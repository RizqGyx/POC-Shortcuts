import SwiftUI

struct RootView: View {

    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.hasOnboarded {
                WorkModeView()
            } else {
                OnboardingView()
            }
        }
        // The break screen is presented over whatever is showing, because the request can
        // arrive at any moment from an automation or a notification tap.
        .sheet(item: $state.pendingRequest) { request in
            BreakConfigView(request: request)
        }
    }
}

/// Honesty labels, shown throughout the UI so it is always clear which parts of the flow
/// iOS genuinely supports.
enum Capability: String {
    case real       = "REAL"
    case partial    = "PARTIAL"
    case simulated  = "SIMULATED"

    var color: Color {
        switch self {
        case .real:      return .green
        case .partial:   return .orange
        case .simulated: return .red
        }
    }
}

struct CapabilityBadge: View {
    let capability: Capability
    var note: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(capability.rawValue)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(capability.color.opacity(0.18), in: Capsule())
                .foregroundStyle(capability.color)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
