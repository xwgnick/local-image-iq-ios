import SwiftUI

@main
@MainActor
struct LocalImageIQApp: App {
    @StateObject private var state = AppState(translationPreferences: .standard)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .tint(IQStyle.accent)
                .task { state.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { state.enterBackground() }
                    else if phase == .active { state.enterForeground() }
                }
        }
    }
}