import SwiftUI
import UIKit
import Observation
import MahjongCore
import Recognition

/// Which destination the scan feeds (the Score/Coach toggle on the scan screen).
enum ScanMode: Hashable { case score, coach }

/// Steps in the scan → score / coach flow.
enum ScanRoute: Hashable { case correct, context, result, coach }

/// Result of validating the corrected hand's size (warn-only — never blocks).
enum HandCountStatus: Equatable {
    case valid
    case kongSized(playable: Int)   // 15–18 (kongs) — scorer can't decompose kongs yet
    case tooFew(playable: Int)
    case tooMany(playable: Int)

    var isValid: Bool { if case .valid = self { return true } else { return false } }
}

/// Mutable working state for one scan: the editable detected tiles (UUID-keyed so
/// add/remove never corrupts indices) plus the seat/round/win context.
@Observable
final class ScanSession {
    /// The recognizer's raw result (retained for reference).
    var recognized: RecognitionResult = .empty
    /// The editable working set — reading order, survives add/remove/replace.
    var working: [DetectedTile] = []
    var mode: ScanMode = .score
    /// The photo grabbed at the shutter — the whole post-scan flow sits on a
    /// blurred, green-tinted copy of it. Nil for mock/demo captures.
    var capturedPhoto: UIImage?
    var seatWind: Wind = .east
    var roundWind: Wind = .east
    var isSelfDraw: Bool = true
    var isDealer: Bool = true

    func start(with result: RecognitionResult) {
        recognized = result
        working = result.tiles
        seatWind = .east
        roundWind = .east
        isSelfDraw = true
        isDealer = true
    }

    /// The faces in reading order (read-only compat for scoring / coaching).
    var tiles: [Tile] { working.map(\.tile) }
    /// The working tiles grouped into the physical rows the camera saw.
    var workingRows: [[DetectedTile]] { TileRowClusterer.rows(working) }

    /// Non-bonus tiles (what counts toward a hand) and the flowers/seasons set aside.
    var playable: [DetectedTile] { working.filter { !$0.tile.isBonus } }
    var bonus: [DetectedTile] { working.filter { $0.tile.isBonus } }

    var lowConfidenceCount: Int { working.filter(\.isLowConfidence).count }
    /// Tiles worth a look: the recognizer wasn't sure about them.
    var flaggedIDs: Set<UUID> { Set(working.filter(\.isLowConfidence).map(\.id)) }

    // MARK: Editing (UUID-keyed — no index bookkeeping)

    func replace(id: UUID, with tile: Tile) {
        guard let i = working.firstIndex(where: { $0.id == id }) else { return }
        working[i].tile = tile
        working[i].confidence = 1.0      // user-confirmed → clears low-confidence flag
    }

    func remove(id: UUID) { working.removeAll { $0.id == id } }

    func append(_ tile: Tile) {
        // Drop it just right of the bottom row's last tile so clustering stays coherent.
        let anchor = TileRowClusterer.rows(working).last?.last?.box
            ?? TileBoundingBox(x: -0.06, y: 0.45, width: 0.06, height: 0.12)
        let box = TileBoundingBox(x: min(0.93, anchor.x + anchor.width * 1.15),
                                  y: anchor.y, width: anchor.width, height: anchor.height)
        working.append(DetectedTile(tile: tile, confidence: 1.0, box: box))
    }

    // MARK: Scoring inputs

    /// Standard HK house rules now that real scans carry real flowers/seasons.
    var gameContext: GameContext {
        GameContext(seatWind: seatWind, prevailingWind: roundWind, houseRules: .standard)
    }

    /// Flowers/seasons go into `bonusTiles` (never a scoring set); the winning tile
    /// is the last *playable* tile in reading order.
    var hand: Hand {
        let faces = playable.map(\.tile)
        return Hand(concealedTiles: faces,
                    bonusTiles: bonus.map(\.tile),
                    winningTile: faces.last,
                    isSelfDraw: isSelfDraw)
    }

    /// Warn only when the playable count can't be a real hand (bonus tiles excluded).
    func countStatus(for mode: ScanMode) -> HandCountStatus {
        let n = playable.count
        switch mode {
        case .score:
            if n == 14 { return .valid }
            if (15...18).contains(n) { return .kongSized(playable: n) }
            return n < 14 ? .tooFew(playable: n) : .tooMany(playable: n)
        case .coach:
            return n == 14 ? .valid : (n < 14 ? .tooFew(playable: n) : .tooMany(playable: n))
        }
    }
}

/// Owns the navigation path + session for the Scan tab, and runs recognition on
/// captured frames (the bundled Core ML detector when present, else the mock).
@Observable
final class ScanCoordinator {
    var path: [ScanRoute] = []
    let session = ScanSession()
    /// True while a capture is being recognized (drives the shutter's busy state).
    private(set) var isRecognizing = false

    /// Cached recognizer, loaded lazily off the main thread on first capture.
    private var recognizer: (any Recognizer)?

    /// Recognize `frame` (a live camera buffer or a picked photo), keep only tiles
    /// inside the viewfinder `roi`, and route to the result or coach lane. When
    /// `frame` is nil — e.g. the Simulator has no camera — falls back to the demo
    /// hand. `photo` is the shutter-moment still used as the post-scan backdrop.
    func capture(_ mode: ScanMode, frame: RecognizerFrame? = nil,
                 roi: TileBoundingBox? = nil, photo: UIImage? = nil) {
        guard !isRecognizing else { return }
        Task { @MainActor in
            isRecognizing = true
            defer { isRecognizing = false }
            session.mode = mode
            session.capturedPhoto = photo   // nil clears any stale photo (mock path)

            let result: RecognitionResult
            if let frame {
                let recognizer = await activeRecognizer()
                let recognized = (try? await recognizer.recognize(frame)) ?? .empty
                result = recognized.keepingTiles(insideROI: roi)
            } else {
                result = (mode == .coach) ? MockHands.coach : MockHands.winning
            }

            session.start(with: result)
            session.mode = mode
            // Empty real captures fall to the check screen rather than the coach.
            path = (mode == .coach && !result.isEmpty) ? [.coach] : [.correct]
        }
    }

    /// Loads the bundled ``VisionRecognizer`` (Core ML) off the main thread, or
    /// ``MockRecognizer`` when no model is bundled. Cached after the first load.
    @MainActor
    private func activeRecognizer() async -> any Recognizer {
        if let recognizer { return recognizer }
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? VisionRecognizer()) as (any Recognizer)? ?? MockRecognizer()
        }.value
        recognizer = loaded
        return loaded
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
                coordinator.session.start(with: debugRoute == .coach ? MockHands.coach : MockHands.twoRowWinning)
                coordinator.session.mode = (debugRoute == .coach) ? .coach : .score
                coordinator.path = [debugRoute]
            }
        }
    }
}
