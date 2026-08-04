import AppIntents
import Foundation

/// Buttons for the Live Activity.
///
/// These live in Shared because a Live Activity's buttons are rendered — and their intents
/// executed — by the widget extension, not the app.
///
/// Why put controls here at all: the Dynamic Island is on screen exactly when a break is
/// running, including the moment it runs out. It does not depend on `DeviceActivityMonitor`
/// firing, and it does not depend on iOS re-rendering a shield. Both of those have proved
/// unreliable, so this is the one surface that is reliably in front of the user.

/// Ends the break immediately and re-blocks the apps.
///
/// `openAppWhenRun` is deliberately true. Re-applying a shield needs the Family Controls
/// entitlement and the stored `FamilyActivitySelection`, and granting the widget extension
/// those would mean another App ID and another portal capability. Handing the work to the
/// app instead keeps the widget's entitlements minimal — and going back to work is exactly
/// the moment where opening Voyage Focus is unobjectionable.
struct StartWorkFromBreakIntent: AppIntent {

    static var title: LocalizedStringResource = "Start Work"
    static var description = IntentDescription("Ends the break and blocks your distracting apps again.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        SharedStore.endBreakRequested = true
        SharedStore.log("LiveActivity", "Start Work tapped — asking the app to re-block.")
        return .result()
    }
}

/// Hides the countdown without touching the break.
///
/// Runs entirely inside the widget extension: ending a Live Activity needs nothing beyond
/// ActivityKit, so no extra entitlement and no app launch.
struct DismissBreakActivityIntent: AppIntent {

    static var title: LocalizedStringResource = "Dismiss"
    static var description = IntentDescription("Hides the break countdown. The break keeps running.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        SharedStore.log("LiveActivity", "Countdown dismissed by the user.")
        LiveActivityService.end(from: "LiveActivity")
        return .result()
    }
}
