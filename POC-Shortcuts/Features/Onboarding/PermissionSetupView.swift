import SwiftUI
import FamilyControls

/// Setup is two required steps: grant Screen Time, pick apps.
///
/// App identity is resolved automatically via FamilyActivityData — there is no manual
/// linking step anywhere in the app. Step 3 only reports whether that succeeded, and offers
/// the one action that can fix it when it hasn't.
///
/// Nothing about Shortcuts appears here on a current device. That matches how Jomo, Opal
/// and ClearSpace behave — they are pure Screen Time API apps and never ask the user to
/// build an automation. iOS 26.5's `openParentalControlsApp` is what makes that possible
/// for us too; below that version the fallback section appears automatically.
struct PermissionSetupView: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeService

    @State private var showPicker = false
    @State private var notificationsRequested = false

    private var authorized: Bool { screenTime.isAuthorized }
    /// Linking is part of being ready, not an optional extra. If a token has no identity,
    /// the break flow cannot reopen that app and the user hits a dead end mid-break.
    private var ready: Bool { authorized && screenTime.selectedAppCount > 0 }

    var body: some View {
        Form {
            // 1 ── required ────────────────────────────────────────────────
            Section {
                LabeledContent("Status") {
                    Text(statusText)
                        .foregroundStyle(authorized ? .green : .secondary)
                }
                Button(authorized ? "Re-check Authorization" : "Request Screen Time Access") {
                    Task {
                        if authorized {
                            screenTime.refreshAuthorizationStatus()
                        } else {
                            await screenTime.requestAuthorization()
                        }
                    }
                }
                if let error = screenTime.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                HStack {
                    Text("1. Screen Time")
                    Spacer()
                    CapabilityBadge(capability: .real)
                }
            } footer: {
                Text("""
                Voyage Focus needs Screen Time access to block distracting apps. Apple \
                presents its own consent sheet — we cannot pre-approve or skip it.

                Requires a physical device; this does not work in the Simulator.
                """)
            }

            // 2 ── required ────────────────────────────────────────────────
            Section {
                Button("Choose Distracting Apps") { showPicker = true }
                    .disabled(!authorized)
                LabeledContent("Selected") {
                    Text("\(screenTime.selectedAppCount) app(s)")
                        .foregroundStyle(screenTime.selectedAppCount > 0 ? .green : .secondary)
                }
            } header: {
                HStack {
                    Text("2. Pick Apps")
                    Spacer()
                    CapabilityBadge(capability: .real)
                }
            } footer: {
                Text("Apple's own picker. That's the whole setup — Voyage Focus works out app identities on its own from here.")
            }

            // 3 ── automatic, nothing for the user to do ──────────────────
            Section {
                switch screenTime.detectionState {
                case .ready(let linked):
                    Label("\(linked) app(s) indexed — blocked apps can be reopened", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .noAppsSelected:
                    Text("Pick some apps first.").foregroundStyle(.secondary)
                case .unsupportedOS:
                    Label("Requires iOS 26.4 or later", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .needsDataAccess where screenTime.hasDataAccess:
                    // Entitlement and data access are both in place, yet iOS still returns
                    // no names. Nothing the user does in this app changes that, so don't
                    // pretend otherwise.
                    VStack(alignment: .leading, spacing: 8) {
                        Label("iOS isn't returning app names", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("""
                        Screen Time access is fully granted, but iOS reports no name for your \
                        blocked apps. Blocking and breaks still work — only reopening the app \
                        automatically after Save does not.

                        Worth checking: Settings → Screen Time must be switched on for usage \
                        data to exist at all.
                        """)
                        .font(.caption)
                        Button("Re-pick Apps") { showPicker = true }
                            .buttonStyle(.bordered)

                        Divider()

                        // The decisive unknown: the shield configuration extension is the
                        // one process that can read an app's name without any entitlement.
                        // If it runs, identification is fixable; if it never runs, it is not.
                        LabeledContent("Shield extension") {
                            if let last = SharedStore.events.first(where: { $0.process == "ShieldConfiguration" }) {
                                Text(last.timestamp, style: .relative).foregroundStyle(.green)
                            } else {
                                Text("never ran").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)

                        LabeledContent("Last shielded app") {
                            Text(SharedStore.lastShieldedApp?.name ?? "none recorded")
                                .foregroundStyle(SharedStore.lastShieldedApp == nil ? .orange : .green)
                        }
                        .font(.caption)

                        Text("Open a blocked app once, come back here, and pull to refresh to update these.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                case .needsDataAccess:
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Screen Time data access needed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(screenTime.lastError ?? """
                        Voyage Focus can block your apps, but can't tell which one you opened, \
                        so it can't reopen it after a break.
                        """)
                        .font(.caption)
                        Button("Reset Screen Time Access") {
                            Task { await screenTime.resetAuthorization() }
                        }
                        .buttonStyle(.bordered)
                        Text("Resetting clears your app selection — old tokens stop working once authorization is revoked.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("3. App Detection")
                    Spacer()
                    CapabilityBadge(capability: .real, note: "automatic")
                }
            } footer: {
                Text("""
                Handled entirely by the app through FamilyActivityData — there is nothing to \
                configure. Granting authorization again is the only way to add data access, \
                because iOS ignores a repeat request while a grant already exists.
                """)
            }

            // 4 ── optional ────────────────────────────────────────────────
            Section {
                Button("Allow Notifications") {
                    Task {
                        await state.requestNotificationPermission()
                        notificationsRequested = true
                    }
                }
                if notificationsRequested {
                    Text("Requested.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text(PlatformCapabilities.shieldCanOpenApp ? "4. Notifications (optional)"
                                                               : "4. Notifications (required)")
                    Spacer()
                    CapabilityBadge(capability: .real)
                }
            } footer: {
                if PlatformCapabilities.shieldCanOpenApp {
                    Text("""
                    Only used to tell you when a break is ending. The block screen opens \
                    Voyage Focus directly on this iOS version, so nothing depends on this.
                    """)
                } else {
                    Text("""
                    Load-bearing on this iOS version. The block screen cannot open Voyage \
                    Focus directly here, so a notification is the only way it can reach you. \
                    iOS 26.5 removes this constraint.
                    """)
                }
            }

            // 4 ── only on older iOS ───────────────────────────────────────
            if PlatformCapabilities.needsShortcutsFallback {
                Section {
                    NavigationLink("Set Up the Automation") { AutomationGuideView() }
                } header: {
                    HStack {
                        Text("5. Shortcuts (older iOS only)")
                        Spacer()
                        CapabilityBadge(capability: .partial, note: "manual")
                    }
                } footer: {
                    Text("""
                    Optional fallback. On iOS below 26.5 the block screen cannot route you \
                    into Voyage Focus, so a Shortcuts automation is the alternative way in. \
                    iOS provides no API to create one — it has to be built by hand, per app.
                    """)
                }
            }

            Section {
                Button("Finish Setup") { state.completeOnboarding() }
                    .disabled(!ready)
            } footer: {
                if !ready {
                    Text(screenTime.unmappedAppCount > 0
                         ? "Link your blocked apps so Voyage Focus can reopen them after a break."
                         : "Grant Screen Time access and pick at least one app to continue.")
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Setup")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $showPicker, selection: $screenTime.selection)
        .onChange(of: showPicker) { _, isShowing in
            guard !isShowing else { return }
            screenTime.persistSelection()
            // Resolve names automatically first; only surface the screen if anything is
            // still unidentified.
            Task { await screenTime.autoLinkSelectedApps(force: true) }
        }
    }

    private var statusText: String { screenTime.statusDescription }
}
