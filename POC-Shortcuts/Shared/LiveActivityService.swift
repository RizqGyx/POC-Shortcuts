import Foundation
import ActivityKit

/// Starts and ends the break countdown in the Dynamic Island.
///
/// Lives in Shared rather than the app target because **ending** has to happen from the
/// monitor extension. ActivityKit only allows *starting* an activity from a foregrounded
/// app, but ending one is permitted elsewhere — and the break usually runs out while the
/// user is in Instagram, with Voyage Focus nowhere near the foreground. Leaving the end to
/// the app meant the countdown sat at 0:00 until the user happened to open Voyage Focus.
enum LiveActivityService {

    private static var current: Activity<BreakActivityAttributes>? {
        Activity<BreakActivityAttributes>.activities.first
    }

    @discardableResult
    static func start(grant: BreakGrant) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            SharedStore.log("App", "Live Activities are disabled in Settings — skipping Dynamic Island.")
            return false
        }

        // Only one break runs at a time; clear any leftover from a previous session.
        end(from: "App")

        let attributes = BreakActivityAttributes(appName: grant.appName)
        let state = BreakActivityAttributes.ContentState(
            startedAt: grant.grantedAt,
            endsAt: grant.expiresAt,
            contextNote: grant.contextNote
        )

        do {
            // `staleDate` is not cosmetic here: it is the only thing that flips the Live
            // Activity into its "break's over" look at the right moment. ActivityKit marks
            // the content stale on its own and the widget re-renders locally, with no
            // process running and nothing pushed.
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: grant.expiresAt),
                pushType: nil
            )
            SharedStore.log("App", "Live Activity started — \(grant.appName), ends \(grant.expiresAt).")
            return true
        } catch {
            SharedStore.log("App", "Live Activity request FAILED: \(error)")
            return false
        }
    }

    /// Flips the countdown into its "over" state and alerts.
    ///
    /// `alertConfiguration` is the only supported way to make the Dynamic Island present
    /// itself — an app cannot expand it on demand. The activity is kept alive on purpose so
    /// the two buttons stay reachable.
    ///
    /// Best effort only, and specifically a no-op when called from `DeviceActivityMonitor`:
    /// `Activity.activities` lists only activities owned by the calling process, and an
    /// extension owns none. The widget's `staleDate` handling covers that case instead.
    static func markOver(appName: String) {
        guard let activity = Activity<BreakActivityAttributes>.activities.first else { return }
        var state = activity.content.state
        guard !state.isOver else { return }
        state.isOver = true

        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: nil),
                alertConfiguration: AlertConfiguration(
                    title: "Break's over",
                    body: "\(appName) is blocked again.",
                    sound: .default
                )
            )
            SharedStore.log("App", "Live Activity switched to \"break's over\" with an alert.")
        }
    }

    /// Removes the countdown entirely.
    ///
    /// Called from several processes on purpose. `Activity.activities` only lists activities
    /// owned by the calling process, and which extensions count as owners is not documented —
    /// the monitor extension appears not to, which is why the countdown used to hang at 0:00.
    /// Rather than rely on one of them, every process that plausibly runs at the right moment
    /// tries, and the log records which one actually managed it.
    ///
    /// - Returns: whether any activity was found to end.
    @discardableResult
    static func end(from process: String = "App") -> Bool {
        let activities = Activity<BreakActivityAttributes>.activities
        guard !activities.isEmpty else {
            SharedStore.log(process, "No Live Activity visible from this process — cannot end it here.")
            return false
        }
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            SharedStore.log(process, "Live Activity ended and dismissed.")
        }
        return true
    }
}
