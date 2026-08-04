import Foundation

/// Break lengths, in **seconds**.
///
/// Seconds rather than minutes because a one-minute floor made the expiry path painful to
/// test: every run of "start a break, wait for it to run out, check the shield came back"
/// cost a full minute of waiting.
///
/// One thing seconds cannot buy back: `DeviceActivityEvent`'s usage threshold is expressed in
/// whole minutes, so for a sub-minute break that trigger cannot be armed at all. Those breaks
/// rely on the wall-clock schedule and the app's foreground check instead — see
/// `ScreenTimeService.armReshield`.
enum BreakDurations {

    /// Quick-tap presets. Any value in `range` is selectable, so this is convenience only —
    /// not the set of allowed durations.
    static let options = [10, 30, 60, 300, 600, 900]

    /// Anything under a minute exists for development, and the UI says so.
    static let developmentCeiling = 60

    static let range = 5...(3 * 60 * 60)

    static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// Coarser steps as the value grows, so one stepper spans 5 seconds to 3 hours without
    /// hundreds of taps.
    static func step(for seconds: Int) -> Int {
        switch seconds {
        case ..<60:   return 5
        case ..<300:  return 30
        case ..<1800: return 60
        default:      return 300
        }
    }

    static func label(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }

        let minutes = seconds / 60
        let leftoverSeconds = seconds % 60

        if minutes < 60 {
            return leftoverSeconds == 0 ? "\(minutes) min" : "\(minutes)m \(leftoverSeconds)s"
        }

        let hours = minutes / 60
        let leftoverMinutes = minutes % 60
        return leftoverMinutes == 0 ? "\(hours) hr" : "\(hours) hr \(leftoverMinutes) min"
    }
}
