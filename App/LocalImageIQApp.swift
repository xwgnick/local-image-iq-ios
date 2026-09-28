import SwiftUI

@main
@MainActor
struct LocalImageIQApp: App {
    @StateObject private var state = AppState(translationPreferences: .standard)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.73, green: 0.57, blue: 1))
                .task { state.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { state.enterBackground() }
                    else if phase == .active { state.enterForeground() }
                }
        }
    }
}