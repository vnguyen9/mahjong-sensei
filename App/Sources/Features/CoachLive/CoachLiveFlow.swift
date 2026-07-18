import SwiftUI
import UIKit
import DesignSystem
import MahjongCore

/// UserDefaults-backed settings for Coach Live — the ONLY two, following the
/// `TileDetector.prefersHighAccuracy` pattern exactly (UI plan §13).
enum CoachLivePrefs {
    static let blurKey = "coachLiveBlursFeed"
    static let breatheKey = "coachLiveAutoBreathes"

    /// Unset → true (blur on) — privacy default.
    static var blursFeed: Bool {
        get { UserDefaults.standard.object(forKey: blurKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: blurKey) }
    }
    /// Unset → true (auto-breathing on).
    static var autoBreathes: Bool {
        get { UserDefaults.standard.object(forKey: breatheKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: breatheKey) }
    }
}

/// The Coach Live cover root: `.setup` (round/seat wind, two taps) → `.live`
/// (the split-screen tracker), a crossfade rather than another modal (UI
/// plan §6). Owns the idle-timer for the whole session.
///
/// Takes `onExit`/`onScoreHandoff` as plain closures rather than reading
/// `ScanCoordinator` from the environment, so this same view works both
/// hosted in `ScanFlowView`'s `fullScreenCover` (real closures) and hosted
/// directly by `RootView`'s `MJ_SCREEN` debug routes (no coordinator in the
/// hierarchy at all).
struct CoachLiveFlowView: View {
    let session: CoachLiveSession
    /// Debug: force straight into `.setup` (MJ_SCREEN `coach-live-setup`).
    var debugFlowState: FlowState? = nil
    /// Debug: force an initial state-pane tab (MJ_SCREEN `-counts`/`-events`).
    var debugInitialTab: LiveTab = .map
    /// Debug: present a correction sheet immediately (MJ_SCREEN `-corrections`).
    var debugSheet: CoachLiveSheet? = nil
    var onExit: () -> Void = {}
    var onScoreHandoff: () -> Void = {}

    enum FlowState { case setup, live }
    @State private var flowState: FlowState
    @Environment(\.scenePhase) private var scenePhase

    init(session: CoachLiveSession, debugFlowState: FlowState? = nil, debugInitialTab: LiveTab = .map,
        debugSheet: CoachLiveSheet? = nil, onExit: @escaping () -> Void = {}, onScoreHandoff: @escaping () -> Void = {}) {
        self.session = session
        self.debugFlowState = debugFlowState
        self.debugInitialTab = debugInitialTab
        self.debugSheet = debugSheet
        self.onExit = onExit
        self.onScoreHandoff = onScoreHandoff
        // Production enters through the two-tap setup card — that card's Start
        // button is the ONLY call site of `session.begin()`, which spins up the
        // tracking loop. Landing straight on `.live` (the old default) left the
        // session never-begun, so the loop never ran ("LIVE · 0 tiles seen").
        // Debug MJ_SCREEN scenes pass an explicit `debugFlowState` (`.live` for
        // the mock-driven live scenes, `.setup` for `coach-live-setup`).
        _flowState = State(initialValue: debugFlowState ?? .setup)
    }

    var body: some View {
        ZStack {
            switch flowState {
            case .setup:
                CoachLiveSetupView(onStart: {
                    withAnimation(.easeInOut(duration: 0.3)) { flowState = .live }
                }, onCancel: onExit)
                .transition(.opacity)
            case .live:
                CoachLiveView(session: session, initialTab: debugInitialTab, initialSheet: debugSheet,
                             onExit: onExit, onScoreHandoff: onScoreHandoff)
                .transition(.opacity)
            }
        }
        .environment(session)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            // Fires on cover dismissal for both exit paths (back button + win
            // handoff): restore keep-awake and tear the tracking loop down.
            UIApplication.shared.isIdleTimerDisabled = false
            session.end()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding suspends the camera anyway; pause the loop and drop
            // the session explicitly, and bring both back on return. `.inactive`
            // (control center, banners) is left alone so brief interruptions
            // don't kill the feed.
            switch phase {
            case .background:
                session.pauseLoop()
                #if !targetEnvironment(simulator)
                session.camera.stop()
                #endif
            case .active:
                session.resumeLoop()
                #if !targetEnvironment(simulator)
                session.camera.requestAndStart()
                #endif
            default:
                break
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}
