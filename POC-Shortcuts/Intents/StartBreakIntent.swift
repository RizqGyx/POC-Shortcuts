import AppIntents
import Foundation

extension Notification.Name {
    static let voyageFocusSharedStateChanged = Notification.Name("voyageFocusSharedStateChanged")
}

/// [REAL] The load-bearing intent. This is what a Shortcuts *personal automation* calls.
///
/// Why it exists: it is the only mechanism on iOS that both (a) brings Voyage Focus to the
/// foreground when the user opens a distracting app, and (b) tells us *which* app that was,
/// as plain readable text. The Screen Time shield path can do neither — the shield action
/// extension cannot launch us, and outside the shield configuration extension every app is
/// an opaque token with no name.
///
/// The name arrives as a parameter because the user configures one automation per app
/// ("When Instagram is opened → Start Break, App Name: Instagram"). We are not detecting
/// the app; the user is telling us. That distinction is the whole reason this works.
///
/// ⚠️ iOS will NOT let this app create that automation. There is no API for personal
/// automations — not App Intents, not the deprecated INVoiceShortcutCenter, nothing. The
/// user must build it by hand in the Shortcuts app. See AutomationGuideView.
struct StartBreakIntent: AppIntent {

    static var title: LocalizedStringResource = "Start a Break"

    static var description = IntentDescription(
        """
        Called by a Shortcuts automation when you open a distracting app. \
        Opens Voyage Focus so you can set up your break.
        """,
        categoryName: "Breaks"
    )

    /// Foregrounds Voyage Focus. This is a *static* property, so the intent cannot decide
    /// at runtime whether to open the app — see the grace-period note in `perform()`.
    static var openAppWhenRun: Bool = true

    static var isDiscoverable: Bool = true

    @Parameter(
        title: "App Name",
        description: "The app you're about to open, e.g. Instagram.",
        requestValueDialog: "Which app are you opening?"
    )
    var appName: String

    @Parameter(
        title: "Context",
        description: "Optional note pre-filled on the break screen.",
        default: ""
    )
    var contextHint: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a break from \(\.$appName)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {

        // Grace period. Without this the automation loops forever: we send the user back
        // to Instagram, Instagram opening re-fires the automation, which re-opens us.
        //
        // Because `openAppWhenRun` is static we cannot suppress the app launch here. So
        // the app opens, sees the live grant, and immediately bounces back to the target.
        // That costs a ~0.5s visible flash. Avoiding it would require returning an
        // OpenURLIntent with a universal link, which needs an associated domain and a
        // hosted apple-app-site-association file — backend infrastructure this POC excludes.
        if SharedStore.hasActiveGrant(forAppNamed: appName) {
            SharedStore.log("StartBreakIntent", "\"\(appName)\" still within an active break — bouncing straight back.")
            SharedStore.pendingRequest = nil
            SharedStore.pendingBounce = appName
            NotificationCenter.default.post(name: .voyageFocusSharedStateChanged, object: nil)
            return .result()
        }

        let request = BreakRequest(
            appName: appName,
            appTokenKey: nil,          // the automation path never carries a token
            source: .shortcutAutomation
        )
        SharedStore.pendingRequest = request
        SharedStore.log("StartBreakIntent", "Intercepted \"\(appName)\" via Shortcuts automation.")

        if let hint = contextHint, !hint.isEmpty {
            SharedStore.log("StartBreakIntent", "Context hint supplied: \"\(hint)\"")
        }

        NotificationCenter.default.post(name: .voyageFocusSharedStateChanged, object: nil)
        return .result()
    }
}
