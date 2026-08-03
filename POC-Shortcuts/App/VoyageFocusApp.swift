import SwiftUI

@main
struct VoyageFocusApp: App {

    @StateObject private var state = AppState()
    @StateObject private var screenTime = ScreenTimeService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(screenTime)
                .onOpenURL { state.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    // The only reliable moment to pick up whatever the shield extensions
                    // left for us in the App Group while we weren't running.
                    if phase == .active {
                        screenTime.refreshAuthorizationStatus()
                        state.refresh()
                    }
                }
        }
    }
}
