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

    // MARK: - Installed apps  [REAL on iOS 26.4+, otherwise genuinely impossible]

    @Published private(set) var installedApps: [(name: String, bundleID: String)] = []

    /// iOS 26.4 introduced `FamilyActivityData`, which hands back real `Application`
    /// values — with `bundleIdentifier` and `localizedDisplayName` populated — instead of
    /// opaque tokens.
    ///
    /// Before 26.4 this was flatly impossible outside the shield configuration extension,
    /// and every app in this category shipped a hand-maintained name→scheme table as a
    /// workaround. That workaround is still in `AppLaunchService` as the pre-26.4 fallback.
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
    func refreshAppCatalogIfPossible() async {
        guard hasDataAccess else { return }
        if let loaded = catalogLoadedAt, Date().timeIntervalSince(loaded) < 300 { return }
        catalogLoadedAt = Date()
        await loadInstalledApps()
    }

    // MARK: - Selection  [REAL]

    var selectedAppCount: Int { selection.applicationTokens.count }

    func persistSelection() {
        SharedStore.selectionData = try? JSONEncoder().encode(selection)
        SharedStore.log("App", "Selected \(selection.applicationTokens.count) app(s) to shield.")
        if SharedStore.isWorkModeActive { applyShield() }
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
