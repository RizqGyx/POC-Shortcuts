import Foundation
import Combine
import SwiftUI
import UserNotifications

/// Coordinates the app's view of state that actually lives in the App Group, because
/// three other processes can change it while we are not running.
@MainActor
final class AppState: ObservableObject {

    @Published var hasOnboarded: Bool = SharedStore.hasOnboarded
    @Published var isWorkModeActive: Bool = SharedStore.isWorkModeActive
    @Published var pendingRequest: BreakRequest?
    @Published var activeGrant: BreakGrant?
    @Published var lastOutcome: AppLaunchService.Outcome?
    @Published var bannerMessage: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .voyageFocusSharedStateChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: - Sync with the App Group

    /// Called on every foreground and whenever an intent fires. Everything interesting
    /// arrives through here, because the shield extensions can only leave notes for us.
    func refresh() {
        isWorkModeActive = SharedStore.isWorkModeActive
        hasOnboarded = SharedStore.hasOnboarded

        // "Start Work" tapped in the Dynamic Island while we were not running.
        if SharedStore.endBreakRequested {
            SharedStore.endBreakRequested = false
            ScreenTimeService.shared.revokeExpiredGrant(reason: "Start Work from Live Activity", expired: false)
        }

        // Backstop for the unreliable DeviceActivity threshold callback.
        if let grant = SharedStore.activeGrant, !grant.isActive {
            ScreenTimeService.shared.revokeExpiredGrant(reason: "foreground expiry check")
        }
        activeGrant = SharedStore.activeGrant

        if let bounce = SharedStore.pendingBounce {
            SharedStore.pendingBounce = nil
            Task { await bounceBack(to: bounce) }
            return
        }

        pendingRequest = SharedStore.pendingRequest.map(resolveIdentity)

        // Keep the token→app map fresh so the *next* shield tap can be identified without
        // depending on the shield configuration extension having run.
        Task { await ScreenTimeService.shared.autoLinkSelectedApps() }
    }

    /// The shield action extension often cannot name the app it was invoked for: the token
    /// map is empty (`Application.token` is nil in the configuration extension) and iOS
    /// caches shield configurations, so that extension may not run again at all. When that
    /// happens the request arrives as the placeholder "an app".
    ///
    /// The app has better information than the extension does, so it repairs the request
    /// here rather than at the point of failure.
    private func resolveIdentity(_ request: BreakRequest) -> BreakRequest {
        var resolved = request

        if let info = SharedStore.info(forTokenKey: request.appTokenKey) {
            resolved.appName = info.name
            resolved.appBundleID = info.bundleID
        } else if AppLaunchService.placeholderNames.contains(request.appName.lowercased()),
                  let last = SharedStore.lastShieldedApp {
            resolved.appName = last.name
            resolved.appBundleID = last.bundleID
        }

        if resolved.appName != request.appName {
            SharedStore.log("App", "Resolved requested app: \"\(request.appName)\" → \"\(resolved.appName)\".")
        }
        return resolved
    }

    /// The automation re-fired during a live grant, so we hand the user straight back
    /// rather than asking them to configure another break.
    private func bounceBack(to appName: String) async {
        bannerMessage = "Break still running — returning to \(appName)."
        _ = await AppLaunchService.open(appNamed: appName)
    }

    // MARK: - Deep link:  voyagefocus://break?app=Instagram

    func handle(url: URL) {
        guard url.scheme == AppGroup.urlScheme else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let appName = components?.queryItems?.first(where: { $0.name == "app" })?.value

        switch url.host {
        case "endbreak":
            // From the Live Activity's "Start Work" button.
            SharedStore.log("App", "Start Work from the Dynamic Island.")
            ScreenTimeService.shared.revokeExpiredGrant(reason: "Start Work from Live Activity", expired: false)
            refresh()

        case "break":
            let request = BreakRequest(
                appName: appName ?? "an app",
                appTokenKey: nil,
                source: .manual
            )
            SharedStore.pendingRequest = request
            SharedStore.log("App", "Deep link opened break screen for \"\(request.appName)\".")
            refresh()
        default:
            break
        }
    }

    // MARK: - The Save & Continue path
    //
    // Split into two phases on purpose. Lifting a Screen Time shield is not instantaneous:
    // the write goes to the system's ManagedSettings store and takes a moment to take
    // effect. Calling `open("instagram://")` in the same run loop asks iOS to launch an app
    // it still considers shielded, and the launch is refused — which looked like "Save did
    // nothing" while the shield had in fact been lifted correctly.
    //
    // The shield's own quick-break path avoids this entirely: it returns `.defer` and lets
    // the *system* re-evaluate, rather than trying to launch the app itself.

    /// Phase 1 — persist, lift the shield, start the Live Activity. No app launching here.
    func commitBreak(request: BreakRequest, seconds: Int, context: String) {
        let grant = BreakGrant(request: request, durationSeconds: seconds, contextNote: context)

        ScreenTimeService.shared.grantBreak(grant)
        SharedStore.clearPendingRequest()
        SharedStore.log(
            "App",
            "SAVED break — app: \(grant.appName), duration: \(BreakDurations.label(seconds)), context: \"\(context)\""
        )

        activeGrant = grant
        pendingRequest = nil
        lastOutcome = nil

        LiveActivityService.start(grant: grant)
    }

    /// Phase 2 — run after the sheet has been dismissed, so the launch isn't competing with
    /// a presentation transition, and after the unshield has had time to propagate.
    func openRequestedApp(_ request: BreakRequest) async {
        try? await Task.sleep(for: .milliseconds(400))

        var outcome = await AppLaunchService.open(appNamed: request.appName,
                                                  bundleID: request.appBundleID)

        // One retry. On a cold shield-lift the first attempt can still land too early.
        if case .failed = outcome {
            SharedStore.log("App", "First launch attempt failed — retrying after propagation delay.")
            try? await Task.sleep(for: .milliseconds(800))
            outcome = await AppLaunchService.open(appNamed: request.appName,
                                                  bundleID: request.appBundleID)
        }

        lastOutcome = outcome
    }

    func dismissRequest() {
        SharedStore.clearPendingRequest()
        pendingRequest = nil
    }

    // MARK: - Onboarding / work mode

    func completeOnboarding() {
        SharedStore.hasOnboarded = true
        hasOnboarded = true
    }

    func startWorkMode() {
        ScreenTimeService.shared.startWorkMode()
        refresh()
    }

    func endWorkMode() {
        ScreenTimeService.shared.endWorkMode()
        lastOutcome = nil
        refresh()
    }

    /// The shield action extension can only reach the user through a notification, so
    /// this permission is load-bearing rather than cosmetic.
    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Lets you exercise the break screen without needing Work Mode or an automation.
    func simulateRequest(appName: String) {
        SharedStore.pendingRequest = BreakRequest(
            appName: appName,
            appTokenKey: nil,
            source: .manual
        )
        SharedStore.log("App", "Manual test intercept for \"\(appName)\".")
        refresh()
    }
}
