import SwiftUI
import UIKit
import Observation
import MahjongCore
import Recognition

/// Which destination the scan feeds (the Score / Coach / What's-this toggle on the
/// scan screen). `.lookup` is a live single-tile identifier — it never scores.
enum ScanMode: Hashable { case score, coach, lookup }

/// Picks which bundled detector the recognizer loads. Two models ship: a small
/// fast one and a larger, more accurate (slower) one — the Settings "Higher
/// accuracy" toggle flips between them without ever naming the models. Defaults
/// to the accurate model (current testing default).
enum TileDetector {
    static let defaultsKey = "prefersHighAccuracy"
    /// Compiled-resource base names (`<name>.mlmodelc` in the app bundle).
    static let fastModel = "MahjongTileDetector"
    static let accurateModel = "MahjongTileDetectorPro"

    /// Unset → true (accurate) so fresh installs and test builds get the big model.
    static var prefersHighAccuracy: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var preferredModelName: String {
        prefersHighAccuracy ? accurateModel : fastModel
    }
}

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
    /// MINE bucket: my own exposed melds (pung/kong/chow) — structure feeds `Hand.melds`.
    var myMelds: [Meld] = []
    /// TABLE bucket: every other face-up tile (all discards + opponents' melds).
    /// Only the *count per type* matters — subtracted from live outs. Order irrelevant.
    var tablePool: [DetectedTile] = []
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
        myMelds = []
        tablePool = []
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

    /// TABLE bucket as a 34-slot `classIndex` histogram — the "seen" tiles fed to
    /// the engine so ukeire reports *live* outs. Bonus tiles skipped.
    var seenHistogram: [Int] {
        var h = [Int](repeating: 0, count: Tile.baseClassCount)
        for d in tablePool where !d.tile.isBonus { h[d.tile.classIndex] += 1 }
        return h
    }

    /// Base tiles (of 136) not yet visible anywhere — the draw pool for a rough
    /// "chance" figure: everything minus my concealed hand, my melds, and the table.
    var unseenCount: Int {
        let myMeldTiles = myMelds.reduce(0) { $0 + $1.tiles.filter { !$0.isBonus }.count }
        return max(1, 136 - playable.count - myMeldTiles - seenHistogram.reduce(0, +))
    }

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
    /// is the last *playable* tile in reading order. My own exposed melds go into
    /// `melds` so a mid-game (melded) hand shantens correctly.
    var hand: Hand {
        let faces = playable.map(\.tile)
        return Hand(concealedTiles: faces,
                    melds: myMelds,
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
            // A decision hand is 14 tiles; each exposed meld fills a 3-tile set,
            // so the concealed target shrinks by 3 per meld (13+draw when melded).
            let need = 14 - 3 * myMelds.count
            return n == need ? .valid : (n < need ? .tooFew(playable: n) : .tooMany(playable: n))
        case .lookup:
            return .valid   // identify-only; never scored
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
    /// Which bundled model the cached recognizer holds — so a flipped accuracy
    /// preference triggers a reload instead of serving the stale model.
    private var loadedModelName: String?

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

    /// Identify the single most-confident tile in `frame` (≥ 0.5 confidence) for the
    /// live "What's this?" lens, considering only detections inside the viewfinder
    /// `roi` — the camera sees the whole (blurred) frame, the user only the window.
    /// Reuses the cached recognizer and never touches the routing/`isRecognizing`
    /// state, so it's safe to poll continuously.
    @MainActor
    func lookup(_ frame: RecognizerFrame, roi: TileBoundingBox? = nil) async -> DetectedTile? {
        let recognizer = await activeRecognizer()
        guard let result = try? await recognizer.recognize(frame) else { return nil }
        return result.keepingTiles(insideROI: roi).tiles
            .filter { $0.confidence >= 0.5 }
            .max { $0.confidence < $1.confidence }
    }

    /// Loads the preferred bundled ``VisionRecognizer`` (Core ML) off the main
    /// thread, reloading when the accuracy preference has flipped since last time.
    /// Falls back accurate → fast → ``MockRecognizer`` so a model that won't load
    /// (or an unbundled one) degrades gracefully rather than crashing.
    @MainActor
    private func activeRecognizer() async -> any Recognizer {
        let wanted = TileDetector.preferredModelName
        if let recognizer, loadedModelName == wanted { return recognizer }
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? VisionRecognizer(bundledModelNamed: wanted)) as (any Recognizer)?
                ?? (try? VisionRecognizer(bundledModelNamed: TileDetector.fastModel)) as (any Recognizer)?
                ?? MockRecognizer()
        }.value
        recognizer = loaded
        loadedModelName = wanted
        return loaded
    }

    func push(_ route: ScanRoute) { path.append(route) }
    func restart() { path.removeAll() }
}

/// The Scan tab: a NavigationStack driving the whole scan flow.
struct ScanFlowView: View {
    /// Debug: jump straight to a route (used by the `MJ_SCREEN` launch hook).
    var debugRoute: ScanRoute? = nil
    /// Debug: seed a specific hand instead of the default demo one.
    var debugHand: RecognitionResult? = nil
    /// Debug: open the scan screen already on a given mode (e.g. `.lookup`).
    var debugScanMode: ScanMode? = nil
    /// Debug: seed a melded coach hand + a discard pool (table-aware coaching).
    var debugTable: Bool = false
    @State private var coordinator = ScanCoordinator()

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            ScanView(initialMode: debugScanMode ?? .score)
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
        .onAppear(perform: seedIfDebug)
    }

    /// Debug: a melded tenpai plus a discard pool, so the table-aware Coach shows
    /// reduced live outs. Concealed 23m 456p 789p 33s 5s + exposed East pung;
    /// the pond already holds two 1m + one 4m, thinning the 1m/4m wait.
    private static func seedCoachTable(_ session: ScanSession) {
        session.start(with: .row([.m(2), .m(3), .p(4), .p(5), .p(6),
                                  .p(7), .p(8), .p(9), .s(3), .s(3), .s(5)]))
        session.myMelds = [.pung(.east)]
        session.tablePool = [.m(1), .m(1), .m(4), .p(1), .s(9), .west].map {
            DetectedTile(tile: $0, confidence: 1.0,
                         box: TileBoundingBox(x: 0, y: 0, width: 0.05, height: 0.05))
        }
    }

    private func seedIfDebug() {
        guard let debugRoute, coordinator.path.isEmpty else { return }
        if debugTable {
            Self.seedCoachTable(coordinator.session)
        } else {
            let hand = debugHand ?? (debugRoute == .coach ? MockHands.coach : MockHands.twoRowWinning)
            coordinator.session.start(with: hand)
        }
        coordinator.session.mode = (debugRoute == .coach) ? .coach : .score
        coordinator.path = [debugRoute]
    }
}
