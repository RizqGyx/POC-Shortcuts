import Foundation
import ManagedSettings

/// `ApplicationToken` is opaque but `Codable` and `Hashable`, so we can round-trip it
/// through the App Group as a base64 string and use it as a dictionary key.
///
/// This is the *only* durable handle we have on a third-party app. We never learn its
/// bundle identifier outside the shield configuration extension.
///
/// Caveat worth knowing: tokens are not guaranteed to be stable forever. iOS may
/// re-issue a new token for the same app after an OS or app update, at which point a
/// previously stored key silently stops matching.
enum TokenBox {

    static func key(for token: ApplicationToken) -> String? {
        guard let data = try? JSONEncoder().encode(token) else { return nil }
        return data.base64EncodedString()
    }

    static func token(from key: String) -> ApplicationToken? {
        guard let data = Data(base64Encoded: key) else { return nil }
        return try? JSONDecoder().decode(ApplicationToken.self, from: data)
    }
}
