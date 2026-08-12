import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

/// The Dynamic Island + Lock Screen presentation of a running break.
///
/// The countdown uses `Text(timerInterval:)` throughout, which SwiftUI ticks by itself from
/// the end date. Nothing here polls, and the app does not push updates — a third-party app
/// cannot run a background timer, so a self-driving view is the only accurate option.
struct BreakLiveActivity: Widget {

    /// Whether the break has run out.
    ///
    /// `context.isStale` is the load-bearing half. ActivityKit flips it automatically once
    /// the content's `staleDate` passes, and the widget re-renders locally — no process has
    /// to be running and nothing has to be pushed. That matters because the obvious approach,
    /// having `DeviceActivityMonitor` call `Activity.update`, silently does nothing:
    /// `Activity.activities` only lists activities owned by the process asking, and an
    /// extension owns none. The countdown simply sat at 0:00 forever.
    ///
    /// `state.isOver` is kept as the explicit signal for when the app itself is running and
    /// can update properly.
    private func isOver(_ context: ActivityViewContext<BreakActivityAttributes>) -> Bool {
        context.state.isOver || context.isStale
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BreakActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Laid out like an incoming call: an action at each edge, the subject in the
                // middle. Worth knowing that a third-party Live Activity cannot *open* itself
                // this way — CallKit's expanded island is a privileged system presentation.
                // This is what the user sees on long-press, or when an alerting update
                // briefly presents the activity.
                DynamicIslandExpandedRegion(.leading) {
                    Link(destination: URL(string: "\(AppGroup.urlScheme)://endbreak")!) {
                        Image(systemName: "bolt.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.orange, in: Circle())
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    // A Link, not Button(intent:). The intent button rendered but never
                    // fired on device inside an expanded region, and `Shared/` compiling
                    // into both app and widget gives the intent two module-qualified types
                    // besides. A URL sidesteps both problems.
                    Link(destination: URL(string: "\(AppGroup.urlScheme)://newbreak")!) {
                        Image(systemName: isOver(context) ? "hourglass" : "xmark")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(isOver(context) ? Color.blue : Color.gray, in: Circle())
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isOver(context) {
                            Text("Break's over")
                                .font(.headline)
                                .foregroundStyle(.orange)
                        } else {
                            countdown(context, font: .title3.monospacedDigit().bold())
                        }
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("Start Work").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(isOver(context) ? "\(context.attributes.appName) is blocked again"
                                             : context.state.contextNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("Dismiss").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "sailboat.fill")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                if isOver(context) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    countdown(context, font: .caption.monospacedDigit())
                        .frame(maxWidth: 44)
                }
            } minimal: {
                Image(systemName: "sailboat.fill")
                    .foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }

    // MARK: -

    private func lockScreen(_ context: ActivityViewContext<BreakActivityAttributes>) -> some View {
        VStack(spacing: 10) {
        HStack(spacing: 14) {
            Image(systemName: "sailboat.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(isOver(context)
                     ? "Break's over — \(context.attributes.appName)"
                     : "Break — \(context.attributes.appName)")
                    .font(.subheadline.weight(.semibold))
                if !context.state.contextNote.isEmpty {
                    Text(context.state.contextNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressView(timerInterval: context.state.startedAt...context.state.endsAt,
                             countsDown: false)
                    .tint(.orange)
                    .labelsHidden()
            }

            Spacer(minLength: 4)

            if isOver(context) {
                Text("Over").font(.title3.bold()).foregroundStyle(.orange)
            } else {
                countdown(context, font: .title2.monospacedDigit().bold())
                    .frame(maxWidth: 78)
            }
        }
        controls
        }
        .padding()
    }

    /// The controls that make this surface useful.
    ///
    /// They live here rather than on the shield because the Dynamic Island is reliably in
    /// front of the user while a break runs — it does not depend on `DeviceActivityMonitor`
    /// firing, nor on iOS choosing to re-render a cached shield.
    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            // A deep link rather than an App Intent. `Shared/` is compiled into both the app
            // and the widget, so an intent defined there exists twice — as
            // `VoyageFocusWidgets.StartWorkFromBreakIntent` and
            // `POC_Shortcuts.StartWorkFromBreakIntent`. An intent with `openAppWhenRun`
            // hands execution to the app process, which then looks for a type that does not
            // match, and the tap does nothing at all. A URL has no such ambiguity.
            Link(destination: URL(string: "\(AppGroup.urlScheme)://endbreak")!) {
                Label("Start Work", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
            }

            // Stays an intent: it runs entirely inside the widget process, so there is no
            // handoff and no ambiguity.
            Button(intent: DismissBreakActivityIntent()) {
                Text("Dismiss")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.gray)
        }
    }

    private func countdown(_ context: ActivityViewContext<BreakActivityAttributes>,
                           font: Font) -> some View {
        Text(timerInterval: context.state.startedAt...context.state.endsAt,
             countsDown: true)
            .font(font)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.orange)
    }
}
