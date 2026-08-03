import SwiftUI

/// The evidence trail. Four separate processes write here, and this is the only place you
/// can see them on one timeline — extensions cannot be attached to the Xcode debugger in
/// any convenient way, so this substitutes for a console.
struct DiagnosticsView: View {

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeService
    @State private var events: [LogEvent] = []
    @State private var tokenNames: [String: ShieldedAppInfo] = [:]

    var body: some View {
        List {
            Section {
                Button("Read installed apps") {
                    Task { await screenTime.loadInstalledApps() }
                }
                .disabled(!screenTime.hasDataAccess)

                if !screenTime.hasDataAccess {
                    Text("Requires iOS 26.4+ and \"Approved + data access\" authorization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(screenTime.installedApps.prefix(30), id: \.bundleID) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.subheadline.weight(.medium))
                        Text(app.bundleID)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text("FamilyActivityData")
                    Spacer()
                    CapabilityBadge(capability: .real, note: "iOS 26.4+")
                }
            } footer: {
                Text("""
                Real bundle identifiers and display names, straight to the app. Before iOS \
                26.4 this was impossible — selections were opaque tokens and only the shield \
                extension could read a name.
                """)
            }

            Section {
                ForEach(["ShieldConfiguration", "ShieldAction", "DeviceActivityMonitor"], id: \.self) { process in
                    LabeledContent(process) {
                        if let last = events.first(where: { $0.process == process }) {
                            Text(last.timestamp, style: .relative).foregroundStyle(.green)
                        } else {
                            Text("never ran").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                }
            } header: {
                Text("Extension heartbeat")
            } footer: {
                Text("""
                Extensions run in their own processes and don't appear in Xcode's console \
                when it is attached to the app, so "never ran" here is the only reliable \
                signal that one isn't being invoked — iOS caches shield configurations, so \
                ShieldConfiguration in particular may not run on every block.
                """)
            }

            Section("Context payload (App Group)") {
                if let grant = SharedStore.activeGrant {
                    Text(json(grant))
                        .font(.system(.caption, design: .monospaced))
                } else if let request = SharedStore.pendingRequest {
                    Text(json(request))
                        .font(.system(.caption, design: .monospaced))
                } else {
                    Text("Nothing pending.").foregroundStyle(.secondary)
                }
            }

            Section {
                if tokenNames.isEmpty {
                    Text("Empty. Populates the first time a shield is actually shown on device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tokenNames.sorted(by: { $0.value.name < $1.value.name }), id: \.key) { key, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.subheadline.weight(.medium))
                            Text(entry.bundleID ?? "bundle ID unknown")
                                .font(.system(.caption2, design: .monospaced))
                            Text(key.prefix(24) + "…")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Token → name map")
            } footer: {
                Text("Written by the shield configuration extension — the only process on the device that can read an app's real name.")
            }

            Section("Recent breaks") {
                if SharedStore.grantHistory.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(SharedStore.grantHistory) { grant in
                        VStack(alignment: .leading) {
                            Text("\(grant.appName) — \(grant.durationMinutes) min")
                                .font(.subheadline)
                            Text(grant.contextNote.isEmpty ? "no context" : grant.contextNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Cross-process log") {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.process)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color(for: event.process))
                        Text(event.message).font(.caption)
                        Text(event.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Clear log", role: .destructive) {
                    SharedStore.clearLog()
                    reload()
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        events = SharedStore.events
        tokenNames = SharedStore.tokenInfo
    }

    private func color(for process: String) -> Color {
        switch process {
        case "ShieldConfiguration":   return .purple
        case "ShieldAction":          return .orange
        case "DeviceActivityMonitor": return .blue
        case "StartBreakIntent":      return .green
        default:                      return .secondary
        }
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else { return "—" }
        return string
    }
}
