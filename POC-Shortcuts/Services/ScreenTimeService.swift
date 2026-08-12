import Foundation
import Combine
import FamilyControls
import ManagedSettings
import DeviceActivity
import UserNotifications

/// Wraps the three Screen Time frameworks.
///
/// FamilyControls  → asks permission, and lets the user pick apps (as opaque tokens).
/// ManagedSettings → applies and removes the actual shield.
/// DeviceActivity  → tells us when a break has been used up, since we cannot run a timer
///                   in the background.
@MainActor
final class ScreenTimeService: ObservableObject {

    static let shared = ScreenTimeService()

    @Published private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    @Published var selection = FamilyActivitySelection()
    @Published private(set) var lastError: String?

    private let store = ManagedSettingsStore(named: .voyageFocus)
    private let center = DeviceActivityCenter()

    private init() {
        refreshAuthorizationStatus()
        loadSelection()
    }

    // MARK: - Authorization  [REAL]

    /// iOS 26.4 added `.approvedWithDataAccess` alongside `.approved`. Treating only
    /// `.approved` as authorized — the obvious reading — silently breaks the app for
    /// users who granted the *stronger* permission.
    var isAuthorized: Bool {
        if #available(iOS 26.4, *), authorizationStatus == .approvedWithDataAccess {
            return true
        }
        return authorizationStatus == .approved
    }

    /// Whether `FamilyActivityData` will actually return anything. See `loadInstalledApps()`.
    var hasDataAccess: Bool {
        guard #available(iOS 26.4, *) else { return false }
        return authorizationStatus == .approvedWithDataAccess
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
    }

    /// Presents Apple's own Screen Time consent sheet. There is no way to pre-authorise
    /// this, and it will fail outright in the Simulator — a physical device is required.
    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            refreshAuthorizationStatus()
            lastError = nil
            SharedStore.log("App", "Screen Time authorization: \(authorizationStatus)")
        } catch {
            lastError = "Screen Time authorization failed: \(error.localizedDescription)"
            refreshAuthorizationStatus()
            SharedStore.log("App", "Screen Time authorization FAILED: \(error)")
        }
    }

    /// Why automatic app detection isn't working, if it isn't. Drives the setup UI.
    enum DetectionState {
        case ready(linked: Int)
        case needsDataAccess
        case unsupportedOS
        case noAppsSelected

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    /// Ready means: there is a token→app catalogue for the shield's token to be looked up
    /// in when a break starts. It deliberately does *not* require the picker's tokens to
    /// resolve — those come from a different namespace than `FamilyActivityData`, so
    /// insisting on them reported failure while everything needed was already in place.
    var detectionState: DetectionState {
        guard #available(iOS 26.4, *) else { return .unsupportedOS }
        guard hasSelection else { return .noAppsSelected }
        let catalogue = SharedStore.tokenInfo.count
        return catalogue > 0 ? .ready(linked: catalogue) : .needsDataAccess
    }

    /// The only way to change an existing Screen Time grant is to drop it and ask again —
    /// `requestAuthorization` is a no-op once authorization exists, so a user stuck on plain
    /// `.approved` cannot upgrade to `.approvedWithDataAccess` without this.
    ///
    /// Revoking invalidates every `ApplicationToken` issued under the old grant. Keeping the
    /// old selection around leaves tokens that name nothing and shield nothing, so the
    /// selection is cleared deliberately and the user is asked to pick again.
    func resetAuthorization() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AuthorizationCenter.shared.revokeAuthorization { _ in continuation.resume() }
        }
        refreshAuthorizationStatus()

        clearShield()
        selection = FamilyActivitySelection()
        SharedStore.selectionData = nil
        SharedStore.tokenInfo = [:]
        SharedStore.log("App", "Authorization revoked — cleared selection, old tokens are now invalid.")

        await requestAuthorization()

        // The agent needs a moment after a fresh grant before it will answer.
        try? await Task.sleep(for: .seconds(1))
        await autoLinkSelectedApps(force: true)
    }

    /// A readable label for a bundle identifier when iOS withholds the display name.
    /// Falls back to the last path component, so `com.burbn.instagram` reads as "Instagram".
    static func displayName(forBundleID bundleID: String) -> String {
        if let known = AppLaunchService.catalog.first(where: { $0.bundleID == bundleID }) {
            return known.name
        }
        let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }

    /// No catalogue at all — nothing for a shield token to resolve against.
    var selectionLooksStale: Bool {
        selectedAppCount > 0 && SharedStore.tokenInfo.isEmpty
    }

    // MARK: - Installed apps  [REAL on iOS 26.4+, otherwise genuinely impossible]

    @Published private(set) var installedApps: [(name: String, bundleID: String)] = []

    /// Builds the token→app catalogue the shield's token is looked up in at break time.
    ///
    /// Two sources:
    ///
    /// 1. **`selection.applications`** — the picker's own `Application` values. Contributes
    ///    nothing in practice: `localizedDisplayName` and `bundleIdentifier` are both nil
    ///    here, as they are anywhere outside an extension.
    /// 2. **`FamilyActivityData.installedApplications`** — every installed app, with tokens
    ///    and bundle identifiers. This is the one that works.
    ///
    /// `localizedDisplayName` is nil even in source 2, so a bundle identifier alone has to be
    /// enough. Requiring a name as well discarded all 88 usable entries — and, because the
    /// selection-overlap counter sat after that same guard, it also reported 0/3 overlap and
    /// suggested the two APIs used different token namespaces. They do not; it is 3/3.
    ///
    /// Indexing every installed app rather than only the selected ones is deliberate: the
    /// token that matters arrives from the *shield* at break time, and a full catalogue makes
    /// that lookup succeed regardless of which tokens the picker happened to hand back.
    ///
    /// There is no manual fallback. Asking the user to match tokens to apps was both tedious
    /// and unsafe — they could pick YouTube while actually opening Instagram.
    @discardableResult
    func autoLinkSelectedApps(force: Bool = false) async -> Int {
        guard #available(iOS 26.4, *) else {
            SharedStore.log("App", "Auto-link skipped: needs iOS 26.4.")
            return 0
        }
        // Throttled: the foreground refresh calls this on every activation.
        if !force, let loaded = catalogLoadedAt, Date().timeIntervalSince(loaded) < 300 { return 0 }
        catalogLoadedAt = Date()

        let tokens = selection.applicationTokens
        guard !tokens.isEmpty else { return 0 }

        var linked = 0
        var catalogueSize = 0
        var selectionCovered = 0

        // Source 1 — straight from the picker's selection.
        for app in selection.applications {
            guard let token = app.token, let key = TokenBox.key(for: token) else { continue }
            guard app.localizedDisplayName != nil || app.bundleIdentifier != nil else { continue }
            let name = app.localizedDisplayName
                ?? app.bundleIdentifier.flatMap(Self.displayName(forBundleID:))
                ?? "Unknown app"
            SharedStore.recordTokenInfo(key: key, name: name, bundleID: app.bundleIdentifier)
            linked += 1
        }
        SharedStore.log("App", "Auto-link source 1 (selection.applications): \(linked)/\(tokens.count) named.")

        // Source 2 — index *every* installed app, not just the selected ones.
        //
        // The earlier version only recorded apps whose token appeared in the selection, and
        // that intersection is empty: `FamilyActivityData` and `FamilyActivityPicker` do not
        // hand out the same token values, so `tokens.contains(token)` never matched and the
        // whole catalogue was thrown away.
        //
        // Matching the selection was never the point. What matters is the token the *shield*
        // hands us at break time, and indexing all 88 apps gives that lookup a chance to hit
        // regardless of which namespace the selection happens to use.
        if linked < tokens.count {
            do {
                let installed = try await fetchInstalledApplications()
                let withTokens = installed.filter { $0.token != nil }.count

                var indexed = 0
                var matchedSelection = 0
                var withNames = 0
                var withBundleIDs = 0
                var keyable = 0

                for app in installed {
                    if app.localizedDisplayName != nil { withNames += 1 }
                    if app.bundleIdentifier != nil { withBundleIDs += 1 }

                    guard let token = app.token, let key = TokenBox.key(for: token) else { continue }
                    keyable += 1

                    // A bundle identifier alone is enough — it is what `AppLaunchService`
                    // prefers anyway. Requiring a display name as well threw away every
                    // usable entry, because `localizedDisplayName` is nil in this process
                    // by design; only extensions get it.
                    guard app.localizedDisplayName != nil || app.bundleIdentifier != nil else { continue }
                    let name = app.localizedDisplayName
                        ?? app.bundleIdentifier.flatMap(Self.displayName(forBundleID:))
                        ?? "Unknown app"

                    SharedStore.recordTokenInfo(key: key, name: name, bundleID: app.bundleIdentifier)
                    indexed += 1
                    if tokens.contains(token) { matchedSelection += 1 }
                }

                SharedStore.log("App", "Auto-link source 2 (FamilyActivityData): \(installed.count) app(s) — tokens:\(withTokens) names:\(withNames) bundleIDs:\(withBundleIDs) keyable:\(keyable) indexed:\(indexed).")
                SharedStore.log("App", "Selection tokens also present in that catalogue: \(matchedSelection)/\(tokens.count) — if 0, the picker and FamilyActivityData use different token values.")
                catalogueSize = indexed
                selectionCovered = matchedSelection
                lastError = nil
            } catch {
                lastError = explain(error)
                SharedStore.log("App", "FamilyActivityData FAILED (status: \(authorizationStatus)): \(error)")
            }
        }

        SharedStore.log("App", "Auto-link result: catalogue \(catalogueSize) app(s); \(selectionCovered)/\(tokens.count) selected app(s) resolvable.")
        objectWillChange.send()
        return catalogueSize
    }

    /// `FamilyActivityData` talks to `com.apple.ManagedSettingsAgent` over XPC, and that
    /// connection fails intermittently across the whole Screen Time stack — the same
    /// "Couldn't communicate with a helper application" turns up on
    /// `DeviceActivityCenter.startMonitoring`, where retrying after a second is the
    /// established workaround. Worth two retries before believing it.
    @available(iOS 26.4, *)
    private func fetchInstalledApplications() async throws -> [Application] {
        var lastFailure: Error?
        for attempt in 1...3 {
            do {
                return try await FamilyActivityData.shared.installedApplications
            } catch {
                lastFailure = error
                SharedStore.log("App", "FamilyActivityData attempt \(attempt)/3 failed: \(error.localizedDescription)")
                if attempt < 3 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        throw lastFailure ?? FamilyControlsError.unavailable
    }

    /// The raw XPC message is misleading — "Couldn't communicate with a helper application"
    /// reads like a transient glitch, but the underlying failure is
    /// `error 159 - Sandbox restriction` on a lookup of
    /// `com.apple.FamilyControlsAgent.data-access`, which means an entitlement is missing
    /// rather than anything being temporarily unavailable.
    private func explain(_ error: Error) -> String {
        let nsError = error as NSError
        let sandboxBlocked = nsError.code == 4099
            || nsError.localizedDescription.contains("helper application")

        if sandboxBlocked {
            return """
            Missing the "Family Controls App and Website Usage" capability. Enable \
            com.apple.developer.family-controls.app-and-website-usage on this App ID in the \
            Developer Portal, then re-download provisioning profiles. Screen Time is \
            currently "\(statusDescription)".
            """
        }
        return "Automatic detection unavailable: \(error.localizedDescription)"
    }

    var statusDescription: String {
        if #available(iOS 26.4, *), authorizationStatus == .approvedWithDataAccess {
            return "Approved + data access"
        }
        switch authorizationStatus {
        case .approved:      return "Approved"
        case .denied:        return "Denied"
        case .notDetermined: return "Not requested"
        default:             return "Unknown"
        }
    }

    /// Note: deliberately *not* gated on `hasDataAccess`. Whether plain `.approved` is
    /// enough for `FamilyActivityData` is undocumented, so we attempt the call and let the
    /// framework decide, rather than refusing based on a guess.
    func loadInstalledApps() async {
        guard #available(iOS 26.4, *) else {
            lastError = "Installed-app listing requires iOS 26.4 or later."
            return
        }
        do {
            let apps = try await FamilyActivityData.shared.installedApplications
            installedApps = apps.compactMap { app in
                guard let name = app.localizedDisplayName, let bundleID = app.bundleIdentifier else { return nil }
                // Opportunistically seed the token→name map, so the app no longer has to
                // wait for a shield to be shown before it can name anything.
                if let token = app.token, let key = TokenBox.key(for: token) {
                    SharedStore.recordTokenInfo(key: key, name: name, bundleID: bundleID)
                }
                return (name, bundleID)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            lastError = nil
            SharedStore.log("App", "FamilyActivityData returned \(installedApps.count) installed app(s).")
        } catch {
            // Expect FamilyControlsError.unauthorized when the user granted plain
            // `.approved` rather than `.approvedWithDataAccess`.
            lastError = "Could not read installed apps: \(error.localizedDescription)"
            SharedStore.log("App", "FamilyActivityData FAILED: \(error)")
        }
    }

    private var catalogLoadedAt: Date?

    // MARK: - Selection  [REAL]

    var selectedAppCount: Int { selection.applicationTokens.count }
    var selectedCategoryCount: Int { selection.categoryTokens.count }

    /// Picking a whole category yields category tokens and **no** application tokens, so a
    /// count based on apps alone read "0 app(s)" while the shield was in fact covering
    /// everything in that category.
    var hasSelection: Bool { selectedAppCount > 0 || selectedCategoryCount > 0 }

    var selectionSummary: String {
        switch (selectedAppCount, selectedCategoryCount) {
        case (0, 0):            return "nothing selected"
        case (let apps, 0):     return "\(apps) app(s)"
        case (0, let cats):     return "\(cats) categor\(cats == 1 ? "y" : "ies")"
        case (let apps, let cats):
            return "\(apps) app(s) + \(cats) categor\(cats == 1 ? "y" : "ies")"
        }
    }

    /// Blocked apps with no identity at all, so nothing can be derived for reopening them.
    /// An app that is named but absent from the scheme catalog does not count here — a
    /// scheme is guessed from its name, which works for most apps.
    var unmappedAppCount: Int {
        selection.applicationTokens.reduce(into: 0) { count, token in
            guard let key = TokenBox.key(for: token) else { return }
            let info = SharedStore.info(forTokenKey: key)
            if info?.bundleID == nil && info?.name == nil { count += 1 }
        }
    }

    func persistSelection() {
        SharedStore.selectionData = try? JSONEncoder().encode(selection)
        SharedStore.log("App", "Selected \(selection.applicationTokens.count) app(s) to shield.")
        if SharedStore.isWorkModeActive { applyShield() }
        Task {
            // Fresh tokens are not always resolvable in the same instant they are minted.
            await autoLinkSelectedApps(force: true)
            if selectionLooksStale {
                try? await Task.sleep(for: .seconds(1))
                await autoLinkSelectedApps(force: true)
            }
        }
    }

    private func loadSelection() {
        guard let data = SharedStore.selectionData,
              let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return }
        selection = decoded
    }

    // MARK: - Work mode  [REAL]

    /// Shielding is the real interception: iOS blocks the launch and draws its own shield
    /// over the app. We can restyle that shield, but we cannot replace it with our own UI.
    func startWorkMode() {
        SharedStore.isWorkModeActive = true
        SharedStore.clearActiveGrant()
        SharedStore.breakEnded = nil
        applyShield()
        SharedStore.log("App", "Work Mode STARTED — \(selection.applicationTokens.count) app(s) shielded.")
    }

    func endWorkMode() {
        SharedStore.isWorkModeActive = false
        SharedStore.clearActiveGrant()
        SharedStore.breakEnded = nil
        LiveActivityService.end(from: "App")
        clearShield()
        center.stopMonitoring([.breakWindow])
        SharedStore.log("App", "Work Mode ENDED — all shields removed.")
    }

    func applyShield() {
        let tokens = selection.applicationTokens
        store.shield.applications = tokens.isEmpty ? nil : tokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
    }

    func clearShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
    }

    // MARK: - Break grant  [REAL unshield / PARTIAL re-shield]

    /// Lifts the shield on **every** selected app for the duration of the break.
    ///
    /// Earlier this unshielded only the one app the user happened to tap, which made the
    /// break feel broken: you asked for a break, opened Instagram, and WhatsApp was still
    /// blocked. A break is a break from work, not from one specific app.
    @discardableResult
    func grantBreak(_ grant: BreakGrant) -> Bool {
        SharedStore.activeGrant = grant
        SharedStore.breakEnded = nil   // a new break supersedes the "break's over" shield

        clearShield()

        let tokens = selection.applicationTokens
        SharedStore.log("App", "Break granted — ALL \(tokens.count) shielded app(s) unlocked for \(BreakDurations.label(grant.durationSeconds)).")

        scheduleExpiryNotification(for: grant)

        guard !tokens.isEmpty else { return false }
        armReshield(tokens: tokens, seconds: grant.durationSeconds, endsAt: grant.expiresAt)
        return true
    }

    /// A plain local notification timed to the break's expiry.
    ///
    /// Scheduled by the app at grant time, so unlike everything else in this file it does not
    /// depend on `DeviceActivityMonitor` running, on shield caching, or on a Live Activity
    /// being reachable from another process. `UNTimeIntervalNotificationTrigger` fires on its
    /// own. Tapping it opens Voyage Focus, which then re-applies the shield and clears the
    /// countdown — the one path that is guaranteed to close the loop.
    private func scheduleExpiryNotification(for grant: BreakGrant) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.expiryNotificationID])

        let content = UNMutableNotificationContent()
        content.title = "Break's over"
        content.body = "Your \(BreakDurations.label(grant.durationSeconds)) break on \(grant.appName) has ended. Tap to get back to work."
        content.sound = .default
        content.userInfo = ["source": "breakExpiry"]

        let request = UNNotificationRequest(
            identifier: Self.expiryNotificationID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, grant.expiresAt.timeIntervalSinceNow),
                repeats: false
            )
        )
        center.add(request)
        SharedStore.log("App", "Expiry notification scheduled for \(BreakDurations.label(grant.durationSeconds)) from now.")
    }

    private static let expiryNotificationID = "voyagefocus.break.expiry"

    /// Arms the re-block. This is the honest weak point of the architecture: threshold
    /// callbacks are the least reliable part of the Screen Time stack, so `AppState`
    /// also re-checks expiry every time the app comes to the foreground.
    private func armReshield(tokens: Set<ApplicationToken>, seconds: Int, endsAt: Date) {
        center.stopMonitoring([.breakWindow])

        // Two independent triggers, because they measure different things and the user only
        // ever sees one of them:
        //
        // * The **schedule** ends at the break's wall-clock expiry, which is exactly what the
        //   Dynamic Island counts down to. `intervalDidEnd` fires there even if the phone is
        //   sitting in Instagram.
        // * The **usage event** fires earlier if the whole break is spent inside the unlocked
        //   apps without interruption.
        //
        // Previously only the usage event was armed. Wall-clock time would run out, the
        // countdown would hit zero, and nothing happened — because the user had switched
        // apps often enough that measured *usage* never reached the threshold.
        //
        // The window *begins* at the break's expiry and runs the 15-minute minimum from
        // there, so `intervalDidStart` is the wall-clock trigger. Anchoring the window's end
        // to the expiry instead meant registering an interval that had already started, and
        // that callback never arrived.
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: endsAt)
        let endComponents = calendar.dateComponents(
            [.hour, .minute, .second],
            from: endsAt.addingTimeInterval(15 * 60)
        )

        let schedule = DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )
        // Combined usage across every unlocked app — the break is spent no matter which one
        // it was spent in. Thresholds are whole minutes, so anything shorter than that can
        // only be caught by the wall-clock trigger above.
        let thresholdMinutes = seconds / 60
        let events: [DeviceActivityEvent.Name: DeviceActivityEvent] = thresholdMinutes >= 1
            ? [.breakUsageLimit: DeviceActivityEvent(
                applications: tokens,
                threshold: DateComponents(minute: thresholdMinutes)
              )]
            : [:]

        do {
            try center.startMonitoring(.breakWindow, during: schedule, events: events)
            SharedStore.log("App", "Armed re-shield — fires at \(startComponents.hour ?? 0):\(String(format: "%02d", startComponents.minute ?? 0)):\(String(format: "%02d", startComponents.second ?? 0))\(events.isEmpty ? " (wall clock only — break is under a minute)" : ", or after \(thresholdMinutes) min of usage").")
        } catch {
            lastError = "Could not arm re-shield: \(error.localizedDescription)"
            SharedStore.log("App", "startMonitoring FAILED: \(error)")
        }
    }

    /// Called when a grant expires, either via the monitor extension or the foreground check.
    /// Resumes blocking. Called when the user picks "Start Work" — never automatically.
    func resumeWork(reason: String) {
        SharedStore.breakEnded = nil
        SharedStore.clearActiveGrant()
        LiveActivityService.end(from: "App")
        if SharedStore.isWorkModeActive { applyShield() }
        center.stopMonitoring([.breakWindow])
        SharedStore.log("App", "Work resumed (\(reason)) — shield applied.")
    }

    /// - Parameter expired: `true` when the break ran out on its own, `false` when the user
    ///   ended it deliberately.
    ///
    /// An expired break deliberately does **not** re-apply the shield. The apps stay open
    /// until the user chooses "Start Work" or starts another break, so a block never lands
    /// mid-scroll without warning.
    func revokeExpiredGrant(reason: String, expired: Bool = true) {
        guard let grant = SharedStore.activeGrant else { return }
        if expired {
            SharedStore.breakEnded = BreakEndedInfo(
                appName: grant.appName,
                durationSeconds: grant.durationSeconds
            )
        }
        SharedStore.clearActiveGrant()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.expiryNotificationID])
        center.stopMonitoring([.breakWindow])

        if expired {
            SharedStore.log("App", "Break expired (\(reason)) — apps left open, waiting for the user to choose.")
        } else {
            LiveActivityService.end(from: "App")
            if SharedStore.isWorkModeActive {
                applyShield()
                SharedStore.log("App", "Break ended (\(reason)) — shield applied.")
            }
        }
    }
}
