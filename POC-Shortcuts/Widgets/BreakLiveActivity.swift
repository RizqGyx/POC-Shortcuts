import SwiftUI
import WidgetKit
import ActivityKit

/// The Dynamic Island + Lock Screen presentation of a running break.
///
/// The countdown uses `Text(timerInterval:)` throughout, which SwiftUI ticks by itself from
/// the end date. Nothing here polls, and the app does not push updates — a third-party app
/// cannot run a background timer, so a self-driving view is the only accurate option.
struct BreakLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BreakActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.appName, systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context, font: .title3.monospacedDigit().bold())
                        .frame(maxWidth: 70)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Break in progress")
                            .font(.subheadline.weight(.semibold))
                        if !context.state.contextNote.isEmpty {
                            Text(context.state.contextNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(timerInterval: context.state.startedAt...context.state.endsAt,
                                     countsDown: false)
                            .tint(.orange)
                            .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "sailboat.fill")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                countdown(context, font: .caption.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "sailboat.fill")
                    .foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }

    // MARK: -

    private func lockScreen(_ context: ActivityViewContext<BreakActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "sailboat.fill")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Break — \(context.attributes.appName)")
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

            countdown(context, font: .title2.monospacedDigit().bold())
                .frame(maxWidth: 78)
        }
        .padding()
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
