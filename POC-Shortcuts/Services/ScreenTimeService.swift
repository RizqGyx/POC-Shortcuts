import Foundation
import Combine
import FamilyControls
import ManagedSettings
import DeviceActivity

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
        guard selectedAppCount > 0 else { return .noAppsSelected }
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
    /// 1. **`selection.applications`** — the picker's own `Application` values. Observed to
    ///    return nil names on device even with data access granted, so it contributes
    ///    nothing in practice, but it costs one loop and needs no permission.
    /// 2. **`FamilyActivityData.installedApplications`** — every installed app, with names,
    ///    bundle IDs and tokens. This is the one that works.
    ///
    /// Note what is deliberately *not* required: that the picker's tokens appear in source 2.
    /// They do not — the two APIs issue different token values for the same app. Requiring
    /// that intersection made the catalogue look empty when it was in fact complete.
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
                linked = max(linked, indexed)
                lastError = nil
            } catch {
                lastError = explain(error)
                SharedStore.log("App", "FamilyActivityData FAILED (status: \(authorizationStatus)): \(error)")
            }
        }

        SharedStore.log("App", "Auto-link result: \(linked) of \(tokens.count) selected app(s) identified.")
        objectWillChange.send()
        return linked
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
        applyShield()
        SharedStore.log("App", "Work Mode STARTED — \(selection.applicationTokens.count) app(s) shielded.")
    }

    func endWorkMode() {
        SharedStore.isWorkModeActive = false
        SharedStore.clearActiveGrant()
        LiveActivityService.end()
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

        clearShield()

        let tokens = selection.applicationTokens
        SharedStore.log("App", "Break granted — ALL \(tokens.count) shielded app(s) unlocked for \(grant.durationMinutes) min.")

        guard !tokens.isEmpty else { return false }
        armReshield(tokens: tokens, minutes: grant.durationMinutes)
        return true
    }

    /// Arms the re-block. This is the honest weak point of the architecture: threshold
    /// callbacks are the least reliable part of the Screen Time stack, so `AppState`
    /// also re-checks expiry every time the app comes to the foreground.
    private func armReshield(tokens: Set<ApplicationToken>, minutes: Int) {
        center.stopMonitoring([.breakWindow])

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        // Combined usage across every unlocked app — the break is spent no matter which
        // one it was spent in.
        let event = DeviceActivityEvent(
            applications: tokens,
            threshold: DateComponents(minute: minutes)
        )

        do {
            try center.startMonitoring(.breakWindow, during: schedule, events: [.breakUsageLimit: event])
            SharedStore.log("App", "Armed re-shield after \(minutes) min of usage.")
        } catch {
            lastError = "Could not arm re-shield: \(error.localizedDescription)"
            SharedStore.log("App", "startMonitoring FAILED: \(error)")
        }
    }

    /// Called when a grant expires, either via the monitor extension or the foreground check.
    func revokeExpiredGrant(reason: String) {
        guard SharedStore.activeGrant != nil else { return }
        SharedStore.clearActiveGrant()
        LiveActivityService.end()
        center.stopMonitoring([.breakWindow])
        if SharedStore.isWorkModeActive {
            applyShield()
            SharedStore.log("App", "Break expired (\(reason)) — shield RE-APPLIED.")
        }
    }
}
