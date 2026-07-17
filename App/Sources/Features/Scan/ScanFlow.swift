import SwiftUI
import Observation
import MahjongCore
import Recognition

/// Which destination the scan feeds (the Score/Coach toggle on the scan screen).
enum ScanMode: Hashable { case score, coach }

/// Steps in the scan → score / coach flow.
enum ScanRoute: Hashable { case detected, correct, context, result, coach }

/// Mutable working state for one scan: the recognized tiles (editable in the
/// correction step) plus the seat/round/win context gathered before scoring.
@Observable
final class ScanSession {
    var recognized: RecognitionResult = .empty
    var tiles: [Tile] = []
    var seatWind: Wind = .east
    var roundWind: Wind = .east
    var isSelfDraw: Bool = true
    var isDealer: Bool = true

    func start(with result: RecognitionResult) {
        recognized = result
        tiles = result.faces
        seatWind = .east
        roundWind = .east
        isSelfDraw = true
        isDealer = true
    }

    var lowConfidenceCount: Int { recognized.lowConfidenceCount }

    /// The scoring context assembled from the gathered taps. `scoreFlowers` is off
    /// for the demo so the walkthrough's numbers reproduce (house-variable).
    var gameContext: GameContext {
        GameContext(seatWind: seatWind, prevailingWind: roundWind,
                    houseRules: HouseRules(minimumFaan: 3, faanLimit: 10, scoreFlowers: false))
    }

    var hand: Hand {
        Hand(concealedTiles: tiles, winningTile: tiles.last, isSelfDraw: isSelfDraw)
    }
}

/// Owns the navigation path + session for the Scan tab.
@Observable
final class ScanCoordinator {
    var path: [ScanRoute] = []
    let session = ScanSession()

    func capture(_ mode: ScanMode) {
        session.start(with: mode == .coach ? MockHands.coach : MockHands.winning)
        path = (mode == .coach) ? [.coach] : [.detected]
    }

    func push(_ route: ScanRoute) { path.append(route) }
    func restart() { path.removeAll() }
}

/// The Scan tab: a NavigationStack driving the whole scan flow.
struct ScanFlowView: View {
    /// Debug: jump straight to a route (used by the `MJ_SCREEN` launch hook).
    var debugRoute: ScanRoute? = nil
    @State private var coordinator = ScanCoordinator()

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            ScanView()
                .navigationDestination(for: ScanRoute.self) { route in
                    switch route {
                    case .detected: DetectedView()
                    case .correct:  CorrectView()
                    case .context:  ContextView()
                    case .result:   ResultView(session: coordinator.session) { coordinator.restart() }
                    case .coach:    CoachView()
                    }
                }
        }
        .environment(coordinator)
        .onAppear {
            if let debugRoute, coordinator.path.isEmpty {
                coordinator.session.start(with: debugRoute == .coach ? MockHands.coach : MockHands.winning)
                coordinator.path = [debugRoute]
            }
        }
    }
}
