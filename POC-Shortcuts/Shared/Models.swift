import Foundation

/// Which mechanism produced the intervention.
///
/// This matters because the two paths carry different amounts of information:
/// `.shortcutAutomation` gives us the app's real name as plain text, while
/// `.screenTimeShield` gives us only an opaque token that we must look up.
enum InterventionSource: String, Codable {
    case shortcutAutomation
    case screenTimeShield
    case manual

    var displayName: String {
        switch self {
        case .shortcutAutomation: return "Shortcuts automation"
        case .screenTimeShield: return "Screen Time shield"
        case .manual: return "Manual (in-app test)"
        }
    }
}

/// Written by whichever process intercepted the user; read by the main app.
struct BreakRequest: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var appName: String
    /// Base64 of the encoded `ApplicationToken`, when we have one. Never a bundle ID —
    /// iOS does not expose bundle IDs outside the shield configuration extension.
    var appTokenKey: String? = nil
    /// Only the shield configuration extension can see this. Far more reliable than
    /// matching on a display name, which is localised and user-visible.
    var appBundleID: String? = nil
    var source: InterventionSource
    var requestedAt: Date = Date()
}

/// Written when the user taps "Save & Continue". This is the record that unlocks the app.
struct BreakGrant: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var appName: String
    var appTokenKey: String?
    var appBundleID: String?
    var durationSeconds: Int
    var contextNote: String
    var grantedAt: Date
    var expiresAt: Date

    var isActive: Bool { Date() < expiresAt }
    var remaining: TimeInterval { max(0, expiresAt.timeIntervalSinceNow) }

    init(request: BreakRequest, durationSeconds: Int, contextNote: String, now: Date = Date()) {
        self.appName = request.appName
        self.appTokenKey = request.appTokenKey
        self.appBundleID = request.appBundleID
        self.durationSeconds = durationSeconds
        self.contextNote = contextNote
        self.grantedAt = now
        self.expiresAt = now.addingTimeInterval(TimeInterval(durationSeconds))
    }
}

/// Appended by every process so the Diagnostics screen can show, on one timeline,
/// what each of the four processes actually did. This is the POC's evidence trail.
struct LogEvent: Codable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var process: String
    var message: String
}

/// What the shield configuration extension saw, recorded unconditionally.
///
/// The token→name map alone is not enough: `Application.token` is Optional and comes back
/// nil inside that extension, so the map is never populated from there. `bundleIdentifier`
/// and `localizedDisplayName` *are* populated, so we record those instead and let the
/// shield action extension read the most recent entry.
struct ShieldedAppInfo: Codable, Equatable {
    var name: String
    var bundleID: String?
    var seenAt: Date = Date()
}

/// Recorded the moment a break runs out, so the next shield can react to it.
struct BreakEndedInfo: Codable, Equatable {
    var appName: String
    var durationSeconds: Int
    var endedAt: Date = Date()
}
