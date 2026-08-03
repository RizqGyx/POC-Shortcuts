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

    /// Set only when iOS refused to identify the app and the user picked it themselves.
    @State private var manualPick: AppLaunchService.Known?

    /// The request actually saved — `request` plus any manual correction.
    private var effective: BreakRequest {
        var resolved = request
        if let manualPick {
            resolved.appName = manualPick.name
            resolved.appBundleID = manualPick.bundleID
        }
        return resolved
    }

    private var unresolved: Bool {
        AppLaunchService.isUnresolved(name: effective.appName, bundleID: effective.appBundleID)
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

                if unresolved {
                    Section {
                        Picker("App", selection: $manualPick) {
                            Text("Choose…").tag(nil as AppLaunchService.Known?)
                            ForEach(AppLaunchService.catalog) { app in
                                Text(app.name).tag(app as AppLaunchService.Known?)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Which app?")
                            Spacer()
                            CapabilityBadge(capability: .partial, note: "iOS didn't say")
                        }
                    } footer: {
                        Text("""
                        iOS did not identify the app this time. The shield extension gets a \
                        token with no name attached, and `Application.token` is nil in the one \
                        extension that *can* read names — so there is nothing to resolve. \
                        Picking here lets the return-to-app step still work.
                        """)
                    }
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
                    App Group container, lifts the Screen Time shield on \(request.appName), \
                    arms the re-block, and then opens \(request.appName) by its URL scheme.
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
