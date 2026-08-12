import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import UserNotifications

/// Notices when a break has run out.
///
/// This exists because iOS gives a third-party app no way to run a background timer — you
/// cannot say "call me in 10 minutes". DeviceActivity's callbacks are the only mechanism.
///
/// It no longer re-applies the shield itself. A block appearing mid-scroll with no warning
/// was unpleasant, so expiry only records that the break is over and alerts; the user then
/// picks "Start Work" or "New Break" from the Live Activity.
///
/// Note the extension cannot touch the Live Activity: measured on device,
/// `Activity.activities` is empty here, so any update or end call is a silent no-op. The
/// widget's own `staleDate` handling covers the visual change instead.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let store = ManagedSettingsStore(named: .voyageFocus)

    /// Fires when the break's *usage* budget is spent.
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard event == .breakUsageLimit else { return }
        endBreak(reason: "usage threshold reached")
    }

    /// Both triggers converge here, so the user gets identical behaviour either way.
    private func endBreak(reason: String) {
        guard let grant = SharedStore.activeGrant else {
            SharedStore.log("DeviceActivityMonitor", "\(reason), but no break was active — nothing to do.")
            return
        }

        SharedStore.log("DeviceActivityMonitor", "\(reason) for \"\(grant.appName)\".")

        // Marker for the next shield: it greets the user with "break's over" and the choice
        // between going back to work and taking another one.
        SharedStore.breakEnded = BreakEndedInfo(
            appName: grant.appName,
            durationSeconds: grant.durationSeconds
        )

        SharedStore.clearActiveGrant()
        DeviceActivityCenter().stopMonitoring([.breakWindow])

        // Deliberately no re-shield here. A block landing mid-scroll with no warning is
        // jarring, so the apps stay open and the Live Activity asks the user to choose:
        // "Start Work" applies the shield, "New Break" opens the app to pick another
        // duration. Until then nothing changes underneath them.
        SharedStore.log("DeviceActivityMonitor", "Apps left open — waiting for the user to choose.")

        notifyBreakOver(appName: grant.appName, seconds: grant.durationSeconds)
    }

    /// The closest thing to "bring the user back to Voyage Focus" that iOS allows: an app
    /// cannot foreground itself, and this extension gets only a few seconds of runtime. A
    /// notification the user can tap is the supported equivalent.
    private func notifyBreakOver(appName: String, seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Break's over"
        content.body = seconds > 0
            ? "Your \(BreakDurations.label(seconds)) break on \(appName) has ended. Back to work, or take another?"
            : "Your break on \(appName) has ended. Back to work, or take another?"
        content.sound = .default
        content.userInfo = ["source": "breakEnded", "appName": appName]

        let request = UNNotificationRequest(
            identifier: "voyagefocus.breakended.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Fires at the break's wall-clock expiry — the moment the countdown hits zero.
    ///
    /// The monitored window is scheduled to *begin* at that instant rather than end there.
    /// An earlier version anchored the window's end to the expiry, which meant calling
    /// `startMonitoring` for an interval that had already begun; that callback never
    /// arrived. A boundary in the future is the pattern DeviceActivity actually delivers on.
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard activity == .breakWindow else { return }
        endBreak(reason: "break time is up")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity == .breakWindow else { return }
        endBreak(reason: "monitoring window closed")
    }

}
