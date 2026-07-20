import SwiftUI
import UIKit
import CoreVideo
import Observation
import MahjongCore
import Recognition

/// Which destination the scan feeds (the Score / What's-this / Tracker toggle
/// on the scan screen). `.lookup` is a live single-tile identifier — it never
/// scores. `.tracker` is the manual discard-pile tile counter (Tracker plan
/// §1) — record-triggered only, never scores either. Coach Live (the
/// camera-tracked table coach) is a separate full-screen flow, not a scan
/// mode — see `CoachLiveFlowView`.
enum ScanMode: Hashable { case score, lookup, tracker }

/// The three bundled detectors, newest last. `rawValue` is the compiled-resource
/// base name (`<rawValue>.mlmodelc` in the app bundle) handed straight to
/// ``VisionRecognizer``. Surfaced only by the Debug-only model switcher in
/// Settings; production selects via the fast/accurate pair on ``TileDetector``.
enum DetectorModel: String, CaseIterable, Identifiable {
    case nanoV3   = "MahjongTileDetectorNanoV3"    // mjss-n-v3  — default (small & fast)
    case smallV3  = "MahjongTileDetectorSmallV3"   // mjss-s-v3  — balanced
    case mediumV3 = "MahjongTileDetectorMediumV3"  // mjss-m-v3  — more accurate
    case largeV3  = "MahjongTileDetectorProV3"     // mjss-l-v3  — most accurate (opt-in)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .nanoV3:   return "Nano v3"
        case .smallV3:  return "Small v3"
        case .mediumV3: return "Medium v3"
        case .largeV3:  return "Large v3"
        }
    }
    /// One-line descriptor shown under the label in the model-selection screen.
    var subtitle: String {
        switch self {
        case .nanoV3:   return "Small & fast · default"
        case .smallV3:  return "Balanced"
        case .mediumV3: return "More accurate"
        case .largeV3:  return "Most accurate"
        }
    }
}

/// Picks which bundled detector the recognizer loads. In production the Settings
/// "Higher accuracy" toggle flips between a small fast model and the larger, more
/// accurate (slower) one without ever naming them, defaulting to accurate. In
/// **Debug** builds the dev-only model switcher (Settings) overrides that and picks
/// any ``DetectorModel`` case directly.
enum TileDetector {
    static let defaultsKey = "prefersHighAccuracy"
    /// Compiled-resource base names (`<name>.mlmodelc` in the app bundle).
    /// Nano v3 is the universal default (thermal/speed); the larger v3 model is
    /// opt-in via the "Higher accuracy" toggle.
    static let fastModel = DetectorModel.nanoV3.rawValue
    static let accurateModel = DetectorModel.largeV3.rawValue

    /// Unset → false (nano v3) so fresh installs default to the light, cool model.
    static var prefersHighAccuracy: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Dev-only detector override (Debug builds only). Persisted like
    /// `prefersHighAccuracy`; unset (or naming a removed model) → `.nanoV3`, the
    /// universal default, so behavior is unchanged until a developer picks another.
    static let devModelKey = "devDetectorModel"
    static var devModel: DetectorModel {
        get { DetectorModel(rawValue: UserDefaults.standard.string(forKey: devModelKey) ?? "") ?? .nanoV3 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: devModelKey) }
    }

    static var preferredModelName: String {
        #if DEBUG
        return devModel.rawValue          // the dev switcher decides in Debug builds
        #else
        return prefersHighAccuracy ? accurateModel : fastModel
        #endif
    }
}

/// Steps in the scan → score flow.
enum ScanRoute: Hashable { case correct, context, result }

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
    // Special win circumstances — can't be read from the tiles, so the player taps
    // them on the "Almost there" screen. Fed straight into `gameContext`.
    var isLastTile: Bool = false        // 海底撈月 / 河底撈魚
    var isReplacement: Bool = false     // 槓上開花 / 花上開花
    var isRobbingKong: Bool = false     // 搶槓

    func start(with result: RecognitionResult) {
        recognized = result
        working = result.tiles
        myMelds = []
        tablePool = []
        seatWind = .east
        roundWind = .east
        isSelfDraw = true
        isDealer = true
        isLastTile = false
        isReplacement = false
        isRobbingKong = false
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
    /// Self-draw and flowers ride on the `Hand`; the special-win flags come from
    /// the "Almost there" toggles.
    var gameContext: GameContext {
        GameContext(seatWind: seatWind, prevailingWind: roundWind, houseRules: .standard,
                    isLastTile: isLastTile, isReplacement: isReplacement, isRobbingKong: isRobbingKong)
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
        case .lookup:
            return .valid   // identify-only; never scored
        case .tracker:
            return .valid   // manual counter; never scored
        }
    }
}

/// Owns the navigation path + session for the Scan tab, and runs recognition on
/// captured frames (the bundled Core ML detector when present, else the mock).
@Observable
final class ScanCoordinator {
    var path: [ScanRoute] = []
    let session = ScanSession()
    /// Tracker mode's running 34-tile "seen" count — one persistent instance
    /// per Scan tab, alongside `session` (Tracker plan chunk 1/§2).
    let tracker = TrackerSession()
    /// The back-camera capture, hoisted here (out of `ScanView`'s `@State`) so
    /// the Coach Live cover can attach a *second* preview layer to the same
    /// running `AVCaptureSession` — a zero-blink transition, since two sessions
    /// can't own the camera at once (UI plan §5). `ScanView` reads
    /// `coordinator.camera`; `ScanView.onDisappear` still owns start/stop for
    /// tab switches (the cover keeps `ScanView` in the hierarchy, so its
    /// teardown never fires while Coach Live is up).
    let camera = CameraCapture()
    /// True while a capture is being recognized (drives the shutter's busy state).
    private(set) var isRecognizing = false

    /// Loads/caches the preferred bundled detector off the main thread. Shared
    /// with Coach Live's tracking loop (via the `recognizerProvider` closure
    /// handed to `CoachLiveSession`) so both honor the same accuracy preference
    /// and never load two copies of the model.
    private let recognizerLoader = RecognizerLoader()

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
                result = MockHands.winning
            }

            session.start(with: result)
            session.mode = mode
            path = [.correct]
        }
    }

    /// Non-nil while the Coach Live cover is up. Constructed headless (no camera
    /// dependency required — see `CoachLiveSession`); on the Simulator it seeds
    /// the mock demo scenario since there's no real tracker loop yet.
    var coachLive: CoachLiveSession?

    /// Coach Live is LiDAR-first while the spatial pipeline is stabilized.
    /// Simulator debug scenes remain available for UI development, but a
    /// physical non-LiDAR device cannot enter the flow or silently use 2D.
    var isCoachLiveAvailable: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        ARTableCapture.isSupported && ARTableCapture.supportsSceneDepth
        #endif
    }

    func startCoachLive() {
        guard isCoachLiveAvailable else { return }
        #if DEBUG && targetEnvironment(simulator)
        coachLive = MockCoachLive.make(scene: "coach-live")
        #else
        // Real session (Lane B chunk G): ARKit needs the wide camera for
        // itself — free the device from `AVCaptureSession` FIRST, then hand
        // a started `ARTableCapture` to the session. `camera` itself is kept
        // around (still the fallback path if the table never locks, and
        // `endCoachLive`/`beginScoreHandoff` restart it for Scan's return)
        // and the shared recognizer loader still means one loaded model
        // either way.
        camera.stop()
        // `ARTableCapture` is `@MainActor`-isolated; `ScanCoordinator` isn't
        // (its intent methods are called directly from SwiftUI action
        // closures, always on the main actor at runtime but not statically
        // typed `@MainActor` all the way through) — `assumeIsolated` bridges
        // that gap, matching `CoachLiveSession.end()`'s identical situation.
        let arCapture = MainActor.assumeIsolated { () -> ARTableCapture in
            let capture = ARTableCapture()
            capture.start()
            return capture
        }
        let loader = recognizerLoader
        coachLive = CoachLiveSession(camera: camera, arCapture: arCapture, recognizerProvider: { await loader.active() })
        // Warm the (multi-second) Core ML detector now, while the user is on the
        // setup card tapping winds — `RecognizerLoader` caches, so the tracking
        // loop's first `await recognizerProvider()` then returns instantly.
        Task { _ = await loader.active() }
        #endif
    }

    func endCoachLive() {
        coachLive?.end()             // pauses the AR session (if any) — see `CoachLiveSession.end()`
        coachLive = nil
        #if !targetEnvironment(simulator)
        camera.requestAndStart()     // Scan's own preview resumes (harmless no-op if already running)
        #endif
    }

    /// Hands a completed live-tracked hand to the existing Score flow: seeds the
    /// session from the tracked faces, prefills context (winds/melds/self-draw),
    /// and lands on `ContextView` (one confirmation glance) rather than `.result`
    /// directly — `ScanRoute.correct` is deliberately skipped since the hand came
    /// from the tracker, not a fresh scan.
    @MainActor
    func beginScoreHandoff(from live: CoachLiveSession) {
        let faces = live.handTiles.map(\.face) + [live.drawnTile?.face].compactMap { $0 }
        session.start(with: .row(faces))          // resets winds/melds — set AFTER it
        session.myMelds = live.myMelds
        session.tablePool = live.tablePoolAsDetected
        session.seatWind = live.seatWind
        session.roundWind = live.roundWind
        session.isSelfDraw = live.winDetected?.isSelfDraw ?? true
        session.isDealer = (live.seatWind == .east)
        session.mode = .score
        session.capturedPhoto = live.lastFrameSnapshot
        live.end()                  // stop the tracking loop (+ pause AR) before we drop the cover
        #if !targetEnvironment(simulator)
        camera.requestAndStart()    // Scan's own preview resumes (Lane B chunk G)
        #endif
        path = [.context]           // set path BEFORE clearing coachLive so the
        coachLive = nil             // cover dismissal reveals ContextView, not the camera.
    }

    /// Identify the largest (closest-to-camera) tile in `frame` for the live
    /// "What's this?" lens, considering only detections inside the viewfinder
    /// `roi` — the camera sees the whole (blurred) frame, the user only the window.
    /// Among reads ≥ 0.5 confidence we pick the biggest bounding box, so a tile
    /// held up to the lens wins over smaller background tiles. Reuses the cached
    /// recognizer and never touches the routing/`isRecognizing` state, so it's
    /// safe to poll continuously.
    @MainActor
    func lookup(_ frame: RecognizerFrame, roi: TileBoundingBox? = nil) async -> DetectedTile? {
        let recognizer = await activeRecognizer()
        guard let result = try? await recognizer.recognize(frame) else { return nil }
        return result.keepingTiles(insideROI: roi).tiles
            .filter { $0.confidence >= 0.5 }
            .max { ($0.box.width * $0.box.height) < ($1.box.width * $1.box.height) }
    }

    /// Recognizes every tile in `frame`, keeping only those inside `roi` —
    /// the same core `capture` runs (`ScanFlow.swift:258-261`), exposed
    /// standalone for Tracker mode's single-frame (non-tiled) recognize path.
    @MainActor
    func recognizeAllTiles(frame: RecognizerFrame, roi: TileBoundingBox? = nil) async -> [DetectedTile] {
        let recognizer = await activeRecognizer()
        return ((try? await recognizer.recognize(frame)) ?? .empty).keepingTiles(insideROI: roi).tiles
    }

    /// Tracker mode's Record action: recognizes `buffer` via
    /// `TiledTileRecognizer`'s overlapping native-resolution grid (never
    /// feeds the whole frame straight to the model — see that type's doc),
    /// merges/dedupes across crops, and returns the result for the caller to
    /// fold into `tracker.recordReplaceFromShot`.
    @MainActor
    func recordScan(buffer: CVPixelBuffer, roi: TileBoundingBox? = nil) async -> [DetectedTile] {
        await TiledTileRecognizer.recognize(buffer: buffer, roi: roi) { frame in
            let recognizer = await self.activeRecognizer()
            return (try? await recognizer.recognize(frame)) ?? .empty
        }
    }

    /// The preferred bundled recognizer (accurate → fast → mock fallback),
    /// via the shared loader — see ``RecognizerLoader``.
    @MainActor
    private func activeRecognizer() async -> any Recognizer {
        await recognizerLoader.active()
    }

    func push(_ route: ScanRoute) { path.append(route) }
    func restart() { path.removeAll() }
}

/// Loads and caches the preferred bundled ``VisionRecognizer`` (Core ML) off
/// the main thread, reloading when the "Higher accuracy" preference has flipped
/// since last time. Falls back accurate → fast → ``MockRecognizer`` so a model
/// that won't load (or an unbundled one) degrades gracefully rather than
/// crashing. An `actor` so the scan shutter/lookup and Coach Live's tracking
/// loop can share one instance (one loaded model) without a data race — this is
/// exactly the old `ScanCoordinator.activeRecognizer()` body, lifted out so
/// both callers reuse it instead of duplicating the fallback chain.
actor RecognizerLoader {
    private var recognizer: (any Recognizer)?
    private var loadedModelName: String?

    func active() async -> any Recognizer {
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
}

/// The Scan tab: a NavigationStack driving the whole scan flow.
struct ScanFlowView: View {
    /// Debug: jump straight to a route (used by the `MJ_SCREEN` launch hook).
    var debugRoute: ScanRoute? = nil
    /// Debug: seed a specific hand instead of the default demo one.
    var debugHand: RecognitionResult? = nil
    /// Debug: open the scan screen already on a given mode (e.g. `.lookup`).
    var debugScanMode: ScanMode? = nil
    @State private var coordinator = ScanCoordinator()

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            ScanView(initialMode: debugScanMode ?? .lookup)
                .navigationDestination(for: ScanRoute.self) { route in
                    switch route {
                    case .correct:  CorrectView()
                    case .context:  ContextView()
                    case .result:   ResultView(session: coordinator.session) { coordinator.restart() }
                    }
                }
        }
        .environment(coordinator)
        .fullScreenCover(item: $coordinator.coachLive) { session in
            CoachLiveFlowView(session: session,
                              onExit: { coordinator.endCoachLive() },
                              onScoreHandoff: { coordinator.beginScoreHandoff(from: session) })
        }
        .onAppear(perform: seedIfDebug)
    }

    private func seedIfDebug() {
        guard let debugRoute, coordinator.path.isEmpty else { return }
        let hand = debugHand ?? MockHands.twoRowWinning
        coordinator.session.start(with: hand)
        coordinator.session.mode = .score
        coordinator.path = [debugRoute]
    }
}
