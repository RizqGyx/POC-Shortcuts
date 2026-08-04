import SwiftUI
import FamilyControls

struct WorkModeView: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeService

    @State private var showPicker = false
    @State private var testAppName = "Instagram"

    private var onBreak: Bool {
        guard let grant = state.activeGrant else { return false }
        return grant.isActive
    }

    var body: some View {
        NavigationStack {
            Form {
                if let banner = state.bannerMessage {
                    Section {
                        Label(banner, systemImage: "info.circle")
                            .font(.footnote)
                    }
                }

                Section {
                    if state.isWorkModeActive {
                        // Work Mode stays on during a break — the shields are lifted, not
                        // the session. Showing "Work Mode Active" alone made it look like
                        // the break hadn't taken effect.
                        LabeledContent("Status") {
                            if onBreak {
                                Text("On a break").foregroundStyle(.orange).bold()
                            } else {
                                Text("Focusing").foregroundStyle(.green).bold()
                            }
                        }
                        if let started = SharedStore.workModeStartedAt {
                            LabeledContent("Session started") {
                                Text(started, style: .relative)
                            }
                        }
                        LabeledContent("Shielded apps") {
                            if onBreak {
                                Text("0 of \(screenTime.selectedAppCount) — all unlocked")
                                    .foregroundStyle(.orange)
                            } else {
                                Text("\(screenTime.selectedAppCount)")
                            }
                        }
                    } else {
                        Text("Stay focused.\nWe'll handle your breaks.")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("Work Mode")
                }

                if let grant = state.activeGrant, grant.isActive {
                    Section {
                        LabeledContent("Opened from", value: grant.appName)
                        LabeledContent("Duration", value: BreakDurations.label(grant.durationSeconds))
                        LabeledContent("Context", value: grant.contextNote.isEmpty ? "—" : grant.contextNote)
                        LabeledContent("Ends") { Text(grant.expiresAt, style: .relative) }
                        Button("End Break Now", role: .destructive) {
                            screenTime.revokeExpiredGrant(reason: "ended manually", expired: false)
                            state.refresh()
                        }
                    } header: {
                        HStack {
                            Text("Break in progress — all apps unlocked")
                            Spacer()
                            CapabilityBadge(capability: .partial, note: "re-block is best-effort")
                        }
                    }
                }

                if let outcome = state.lastOutcome {
                    Section {
                        switch outcome {
                        case .opened(let scheme):
                            Label("Opened via \(scheme)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .noScheme(let name), .failed(let name):
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Couldn't open \(name) directly", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("""
                                Either the app registers no URL scheme, or it isn't installed. \
                                The supported fallback is a one-action "Open App" shortcut you \
                                make yourself, which we can then run by name.
                                """)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Button("Run shortcut \"Open \(name)\"") {
                                    Task { await AppLaunchService.openViaShortcut(named: "Open \(name)") }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Return to app")
                            Spacer()
                            CapabilityBadge(capability: outcome.succeeded ? .real : .partial)
                        }
                    }
                }

                Section {
                    Button(state.isWorkModeActive ? "End Work Mode" : "Start Work Mode") {
                        state.isWorkModeActive ? state.endWorkMode() : state.startWorkMode()
                    }
                    .disabled(!screenTime.isAuthorized)

                    Button("Change Distracting Apps") { showPicker = true }
                        .disabled(!screenTime.isAuthorized)
                }

                Section {
                    HStack {
                        TextField("App name", text: $testAppName)
                        Button("Test") {
                            state.simulateRequest(appName: testAppName)
                        }
                        .buttonStyle(.bordered)
                    }
                } header: {
                    HStack {
                        Text("Test the break flow")
                        Spacer()
                        CapabilityBadge(capability: .simulated, note: "the trigger only")
                    }
                } footer: {
                    Text("""
                    Fires the break screen by hand, as if an automation had called it. Only \
                    the trigger is faked here — persistence, the shield lift and the return \
                    to the app all run for real.
                    """)
                }

                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                    NavigationLink {
                        AutomationGuideView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shortcuts Automation")
                            Text(PlatformCapabilities.needsShortcutsFallback
                                 ? "Fallback — needed on this iOS version"
                                 : "Not needed here; the block screen opens this app directly")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("More")
                }
            }
            .navigationTitle("Voyage Focus")
            .familyActivityPicker(isPresented: $showPicker, selection: $screenTime.selection)
            .onChange(of: showPicker) { _, isShowing in
                if !isShowing { screenTime.persistSelection() }
            }
        }
    }
}
