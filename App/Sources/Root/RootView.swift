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
            case "result":     ResultView(session: Self.demoResultSession()) {}
            case "correct":      ScanFlowView(debugRoute: .correct)
            case "correct-long": ScanFlowView(debugRoute: .correct, debugHand: MockHands.longRow)
            case "correct-emoji": ScanFlowView(debugRoute: .correct, debugHand: MockHands.bonusSampler)
            case "lookup":     ScanFlowView(debugScanMode: .lookup)
            case "context":    ScanFlowView(debugRoute: .context)
            case "coach":      ScanFlowView(debugRoute: .coach)
            case "coach-table": ScanFlowView(debugRoute: .coach, debugTable: true)
            case "learn":      LearnView()
            case "settings":   SettingsView()
            case "basics":     NavigationStack { LearnBasicsView() }
            case "cheatsheet": NavigationStack { ScoringCheatSheetView() }
            case "dictionary": NavigationStack { TileDictionaryView() }
            case "winds":      NavigationStack { WindExplainerView() }
            case "rules":      NavigationStack { HouseRulesView() }
            default:           MainTabView()
            }
        } else if app.hasOnboarded {
            MainTabView()
        } else {
            OnboardingView()
        }
    }

    /// A session preloaded with the sample winning hand (debug `MJ_SCREEN=result`).
    private static func demoResultSession() -> ScanSession {
        let session = ScanSession()
        session.start(with: MockHands.winning)
        return session
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
                case .scan:     ScanFlowView()
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
