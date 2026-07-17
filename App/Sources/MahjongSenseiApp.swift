import SwiftUI
import DesignSystem

@main
struct MahjongSenseiApp: App {
    @State private var appState = AppState()

    init() {
        MJFont.registerBundledSerif(from: .main)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}
