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

    /// Prints what this extension can actually see onto the shield itself.
    ///
    /// This process has no console you can attach to and — if the App Group is not reachable —
    /// no way to leave a note for the app either. The shield's own subtitle is the one
    /// channel that always works, so it doubles as the diagnostic surface. Set to `false`
    /// once the answer is known.
    private static let showDiagnostics = true

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        shield(for: capture(application), application: application)
    }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration {
        shield(for: capture(application), application: application)
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

    /// What this process can and cannot see, rendered onto the shield.
    private func diagnosticLine(_ application: Application?) -> String {
        let group = AppGroup.isShared ? "group:ok" : "group:FAIL"
        let displayName = application?.localizedDisplayName.map { "name:\($0)" } ?? "name:nil"
        let bundle = application?.bundleIdentifier.map { "id:\($0)" } ?? "id:nil"
        let token = application?.token == nil ? "token:nil" : "token:ok"
        return "\(group) · \(displayName) · \(bundle) · \(token)"
    }

    private func shield(for name: String, application: Application? = nil) -> ShieldConfiguration {
        let blur: UIBlurEffect.Style = .systemUltraThinMaterialDark
        let background = UIColor.black.withAlphaComponent(0.55)
        let icon = UIImage(systemName: "sailboat.fill")
        let title = ShieldConfiguration.Label(text: "Voyage Focus", color: .white)
        var subtitleText = "Work Mode is on.\nYou're trying to open \(name)."
        if Self.showDiagnostics {
            subtitleText += "\n\n\(diagnosticLine(application))"
        }
        let subtitle = ShieldConfiguration.Label(
            text: subtitleText,
            color: UIColor.white.withAlphaComponent(0.85)
        )
        let primary = ShieldConfiguration.Label(text: "Take a break", color: .black)

        // One button. "Take a break" opens Voyage Focus, where the duration and the context
        // note are collected, and the blocked app is reopened after Save.
        //
        // The iOS 26.4 submenu (`secondaryButtonSubmenuItems`) is deliberately not used: it
        // grants a break from inside this extension, which means no context note and no
        // Live Activity, and it is a second way of doing the same thing.
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
