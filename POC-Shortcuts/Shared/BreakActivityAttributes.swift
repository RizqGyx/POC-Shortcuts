import Foundation
import ActivityKit

/// The Live Activity shown in the Dynamic Island and on the Lock Screen while a break runs.
///
/// Shared between the app (which starts and ends the activity) and the widget extension
/// (which renders it). They are separate processes, so this type has to be identical in
/// both — hence its place in Shared.
struct BreakActivityAttributes: ActivityAttributes {

    /// Fixed for the lifetime of the activity.
    var appName: String

    /// The part that changes. `endsAt` drives a self-updating countdown: SwiftUI's
    /// `Text(timerInterval:)` ticks on its own, so the activity does not need pushes or a
    /// background timer to stay accurate — which matters, because a third-party app cannot
    /// run one.
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var endsAt: Date
        var contextNote: String
    }
}
