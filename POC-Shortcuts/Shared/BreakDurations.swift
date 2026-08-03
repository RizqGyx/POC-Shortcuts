import Foundation

/// The break lengths offered throughout the app.
///
/// Shared because the shield configuration extension renders these as submenu labels while
/// the shield action extension maps the resulting tap back to a number of minutes. The two
/// run in separate processes and would drift apart if each kept its own copy — the
/// submenu reports only "first / second / third item pressed", never the label text.
enum BreakDurations {
    static let options = [5, 10, 15]

    static var submenuLabels: [String] {
        options.map { "\($0) minutes" }
    }

    static func minutes(atSubmenuIndex index: Int) -> Int {
        options.indices.contains(index) ? options[index] : options[0]
    }
}
