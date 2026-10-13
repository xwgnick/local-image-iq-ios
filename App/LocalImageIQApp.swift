import SwiftUI

@main
@MainActor
struct LocalImageIQApp: App {
    @StateObject private var state = AppState(
        translationPreferences: .standard,
        startupHistory: StartupHistoryStore(defaults: .standard),
        startupContext: { StartupContext.current() },
        textSearchPreferences: .standard,
        queryHistoryStore: QueryHistoryStore())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if state.showsHome {
                    ContentView(state: state)
                } else {
                    StartupView(state: state)
                }
            }
                .statusBarHidden(!state.showsHome)
                .tint(IQStyle.accent)
                .task { state.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { state.enterBackground() }
                    else if phase == .active { state.enterForeground() }
                }
        }
    }
}