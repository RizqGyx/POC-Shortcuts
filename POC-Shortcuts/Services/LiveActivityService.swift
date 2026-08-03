import Foundation
import ActivityKit

/// Starts and ends the break countdown in the Dynamic Island.
///
/// One constraint shapes where this can be called from: **ActivityKit only lets you start
/// a Live Activity while your app is in the foreground.** An app extension cannot do it.
/// That rules out starting one from the shield's quick-break path, and is part of why the
/// break flow now routes through the app.
///
/// Ending is less restricted, so the monitor extension's re-shield can be reconciled by the
/// app the next time it is foregrounded.
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
        endAll()

        let attributes = BreakActivityAttributes(appName: grant.appName)
        let state = BreakActivityAttributes.ContentState(
            startedAt: grant.grantedAt,
            endsAt: grant.expiresAt,
            contextNote: grant.contextNote
        )

        do {
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

    /// Ends the countdown. Called when a break expires, is ended early, or Work Mode stops.
    static func end() {
        endAll()
    }

    private static func endAll() {
        let activities = Activity<BreakActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            SharedStore.log("App", "Live Activity ended.")
        }
    }
}
