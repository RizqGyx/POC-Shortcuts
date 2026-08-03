import Foundation
import ManagedSettings

/// Identifiers shared by the app and all three extensions.
///
/// Every one of these values must match exactly across targets. The App Group is the
/// only channel the four processes have — an extension cannot call into the app, and
/// the app cannot call into an extension.
enum AppGroup {

    /// Must exist in the Developer Portal and be enabled on all 4 targets.
    static let identifier = "group.com.ILC6.Miracle.POC-Shortcuts"

    /// The app's own URL scheme, used for deep links back into the break screen.
    static let urlScheme = "voyagefocus"

    static var defaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: identifier) else {
            // Almost always means the App Group is missing from this target's entitlements.
            assertionFailure("App Group \(identifier) unavailable — check entitlements.")
            return .standard
        }
        return defaults
    }
}

/// A *named* ManagedSettingsStore. The name must be identical in the app, the shield
/// action extension and the monitor extension, otherwise each process would be reading
/// and writing a different, unrelated set of restrictions.
extension ManagedSettingsStore.Name {
    static let voyageFocus = Self("VoyageFocusStore")
}
