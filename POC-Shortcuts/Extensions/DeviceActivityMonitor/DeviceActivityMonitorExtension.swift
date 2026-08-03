import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings

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

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard event == .breakUsageLimit else { return }

        let appName = SharedStore.activeGrant?.appName ?? "the app"
        SharedStore.log("DeviceActivityMonitor", "Usage threshold reached for \"\(appName)\" — re-applying shield.")

        SharedStore.clearActiveGrant()
        reapplyShield()
        DeviceActivityCenter().stopMonitoring([.breakWindow])
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity == .breakWindow else { return }
        SharedStore.log("DeviceActivityMonitor", "Break window interval ended — re-applying shield.")
        SharedStore.clearActiveGrant()
        reapplyShield()
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
