import SwiftUI

/// The screen the whole product concept is built around.
///
/// Note that this cannot be the shield itself — the shield is drawn by the system and
/// supports a title, subtitle and two buttons, nothing more. Duration pickers and text
/// fields have to live in the app, which is precisely why getting the user *into* the app
/// is the hard part of this problem.
struct BreakConfigView: View {

    let request: BreakRequest

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// The app is identified before this screen ever appears — the token→app link is made
    /// once during setup. Asking here would be both an extra step and unsafe: the user could
    /// pick YouTube while actually opening Instagram, and we would reopen the wrong app.
    private var effective: BreakRequest { request }

    private var unresolved: Bool {
        AppLaunchService.isUnresolved(name: request.appName, bundleID: request.appBundleID)
    }

    @State private var seconds = BreakDurations.options[3]
    @State private var contextNote = ""
    @State private var isSaving = false

    private let suggestions = ["Quick social check", "Replying to a message", "Lunch break", "Doomscrolling, honestly"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Taking a break?")
                        .font(.title2.bold())
                    Text(unresolved
                         ? "You're about to open a blocked app."
                         : "You're about to open \(effective.appName).")
                        .foregroundStyle(.secondary)
                    if unresolved {
                        Text("iOS didn't identify this app, so it can't be reopened automatically. Your break still applies to every blocked app.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    HStack {
                        Text("Intercepted via \(request.source.displayName)")
                        Spacer()
                        CapabilityBadge(
                            capability: request.source == .manual ? .simulated : .real
                        )
                    }
                    .font(.caption2)
                }

                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                              spacing: 8) {
                        ForEach(BreakDurations.options, id: \.self) { option in
                            Button {
                                seconds = option
                            } label: {
                                Text(BreakDurations.label(option))
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(seconds == option ? .accentColor : .secondary)
                        }
                    }

                    Stepper(
                        value: Binding(
                            get: { seconds },
                            set: { seconds = BreakDurations.clamp($0) }
                        ),
                        in: BreakDurations.range,
                        step: BreakDurations.step(for: seconds)
                    ) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(BreakDurations.label(seconds))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    HStack {
                        Text("How long?")
                        Spacer()
                        if seconds < BreakDurations.developmentCeiling {
                            CapabilityBadge(capability: .partial, note: "dev length")
                        }
                    }
                } footer: {
                    if seconds < BreakDurations.developmentCeiling {
                        Text("""
                        Under a minute is for testing the expiry path quickly. The usage-based \
                        re-block can't be armed below one minute — DeviceActivity thresholds \
                        are whole minutes — so a break this short relies on the wall-clock \
                        trigger alone.
                        """)
                    }
                }

                Section("What's the context?") {
                    TextField("e.g. Quick social check", text: $contextNote)
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { contextNote = suggestion }
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        isSaving = true
                        let pending = effective
                        // Commit, close the sheet, *then* launch. See AppState for why the
                        // launch cannot happen in the same breath as the unshield.
                        state.commitBreak(request: pending, seconds: seconds, context: contextNote)
                        dismiss()
                        Task {
                            await state.openRequestedApp(pending)
                            isSaving = false
                        }
                    } label: {
                        HStack {
                            Text("Save & Continue")
                            Spacer()
                            if isSaving { ProgressView() }
                        }
                    }
                    .disabled(isSaving)
                } footer: {
                    Text("""
                    Saving writes {requestedApp, breakDuration, context} into the shared \
                    App Group container, lifts the Screen Time shield on every blocked app, \
                    arms the re-block, and reopens the app you came from by its URL scheme.
                    """)
                }
            }
            .navigationTitle("Break")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        state.dismissRequest()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }
}
