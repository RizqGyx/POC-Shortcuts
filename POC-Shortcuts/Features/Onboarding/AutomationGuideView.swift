import SwiftUI

/// A fallback path, not part of normal setup.
///
/// On iOS 26.5+ the shield opens Voyage Focus by itself, so none of this is needed — which
/// is why apps like Jomo and Opal never mention Shortcuts. Below 26.5 the shield cannot
/// route into an app, and a personal automation is the only alternative way in.
///
/// Voyage Focus's *actions* register themselves automatically. The "When Instagram is
/// Opened" trigger is a personal automation, and iOS exposes no API for creating those, so
/// this screen guides rather than pretends.
struct AutomationGuideView: View {

    private let steps: [(String, String)] = [
        ("Open the Shortcuts app",
         "Tap the button below, then choose the Automation tab."),
        ("Tap + → New Automation",
         "Scroll to App and select it."),
        ("Choose your distracting app",
         "Pick Instagram (or TikTok, YouTube…). Leave \"Is Opened\" checked."),
        ("Set it to Run Immediately",
         "Turn off \"Ask Before Running\" so it doesn't interrupt you every time."),
        ("Add the action \"Start a Break\"",
         "Search for Voyage Focus. The action is already there — it registered itself on install."),
        ("Fill in App Name",
         "Type the app's name exactly, e.g. Instagram. This is how Voyage Focus learns which app you wanted."),
        ("Tap Done",
         "Repeat for each distracting app. There is no way to batch this."),
    ]

    var body: some View {
        List {
            if !PlatformCapabilities.needsShortcutsFallback {
                Section {
                    Label {
                        Text("This device doesn't need any of this. The block screen opens Voyage Focus directly. These steps are kept so the fallback path can still be tested.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }

            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(step.0)")
                            .font(.subheadline.weight(.semibold))
                        Text(step.1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("One automation per app")
            }

            Section {
                Button {
                    Task { await AppLaunchService.openShortcutsApp() }
                } label: {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }
            }

            Section {
                Text("""
                Why you have to do this by hand: there is no public API — in App Intents or \
                anywhere else — for an app to create a personal automation. Anything \
                claiming otherwise is describing App Shortcuts, which are a different \
                feature (actions, not triggers).

                Why we use an automation at all: the Screen Time shield genuinely blocks \
                apps, but its extension is not allowed to open Voyage Focus. The automation \
                is the only supported route that lands you in this app with the requested \
                app's name attached.

                What it costs: the target app flashes on screen for about a second before \
                Voyage Focus takes over. It is a redirect, not a block. The Screen Time \
                shield is the real block, running underneath.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Why this is manual")
                    Spacer()
                    CapabilityBadge(capability: .partial)
                }
            }
        }
        .navigationTitle("Automation Setup")
        .navigationBarTitleDisplayMode(.inline)
    }
}
