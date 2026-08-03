import Foundation

/// Runtime feature detection for the Screen Time capabilities that landed in iOS 26.
///
/// These decide how much setup the user is asked to do. On a modern device the answer is
/// "almost none" — grant Screen Time, pick apps, done — which is how apps like Jomo, Opal
/// and ClearSpace behave. The Shortcuts automation only becomes necessary on older iOS,
/// where the shield has no way to hand the user back to us.
enum PlatformCapabilities {

    /// `ShieldActionResponse.openParentalControlsApp` — the shield can open our app.
    /// Without this, tapping the shield can only reach us via a local notification.
    static var shieldCanOpenApp: Bool {
        if #available(iOS 26.5, *) { return true }
        return false
    }

    /// `ShieldConfiguration.secondaryButtonSubmenuItems` — up to three choices on the shield.
    static var shieldSupportsSubmenu: Bool {
        if #available(iOS 26.4, *) { return true }
        return false
    }

    /// `FamilyActivityData` — real names and bundle identifiers, subject to the user
    /// granting `.approvedWithDataAccess`.
    static var canReadInstalledApps: Bool {
        if #available(iOS 26.4, *) { return true }
        return false
    }

    /// The Shortcuts automation is a *fallback*, not part of the product. It is only worth
    /// asking the user to build one when the shield cannot route into the app by itself.
    static var needsShortcutsFallback: Bool { !shieldCanOpenApp }
}
