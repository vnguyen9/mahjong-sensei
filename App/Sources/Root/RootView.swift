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
            #if DEBUG
            case let s where s.hasPrefix("coach-live"): Self.coachLiveDebugView(s)
            #endif
            case "learn":      LearnView()
            case "settings":   SettingsView()
            case "tiles", "basics", "dictionary": NavigationStack { TilesView() }
            case "cheatsheet": NavigationStack { ScoringCheatSheetView() }
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

    #if DEBUG
    /// Builds a Coach Live debug scene for `MJ_SCREEN=coach-live*` (UI plan
    /// §15) — presented directly, no cover needed: the Simulator has no
    /// camera, so `CoachLiveView`'s placeholder feed pane covers this fine,
    /// and every scene is driven entirely by `MockCoachLive`.
    ///
    /// Scene list: `coach-live` (rest split, Map), `-action` / `-think`
    /// (the other two breathing splits), `-counts` / `-events` (tab
    /// selected), `-setup` (the setup card), `-handend` (HandEndedCard,
    /// table-clear), `-win` (HandEndedCard, self-draw win) — the plan's 8
    /// named scenes — plus `-corrections`,
    /// added here to also cover the four correction sheets directly (the
    /// task brief's own scene list names "corrections" where the plan's
    /// table names "setup"; both are implemented rather than guessing which
    /// one to drop).
    private static func coachLiveDebugView(_ scene: String) -> some View {
        let session = MockCoachLive.make(scene: scene)
        let initialTab: LiveTab = scene.hasSuffix("counts") ? .counts : scene.hasSuffix("events") ? .events : .map
        // Mock scenes land on the live view directly (they're driven by
        // `MockCoachLive`, not a real begun session); only `-setup` (and its
        // `-resume` variant, plan A6's synthetic resume-card screenshot hook
        // — see `CoachLiveSetupView.loadResumable`) shows the card. Explicit
        // `.live` because the production default is now `.setup`.
        let flowState: CoachLiveFlowView.FlowState =
            (scene == "coach-live-setup" || scene == "coach-live-setup-resume") ? .setup : .live
        let sheet: CoachLiveSheet? = scene == "coach-live-corrections" ? .assign : nil
        return CoachLiveFlowView(session: session, debugFlowState: flowState,
                                 debugInitialTab: initialTab, debugSheet: sheet)
    }
    #endif
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
