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

    @Published private(set) var lastAutoLinkCount = 0

    var detectionState: DetectionState {
        guard #available(iOS 26.4, *) else { return .unsupportedOS }
        guard selectedAppCount > 0 else { return .noAppsSelected }
        guard unmappedAppCount == 0 else { return .needsDataAccess }
        return .ready(linked: selectedAppCount - unmappedAppCount)
    }

    /// The only way to change an existing Screen Time grant is to drop it and ask again —
    /// `requestAuthorization` is a no-op once authorization exists, so a user stuck on plain
    /// `.approved` cannot upgrade to `.approvedWithDataAccess` without this.
    func resetAuthorization() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AuthorizationCenter.shared.revokeAuthorization { _ in continuation.resume() }
        }
        refreshAuthorizationStatus()
        SharedStore.log("App", "Screen Time authorization revoked — requesting again.")
        await requestAuthorization()
        await autoLinkSelectedApps(force: true)
    }

    // MARK: - Installed apps  [REAL on iOS 26.4+, otherwise genuinely impossible]

    @Published private(set) var installedApps: [(name: String, bundleID: String)] = []

    /// Links every selected token to a real app, with no user involvement.
    ///
    /// This is the whole point of `FamilyActivityData`: it returns `Application` values that
    /// carry a token *and* a bundle identifier *and* a display name, so the tokens the user
    /// picked can be matched against it directly.
    ///
    /// There is deliberately no manual fallback anywhere in the app. Asking the user to
    /// match tokens to apps was both tedious and unsafe — they could pick YouTube while
    /// actually opening Instagram, and the wrong app would be reopened.
    @discardableResult
    func autoLinkSelectedApps(force: Bool = false) async -> Int {
        guard #available(iOS 26.4, *) else { return 0 }
        if force { catalogLoadedAt = nil }
        let tokens = selection.applicationTokens
        guard !tokens.isEmpty else { return 0 }

        do {
            let apps = try await FamilyActivityData.shared.installedApplications
            var linked = 0
            for app in apps {
                guard let token = app.token, tokens.contains(token),
                      let key = TokenBox.key(for: token),
                      let name = app.localizedDisplayName else { continue }
                SharedStore.recordTokenInfo(key: key, name: name, bundleID: app.bundleIdentifier)
                linked += 1
            }
            lastError = nil
            SharedStore.log("App", "Auto-linked \(linked) of \(tokens.count) selected app(s).")
            objectWillChange.send()
            return linked
        } catch {
            lastError = "Automatic linking unavailable: \(error.localizedDescription)"
            SharedStore.log("App", "autoLinkSelectedApps FAILED: \(error)")
            return 0
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

    /// Keeps the token→app map warm so a shield tap can be identified immediately.
    ///
    /// This exists because the shield configuration extension turned out to be an
    /// unreliable source: `Application.token` is nil there, and iOS caches shield
    /// configurations so the extension may not run again after the first display.
    func refreshAppCatalogIfPossible(force: Bool = false) async {
        guard #available(iOS 26.4, *) else { return }
        if !force, let loaded = catalogLoadedAt, Date().timeIntervalSince(loaded) < 300 { return }
        catalogLoadedAt = Date()
        await autoLinkSelectedApps()
    }

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
        Task { await autoLinkSelectedApps() }
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
