import SwiftUI
import FamilyControls

/// Setup is deliberately two required steps: grant Screen Time, pick apps.
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
                Text("Apple's own picker. That's the whole setup — you're ready after this.")
            }

            // 3 ── optional ────────────────────────────────────────────────
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
                    Text(PlatformCapabilities.shieldCanOpenApp ? "3. Notifications (optional)"
                                                               : "3. Notifications (required)")
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
                        Text("4. Shortcuts (older iOS only)")
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
                    Text("Grant Screen Time access and pick at least one app to continue.")
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Setup")
        .navigationBarTitleDisplayMode(.inline)
        .familyActivityPicker(isPresented: $showPicker, selection: $screenTime.selection)
        .onChange(of: showPicker) { _, isShowing in
            if !isShowing { screenTime.persistSelection() }
        }
    }

    private var statusText: String {
        if #available(iOS 26.4, *), screenTime.authorizationStatus == .approvedWithDataAccess {
            return "Approved + data access"
        }
        switch screenTime.authorizationStatus {
        case .approved:      return "Approved"
        case .denied:        return "Denied"
        case .notDetermined: return "Not requested"
        // Plain `default` rather than `@unknown default`: `.approvedWithDataAccess` is
        // handled above under an availability check, which the compiler cannot see as
        // covering the case here.
        default:             return "Unknown"
        }
    }
}
