import AppIntents
import Foundation

/// [REAL] Exposed to Shortcuts so the user can automate Work Mode itself — by time of
/// day, on arriving at the office, when connecting to a Focus, and so on. Unlike the
/// "app is opened" trigger these are conventional triggers that work reliably.
struct StartWorkModeIntent: AppIntent {

    static var title: LocalizedStringResource = "Start Work Mode"
    static var description = IntentDescription(
        "Shields your selected distracting apps.",
        categoryName: "Work Mode"
    )
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        ScreenTimeService.shared.startWorkMode()
        NotificationCenter.default.post(name: .voyageFocusSharedStateChanged, object: nil)
        let count = ScreenTimeService.shared.selectedAppCount
        return .result(dialog: "Work Mode on. \(count) app\(count == 1 ? "" : "s") shielded.")
    }
}

struct EndWorkModeIntent: AppIntent {

    static var title: LocalizedStringResource = "End Work Mode"
    static var description = IntentDescription(
        "Removes all shields and ends the session.",
        categoryName: "Work Mode"
    )
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        ScreenTimeService.shared.endWorkMode()
        NotificationCenter.default.post(name: .voyageFocusSharedStateChanged, object: nil)
        return .result(dialog: "Work Mode off.")
    }
}

/// [REAL] Ends a break early and re-applies the shield immediately.
struct EndBreakIntent: AppIntent {

    static var title: LocalizedStringResource = "End Break Now"
    static var description = IntentDescription(
        "Ends the current break and re-blocks the app.",
        categoryName: "Breaks"
    )
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = SharedStore.activeGrant?.appName
        ScreenTimeService.shared.revokeExpiredGrant(reason: "ended early via Shortcuts", expired: false)
        NotificationCenter.default.post(name: .voyageFocusSharedStateChanged, object: nil)
        return .result(dialog: name.map { "Break from \($0) ended." } ?? "No break was active.")
    }
}
