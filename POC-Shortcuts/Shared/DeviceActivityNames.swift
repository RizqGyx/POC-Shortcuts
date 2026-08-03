import Foundation
import DeviceActivity

/// Names shared between the app (which starts monitoring) and the monitor extension
/// (which receives the callbacks).
extension DeviceActivityName {
    /// A long-running window that simply exists so we have somewhere to hang events.
    ///
    /// A `DeviceActivitySchedule` interval must be at least 15 minutes, which is why we
    /// cannot express "re-block in 5 minutes" as a schedule. We use a day-long window
    /// plus a usage-threshold event instead — thresholds are not bound by that floor.
    static let breakWindow = Self("VoyageFocusBreakWindow")
}

extension DeviceActivityEvent.Name {
    /// Fires once the user has actually *used* the unlocked app for the granted number
    /// of minutes. Measuring usage rather than wall-clock is arguably truer to what a
    /// "5 minute break" means, and it sidesteps the 15-minute schedule minimum.
    static let breakUsageLimit = Self("VoyageFocusBreakUsageLimit")
}
