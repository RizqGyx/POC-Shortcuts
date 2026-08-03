import Foundation
import UIKit

/// Opens the app the user originally asked for.
///
/// Why a hardcoded catalog: there is no API to launch an app by bundle identifier, so a
/// URL scheme is required, and iOS will not tell you an arbitrary app's scheme. Every app
/// in this category ships a table like this one.
///
/// Matching prefers **bundle identifier** over display name. Bundle IDs are stable and
/// unambiguous; display names are localised and can collide.
enum AppLaunchService {

    struct Known: Identifiable, Hashable {
        var name: String
        var bundleID: String
        var scheme: String
        var id: String { bundleID }
    }

    static let catalog: [Known] = [
        Known(name: "Instagram", bundleID: "com.burbn.instagram",      scheme: "instagram://"),
        Known(name: "TikTok",    bundleID: "com.zhiliaoapp.musically", scheme: "tiktok://"),
        Known(name: "YouTube",   bundleID: "com.google.ios.youtube",   scheme: "youtube://"),
        Known(name: "WhatsApp",  bundleID: "net.whatsapp.WhatsApp",    scheme: "whatsapp://"),
        Known(name: "Facebook",  bundleID: "com.facebook.Facebook",    scheme: "fb://"),
        Known(name: "X",         bundleID: "com.atebits.Tweetie2",     scheme: "twitter://"),
        Known(name: "Reddit",    bundleID: "com.reddit.Reddit",        scheme: "reddit://"),
        Known(name: "Snapchat",  bundleID: "com.toyopagroup.picaboo",  scheme: "snapchat://"),
        Known(name: "Netflix",   bundleID: "com.netflix.Netflix",      scheme: "nflx://"),
        Known(name: "Spotify",   bundleID: "com.spotify.client",       scheme: "spotify://"),
    ]

    /// Names iOS gives us when it declines to identify the app. Treat as "unknown", never
    /// as something to match against.
    static let placeholderNames: Set<String> = ["an app", "this app", ""]

    static func isUnresolved(name: String, bundleID: String?) -> Bool {
        scheme(for: name, bundleID: bundleID) == nil
    }

    static func scheme(for appName: String, bundleID: String? = nil) -> String? {
        if let bundleID, let hit = catalog.first(where: { $0.bundleID == bundleID }) {
            return hit.scheme
        }
        let needle = appName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !placeholderNames.contains(needle) else { return nil }
        if let exact = catalog.first(where: { $0.name.lowercased() == needle }) { return exact.scheme }
        return catalog.first(where: { needle.contains($0.name.lowercased()) })?.scheme
    }

    enum Outcome: Equatable {
        case opened(String)
        /// No known scheme for this app, or the app isn't installed.
        case noScheme(String)
        case failed(String)

        var succeeded: Bool { if case .opened = self { return true }; return false }
    }

    /// [REAL] `UIApplication.open` can launch a third-party app by its registered URL
    /// scheme. `LSApplicationQueriesSchemes` is only required for `canOpenURL` — `open`
    /// itself needs no declaration and reports success in its completion handler.
    @MainActor
    static func open(appNamed appName: String, bundleID: String? = nil) async -> Outcome {
        guard let scheme = scheme(for: appName, bundleID: bundleID), let url = URL(string: scheme) else {
            SharedStore.log("App", "No URL scheme known for \"\(appName)\" (bundleID: \(bundleID ?? "nil")).")
            return .noScheme(appName)
        }
        let ok = await UIApplication.shared.open(url)
        SharedStore.log("App", "open(\(scheme)) for \(appName) → \(ok ? "SUCCESS" : "FAILED")")
        return ok ? .opened(scheme) : .failed(scheme)
    }

    /// Fallback for apps that register no URL scheme. The user creates a one-action
    /// "Open App" shortcut named e.g. "Open Notion", and we invoke it by name.
    @MainActor
    @discardableResult
    static func openViaShortcut(named shortcutName: String) async -> Bool {
        let encoded = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? shortcutName
        guard let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return false }
        let ok = await UIApplication.shared.open(url)
        SharedStore.log("App", "run-shortcut \"\(shortcutName)\" → \(ok ? "SUCCESS" : "FAILED")")
        return ok
    }

    @MainActor
    @discardableResult
    static func openShortcutsApp() async -> Bool {
        guard let url = URL(string: "shortcuts://") else { return false }
        return await UIApplication.shared.open(url)
    }
}
