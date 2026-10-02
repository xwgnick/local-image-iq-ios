import SwiftUI

@main
@MainActor
struct LocalImageIQApp: App {
    @StateObject private var state = AppState(translationPreferences: .standard)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if state.launchPhase == .ready {
                    ContentView(state: state)
                } else {
                    StartupView(state: state)
                }
            }
                .statusBarHidden(state.launchPhase != .ready)
                .tint(IQStyle.accent)
                .task { state.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { state.enterBackground() }
                    else if phase == .active { state.enterForeground() }
                }
        }
    }
}