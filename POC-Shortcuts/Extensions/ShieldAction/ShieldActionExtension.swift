import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import UserNotifications

/// Handles taps on the shield's buttons.
///
/// ## The limitation that used to live here, and no longer does
///
/// Until recently a `ShieldActionDelegate` could not open its own containing app. There is
/// no `UIApplication` here and no `NSExtensionContext`, and Apple engineers said on the
/// developer forums across 2023–2025 that no supported mechanism existed. That single gap
/// was what made the original Voyage Focus concept impossible, and it is why apps in this
/// category route through a Shortcuts automation instead.
///
/// **iOS 26.5 added `ShieldActionResponse.openParentalControlsApp`, which closes the gap.**
/// The shield can now hand the user straight to us. The pre-26.5 notification path is kept
/// below as a fallback, since the deployment target is iOS 17.
///
/// ## Two routes out of the shield
///
/// * **Primary button** → open the app, collect duration *and* free-text context.
/// * **Secondary button submenu** (iOS 26.4+) → pick a duration right on the shield and go
///   straight to the app. Faster, but a submenu item is only a `String`, so no context note.
class ShieldActionExtension: ShieldActionDelegate {

    private let store = ManagedSettingsStore(named: .voyageFocus)

    override func handle(action: ShieldAction,
                         for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {

        let key = TokenBox.key(for: application)

        // Resolution order matters. The token map is usually empty, because
        // `Application.token` is nil inside the shield *configuration* extension and that is
        // the only process that can read display names. The record it leaves behind is what
        // actually identifies the app.
        let lastSeen = SharedStore.lastShieldedApp
        let name = SharedStore.displayName(forTokenKey: key) ?? lastSeen?.name ?? "an app"
        let bundleID = lastSeen?.bundleID

        switch action {
        case .primaryButtonPressed:
            SharedStore.pendingRequest = BreakRequest(
                appName: name,
                appTokenKey: key,
                appBundleID: bundleID,
                source: .screenTimeShield
            )

            if #available(iOS 26.5, *) {
                SharedStore.log("ShieldAction", "\"\(name)\" — opening Voyage Focus directly (openParentalControlsApp).")
                completionHandler(.openParentalControlsApp)
            } else {
                SharedStore.log("ShieldAction", "\"\(name)\" — cannot open app on this iOS; posting notification instead.")
                postBreakNotification(appName: name)
                completionHandler(.close)
            }

        case .secondaryButtonPressed:
            // With submenu items attached, this is just the menu opening — nothing to do.
            // Pre-26.4 it is the plain "Stay focused" button.
            SharedStore.log("ShieldAction", "Secondary button on \"\(name)\".")
            completionHandler(.close)

        case .firstSecondarySubmenuItemPressed:
            grantQuickBreak(minutes: BreakDurations.minutes(atSubmenuIndex: 0), token: application,
                            key: key, name: name, completionHandler: completionHandler)

        case .secondSecondarySubmenuItemPressed:
            grantQuickBreak(minutes: BreakDurations.minutes(atSubmenuIndex: 1), token: application,
                            key: key, name: name, completionHandler: completionHandler)

        case .thirdSecondarySubmenuItemPressed:
            grantQuickBreak(minutes: BreakDurations.minutes(atSubmenuIndex: 2), token: application,
                            key: key, name: name, completionHandler: completionHandler)

        @unknown default:
            completionHandler(.close)
        }
    }

    override func handle(action: ShieldAction,
                         for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(.close)
    }

    override func handle(action: ShieldAction,
                         for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(.close)
    }

    // MARK: - Quick break, granted without ever leaving the shield

    /// Lifts the shield from inside the extension, then asks the system to re-evaluate.
    /// `.defer` is the documented way to say "I changed the ManagedSettingsStore, look
    /// again" — the shield finds this app no longer shielded and lets it through.
    private func grantQuickBreak(minutes: Int,
                                 token: ApplicationToken,
                                 key: String?,
                                 name: String,
                                 completionHandler: @escaping (ShieldActionResponse) -> Void) {

        let request = BreakRequest(appName: name, appTokenKey: key, source: .screenTimeShield)
        let grant = BreakGrant(
            request: request,
            durationMinutes: minutes,
            contextNote: "Quick break (chosen on the shield)"
        )
        SharedStore.activeGrant = grant
        SharedStore.clearPendingRequest()

        var shielded = store.shield.applications ?? []
        shielded.remove(token)
        store.shield.applications = shielded.isEmpty ? nil : shielded

        armReshield(token: token, minutes: minutes)

        SharedStore.log("ShieldAction", "Quick break: \(minutes) min for \"\(name)\" — shield lifted from the extension.")
        completionHandler(.defer)
    }

    /// Best effort from inside the extension. `AppState` re-checks expiry on every
    /// foreground regardless, because threshold callbacks are not dependable.
    private func armReshield(token: ApplicationToken, minutes: Int) {
        let center = DeviceActivityCenter()
        center.stopMonitoring([.breakWindow])

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let event = DeviceActivityEvent(applications: [token], threshold: DateComponents(minute: minutes))

        do {
            try center.startMonitoring(.breakWindow, during: schedule, events: [.breakUsageLimit: event])
        } catch {
            SharedStore.log("ShieldAction", "Could not arm re-shield from extension: \(error)")
        }
    }

    /// Pre-iOS 26.5 fallback: the only channel this process had to reach the user.
    private func postBreakNotification(appName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Taking a break?"
        content.body = "Tap to set up your break from \(appName)."
        content.sound = .default
        content.userInfo = ["source": "shield", "appName": appName]

        let request = UNNotificationRequest(
            identifier: "voyagefocus.break.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}
