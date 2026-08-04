import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import UserNotifications

/// [PARTIALLY POSSIBLE] Puts the shield back when a break is used up.
///
/// This exists because iOS gives a third-party app no way to run a background timer. You
/// cannot say "re-block Instagram in 10 minutes" — the app will not be running. The only
/// supported mechanism is to ask DeviceActivity to call you back, either at the end of a
/// schedule interval or when a usage threshold is crossed.
///
/// We use a threshold event: the shield returns after the user has actually *used* the
/// app for the granted duration.
///
/// Honest caveat: threshold callbacks are the least reliable part of the Screen Time
/// stack, with open bug reports about delayed and missed firings on recent iOS versions.
/// `AppState` therefore also checks for expiry whenever the app is foregrounded, and the
/// Diagnostics screen records which of the two actually fired so you can measure it.
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

        SharedStore.log("DeviceActivityMonitor", "\(reason) for \"\(grant.appName)\" — re-applying shield.")

        // Marker for the next shield: it greets the user with "break's over" and the choice
        // between going back to work and taking another one.
        SharedStore.breakEnded = BreakEndedInfo(
            appName: grant.appName,
            durationSeconds: grant.durationSeconds
        )

        SharedStore.clearActiveGrant()
        LiveActivityService.end(from: "DeviceActivityMonitor")
        reapplyShield()
        DeviceActivityCenter().stopMonitoring([.breakWindow])

        notifyBreakOver(appName: grant.appName, seconds: grant.durationSeconds)
    }

    /// The closest thing to "bring the user back to Voyage Focus" that iOS allows: an app
    /// cannot foreground itself, and this extension gets only a few seconds of runtime. A
    /// notification the user can tap is the supported equivalent.
    private func notifyBreakOver(appName: String, seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Break's over"
        content.body = seconds > 0
            ? "Your \(BreakDurations.label(seconds)) break on \(appName) has ended. \(appName) is blocked again."
            : "\(appName) is blocked again."
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

    /// Re-reads the user's selection from the App Group. The extension has no access to
    /// the app's in-memory state, so this is the only source of truth available to it.
    private func reapplyShield() {
        guard SharedStore.isWorkModeActive else {
            SharedStore.log("DeviceActivityMonitor", "Work Mode is off — leaving shields down.")
            return
        }
        guard let data = SharedStore.selectionData,
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else {
            SharedStore.log("DeviceActivityMonitor", "No stored selection — nothing to re-shield.")
            return
        }

        let tokens = selection.applicationTokens
        store.shield.applications = tokens.isEmpty ? nil : tokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
        SharedStore.log("DeviceActivityMonitor", "Re-shielded \(tokens.count) app(s).")
    }
}
