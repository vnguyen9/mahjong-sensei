import SwiftUI
import DesignSystem
import Recognition

/// Gates onboarding, then shows the main tabbed app.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        // Debug hook: `SIMCTL_CHILD_MJ_SCREEN=<onboarding|result|scan|learn|settings>`
        // forces an initial screen for screenshots / UI checks.
        if let forced = ProcessInfo.processInfo.environment["MJ_SCREEN"] {
            switch forced {
            case "onboarding": OnboardingView()
            case "result":     ResultView(result: MockHands.winning)
            default:           MainTabView()
            }
        } else if app.hasOnboarded {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}

/// The three-tab shell with the floating pill tab bar (spec §3.3).
struct MainTabView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .bottom) {
            Group {
                switch app.selectedTab {
                case .scan:     ScanView()
                case .learn:    LearnView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MJTabBar(selection: $app.selectedTab)
                .padding(.bottom, 6)
        }
    }
}
