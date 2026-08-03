import UIKit
import ManagedSettings
import ManagedSettingsUI

/// [PARTIALLY POSSIBLE] Restyles the system shield.
///
/// What we CAN control: icon, title, subtitle, background colour/blur, two button labels
/// and — from iOS 26.4 — up to three submenu items hanging off the secondary button.
///
/// What we CANNOT do: show SwiftUI, a free-text field, or any view of our own. The shield
/// is drawn by the system in its own process, and a submenu item is just a `String`. So a
/// duration can be chosen here, but a typed context note still requires the app.
///
/// The second job of this class is to snapshot the token → display-name mapping into the
/// App Group. Before iOS 26.4 this was the *only* place on the device where
/// `Application.localizedDisplayName` and `.bundleIdentifier` were populated — everywhere
/// else they were nil by design. iOS 26.4's `FamilyActivityData` now exposes the same
/// information to the app directly, but only with `.approvedWithDataAccess` authorization,
/// so this remains the reliable path and the only one available below 26.4.
class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        let name = capture(application)
        return shield(for: name)
    }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration {
        let name = capture(application)
        return shield(for: name)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        shield(for: webDomain.domain ?? "this site")
    }

    override func configuration(shielding webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration {
        shield(for: webDomain.domain ?? "this site")
    }

    // MARK: -

    /// Records what only this process can see.
    ///
    /// `Application.token` is Optional and comes back **nil** here, so the token→name map
    /// can never be populated from this extension — which is why the shield action
    /// extension used to fall back to the literal string "an app". The name and bundle
    /// identifier *are* populated, so we record those unconditionally as the most recently
    /// shielded app, and the action extension reads that instead.
    private func capture(_ application: Application) -> String {
        let name = application.localizedDisplayName ?? "this app"

        SharedStore.lastShieldedApp = ShieldedAppInfo(
            name: name,
            bundleID: application.bundleIdentifier
        )

        // Kept for the case where iOS does hand us a token.
        if let token = application.token, let key = TokenBox.key(for: token) {
            SharedStore.recordTokenInfo(key: key, name: name, bundleID: application.bundleIdentifier)
        }

        SharedStore.log(
            "ShieldConfiguration",
            "Shield shown for \"\(name)\" (bundleID: \(application.bundleIdentifier ?? "nil"), token: \(application.token == nil ? "nil" : "present"))"
        )
        return name
    }

    private func shield(for name: String) -> ShieldConfiguration {
        let blur: UIBlurEffect.Style = .systemUltraThinMaterialDark
        let background = UIColor.black.withAlphaComponent(0.55)
        let icon = UIImage(systemName: "sailboat.fill")
        let title = ShieldConfiguration.Label(text: "Voyage Focus", color: .white)
        let subtitle = ShieldConfiguration.Label(
            text: "Work Mode is on.\nYou're trying to open \(name).",
            color: UIColor.white.withAlphaComponent(0.85)
        )
        let primary = ShieldConfiguration.Label(text: "Take a break", color: .black)

        // A single button, by design.
        //
        // iOS 26.4 also allows a submenu on the secondary button (up to three items, each
        // reported back as its own ShieldAction case), which can grant a break without ever
        // opening the app. That was removed here because two entry points doing almost the
        // same thing made the flow confusing, and because a submenu item is only a String —
        // it cannot capture a context note, and a break granted from the extension cannot
        // start a Live Activity (ActivityKit requires a foregrounded app).
        //
        // The handlers for those submenu cases still exist in ShieldActionExtension, so
        // re-enabling this is a one-line change if the quick path is ever wanted back.
        return ShieldConfiguration(
            backgroundBlurStyle: blur,
            backgroundColor: background,
            icon: icon,
            title: title,
            subtitle: subtitle,
            primaryButtonLabel: primary,
            primaryButtonBackgroundColor: .white
        )
    }
}
