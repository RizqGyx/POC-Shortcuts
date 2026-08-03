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

    @State private var minutes = BreakDurations.options[1]
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

                Section("How long?") {
                    Picker("Duration", selection: $minutes) {
                        ForEach(BreakDurations.options, id: \.self) { option in
                            Text("\(option) min").tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
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
                        state.commitBreak(request: pending, minutes: minutes, context: contextNote)
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
