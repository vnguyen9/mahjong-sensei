import SwiftUI
import DesignSystem

@main
struct MahjongSenseiApp: App {
    @State private var appState = AppState()

    init() {
        MJFont.registerBundledSerif(from: .main)
        #if DEBUG
        TrackerDiagnosticExport.purgeAbandonedExports()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}
