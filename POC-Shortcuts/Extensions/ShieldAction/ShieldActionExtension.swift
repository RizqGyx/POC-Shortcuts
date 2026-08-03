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
/// ## One route out of the shield
///
/// The primary button opens Voyage Focus, where the duration and context note are collected.
/// Reopening the blocked app afterwards needs its identity — see `resolveIdentity`, which is
/// the one part of this flow that depends on iOS being willing to name the app.
class ShieldActionExtension: ShieldActionDelegate {

    private let store = ManagedSettingsStore(named: .voyageFocus)

    override func handle(action: ShieldAction,
                         for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {

        let key = TokenBox.key(for: application)
        let identity = resolveIdentity(token: application, key: key)
        let name = identity.name
        let bundleID = identity.bundleID

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

        // The shield offers no submenu, so these never fire. Still required for the switch
        // to be exhaustive.
        case .firstSecondarySubmenuItemPressed,
             .secondSecondarySubmenuItemPressed,
             .thirdSecondarySubmenuItemPressed:
            completionHandler(.close)

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

    // MARK: - Working out which app this actually is

    /// Four sources, cheapest and most universal first. Each attempt is logged with the
    /// source that won, so the Diagnostics timeline shows which one is doing the work on a
    /// given device instead of leaving it to guesswork.
    ///
    /// 1. `Application(token:)` — costs nothing, needs no permission, works from iOS 15.
    ///    Documented as nil *outside* an extension; this is inside one, so it is worth
    ///    asking. If it populates, no linking or iOS 26.4 is needed at all.
    /// 2. The token map, filled by the app from `FamilyActivityData` (iOS 26.4+).
    /// 3. Whatever the shield configuration extension last recorded — same second, but only
    ///    if iOS actually re-ran that extension rather than serving a cached shield.
    /// 4. Give up; the app shows an unlinked warning rather than reopening the wrong thing.
    private func resolveIdentity(token: ApplicationToken,
                                 key: String?) -> (name: String, bundleID: String?) {

        let direct = Application(token: token)
        if let name = direct.localizedDisplayName {
            SharedStore.log("ShieldAction", "Identified \"\(name)\" via Application(token:) — no linking needed.")
            if let key { SharedStore.recordTokenInfo(key: key, name: name, bundleID: direct.bundleIdentifier) }
            return (name, direct.bundleIdentifier)
        }

        if let info = SharedStore.info(forTokenKey: key), let name = info.name as String? {
            SharedStore.log("ShieldAction", "Identified \"\(name)\" via token map (FamilyActivityData).")
            return (name, info.bundleID)
        }

        if let last = SharedStore.lastShieldedApp {
            SharedStore.log("ShieldAction", "Identified \"\(last.name)\" via last shielded app record.")
            return (last.name, last.bundleID)
        }

        SharedStore.log("ShieldAction", "Could NOT identify the app — Application(token:) gave nil, token map empty, no shield record.")
        return ("an app", nil)
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
