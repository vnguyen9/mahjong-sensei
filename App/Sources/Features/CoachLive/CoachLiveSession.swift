import Foundation
import CoreGraphics
import QuartzCore
import UIKit
import Observation
import MahjongCore
import Recognition
import CoachEngine
import EfficiencyEngine
import ScoringEngine
import os

/// Coach Live's UI-facing session surface — the `@Observable` contract every
/// static view in this folder is built against (UI plan §1). Properties are
/// plain `var`s (not `private(set)`) so this chunk's intents and
/// `CoachLiveMock` can both populate them directly; the later tracker chunk
/// fills the same class with real camera-driven data behind the same surface,
/// so the views above never need to change.
///
/// Two contract requirements the UI plan imposes on whoever wires the real
/// loop in later (§1): (1) table-state properties should mutate at
/// committed-change cadence (~2–4 Hz), not per camera frame — `phase` may
/// change immediately; SwiftUI `@Observable` diffing handles the rest.
/// (2) this class must stay constructible without a camera and drivable by
/// injected scripted events — `CoachLiveMock` is exactly that drive today.
///
/// Beyond the plan's §1 property list (which is deliberately abbreviated):
/// `seatWind`/`roundWind` are added because §6 (setup) and §11 (score
/// handoff) both read/write them directly, and `lastFrameSnapshot` because
/// §11's handoff explicitly assigns `live.lastFrameSnapshot`. `id` is added
/// for the `Identifiable` conformance §5 requires for the `fullScreenCover`.
///
/// One signature adaptation: the plan's `overrideHandTile(_ id: UUID, as:)`
/// predates the real `Recognition.TrackedTile`, whose stable identity is
/// `TrackID` (a monotonic `Int`), not `UUID` — see `TrackingModels.swift`.
/// `handTiles`/`drawnTile` are keyed by `TrackID`, so `overrideHandTile`
/// takes one here; a `UUID` couldn't address them at all.
@Observable
final class CoachLiveSession: Identifiable {
    let id = UUID()

    /// Drives the live-feed/state-pane breathing split. `.action` = tiles
    /// moving; `.thinking` = table still + my turn (a discard decision).
    enum Phase: Equatable { case rest, action, thinking }
    var phase: Phase = .rest

    // MARK: Tracked table state (stable ids — see `TrackedTile.id` — are
    // REQUIRED for animation identity in the Map/hand-strip transitions).

    /// 13 concealed hand tiles, reading order.
    var handTiles: [TrackedTile] = []
    /// The separated 14th tile, when one has been drawn.
    var drawnTile: TrackedTile?
    var myMelds: [Meld] = []
    var opponentMelds: [RelativeSeat: [Meld]] = [:]
    /// For seats with no revealed melds — the "North · 13 · concealed" chip.
    var concealedCounts: [RelativeSeat: Int] = [:]
    var pond: [PondEntry] = []
    var unresolved: [UnresolvedTile] = []
    /// 34-slot, classIndex-keyed — same shape as `ScanSession.seenHistogram`.
    var seenHistogram: [Int] = Array(repeating: 0, count: Tile.baseClassCount)
    /// Pond + opponent melds only — kept exactly as the engine (`recomputeAdvice`/
    /// `coachTable`) reads it. NOT what the LIVE pill displays — see `liveTileCount`,
    /// which counts every live track (a tracked hand alone would read 0 here).
    var seenTotal: Int = 0
    /// Append-only event log (oldest → newest; the Events tab reverses it).
    var events: [TableEvent] = []

    /// "LIVE · N tiles seen" — every currently-tracked tile: hand + drawn +
    /// melds (mine + opponents') + pond + unresolved. Distinct from
    /// `seenTotal` (pond + opponent melds only, which the engine reads
    /// internally for ukeire/seen counts) — a tracked-but-not-yet-discarded
    /// hand would read 0 tiles seen under the old `seenTotal`-based pill even
    /// mid-hand, which is what motivated this fix.
    var liveTileCount: Int {
        handTiles.count + (drawnTile == nil ? 0 : 1)
            + myMelds.reduce(0) { $0 + $1.tiles.count }
            + opponentMelds.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.tiles.count } }
            + pond.count + unresolved.count
    }

    /// This hand's round/seat wind — set by `begin(roundWind:seatWind:)` and
    /// rotated by `confirmHandEnd`. Not in the plan's abbreviated §1 list but
    /// required by §6/§11 — see the type doc.
    var seatWind: Wind = .east
    var roundWind: Wind = .east

    // MARK: Zone geometry, normalized ORIENTED-image coordinates (same space
    // as `DetectedTile.box`). Kept on the surface now so the bracket-overlay
    // chunk (LiveFeedPane) is a pure add with nothing to wire up later.
    var zoneBoxes = ZoneBoxes()
    var orientedImageSize: CGSize = .zero

    /// Recomputed locally (via the real, placeholder `CoachAdvisor`) whenever
    /// a mutation below changes the hand or the seen counts — see
    /// `recomputeAdvice()`.
    var advice: CoachAdvice?

    // MARK: Lifecycle signals
    var handBoundary: HandBoundaryPrediction?
    var winDetected: WinInfo?
    var thermal: ThermalCadence = .nominal

    // MARK: Pipeline health (debug-bisect support — see the plan behind the
    // "LIVE · 0 tiles seen" fix). The poll loop no longer swallows
    // `rec.recognize` failures via `try?`; it records them here instead so
    // the UI can distinguish "recognizer threw" / "no real detector loaded"
    // from genuine zero-recall.

    /// `String(describing:)` of the last error `rec.recognize(_:)` threw, if
    /// any this session. Cleared on the next successful recognize.
    var lastPipelineError: String?
    /// Cumulative count of `rec.recognize(_:)` throws this session.
    var recognizerErrorCount = 0
    /// True once the loop has resolved a recognizer that turned out to be
    /// `MockRecognizer` on the real (camera-backed) path — i.e. the bundled
    /// Core ML model failed to load, not merely "no tiles this frame". The
    /// LIVE pill shows a distinct "detector unavailable" state for this
    /// (`LiveFeedPane.livePill`), reusing the thermal/"cooling" treatment.
    var detectorUnavailable = false
    /// True from `begin()` on the real path until the loop's FIRST recognize
    /// call completes (success or throw) — i.e. the camera is warming and the
    /// detector is loading. The LIVE pill shows a "Starting…" spinner during
    /// this window (`LiveFeedPane.livePill`) so slow phones don't look frozen.
    /// Never set on the mock path, so MJ_SCREEN scenes are unaffected.
    var isWarmingUp = false
    /// Dev-only diagnostics the loop records every tick — powers the
    /// triple-tap debug HUD; see `LiveDiagnostics`.
    var diagnostics = LiveDiagnostics()
    /// `tracker.diagnostics` passthrough for the HUD — `nil` tracker (mock
    /// path) reads as all-zero rather than requiring the HUD to unwrap.
    var trackerDiagnostics: Recognition.TrackerDiagnostics { tracker?.diagnostics ?? Recognition.TrackerDiagnostics() }

    /// Mirrors key pipeline transitions to Console.app (subsystem matches the
    /// bundle id) — plan §3: works even off a connected debugger.
    private static let logger = Logger(subsystem: "com.lumiodatalabs.MahjongSensei", category: "coachlive")

    /// The most recent camera frame, snapshotted for `beginScoreHandoff`'s
    /// `CapturedBackdrop` continuity. Nil until the real capture loop (a
    /// later chunk) starts writing it.
    var lastFrameSnapshot: UIImage?

    // MARK: Camera — the UI needs only `.session` (preview) and `.setTorch(_:)`.
    let camera: CameraCapture

    // MARK: - Live loop (real device path only)

    /// Loads the tile recognizer for the tracking loop; `nil` ⇒ this is a
    /// mock/headless session (the Simulator entry, MJ_SCREEN scenes, and any
    /// `CoachLiveMock`-seeded session) — `begin()` then keeps its stub behavior
    /// and every intent below stays a direct local mutation, exactly as before
    /// this chunk. A non-nil provider is what makes `begin()` spin up the real
    /// camera → `TableTracker` → advice loop.
    private let recognizerProvider: (@Sendable () async -> any Recognizer)?

    /// The single-owner tracker facade — created in `begin()` on the real path,
    /// driven only on the main actor (the loop below + the intents), matching
    /// its "MainActor app loop" ownership contract. `nil` on the mock path.
    private var tracker: TableTracker?
    /// Off-main memoizing front door to the advisor (plan §5).
    private var advisorCache: AdvisorCache?
    /// The tracker config, retained so the loop can read `motionActive` for the
    /// phase signal without a second source of truth.
    private var trackerConfig = TrackerConfig()

    private var loopTask: Task<Void, Never>?
    /// Backgrounded → the loop idles (camera is torn down by the flow view).
    private var isPaused = false
    private var isEnded = false

    // Coalesced-publish bookkeeping (plan §1.1: table state mutates at
    // committed-change cadence, ≤ ~3 Hz, only on a `revision` bump).
    private static let publishInterval: TimeInterval = 0.3
    private static let pollInterval: Duration = .milliseconds(120)
    private var lastPublishedRevision = -1
    private var lastPublishTime: TimeInterval = 0
    /// Rising-edge latch so the win banner fires once and honors "Keep playing".
    private var wasHandComplete = false

    // Stable-UUID bridges: the tracker keys everything by monotonic `TrackID`/
    // event `Int`, but the UI's `PondEntry`/`UnresolvedTile`/`TableEvent` all
    // carry `UUID`s (for ForEach identity + the correction sheets). These keep
    // one UUID per underlying id across republishes, and map a tapped UUID back
    // to the tracker id the facade correction needs.
    private var pondUUIDByTrack: [TrackID: UUID] = [:]
    private var unresolvedUUIDByTrack: [TrackID: UUID] = [:]
    private var unresolvedTrackByUUID: [UUID: TrackID] = [:]
    private var eventUUIDByBackingID: [Int: UUID] = [:]
    private var eventBackingIDByUUID: [UUID: Int] = [:]
    /// Discard/self-discard events → the pond track they reference, so an
    /// Events-tab tile fix can `pin` the underlying track.
    private var eventTileTrackByBackingID: [Int: TrackID] = [:]

    init(camera: CameraCapture, recognizerProvider: (@Sendable () async -> any Recognizer)? = nil) {
        self.camera = camera
        self.recognizerProvider = recognizerProvider
    }

    // MARK: - Intents (UI → tracker)

    /// Starts a session at the given winds.
    ///
    /// On the real (camera-backed) path this builds the tracker, injects the
    /// win predicate + wait-impact annotator, begins a tracker session, and
    /// spins up the polling loop (`startLoop`). On the mock/headless path
    /// (`recognizerProvider == nil`) it stays the original stub — assign the
    /// winds and let `CoachLiveMock` drive the published state directly.
    func begin(roundWind: Wind, seatWind: Wind) {
        self.roundWind = roundWind
        self.seatWind = seatWind
        phase = .rest

        guard let recognizerProvider, tracker == nil else { return }
        isWarmingUp = true
        startLoop(recognizerProvider: recognizerProvider)
    }

    // MARK: - Live loop

    private func startLoop(recognizerProvider: @escaping @Sendable () async -> any Recognizer) {
        var config = TrackerConfig()
        // Injection 1 (plan §2): the win check — Recognition never imports
        // ScoringEngine, so the app supplies it as a closure.
        config.winPredicate = { concealed, melds in
            ScoringEngine.isWinningShape(Hand(concealedTiles: concealed, melds: melds))
        }
        trackerConfig = config

        let tracker = TableTracker(config: config)
        // Injection 2 (plan §2/§4.6): flag events whose tile eats into my live
        // waits — the wait-impact chip. `EfficiencyEngine.ukeire` on the tracked
        // hand, kept cheap (a plain ukeire, not a full re-advise).
        tracker.waitImpactAnnotator = Self.waitImpactAnnotator
        self.tracker = tracker
        advisorCache = AdvisorCache()

        let start = CACurrentMediaTime()
        tracker.beginSession(mySeatWind: seatWind, roundWind: roundWind, at: start)

        let motionActive = config.motionActive
        let basePolicy = CadencePolicy(config: config)   // Sendable — safe to capture
        loopTask = Task { @MainActor [weak self] in
            var cadence = basePolicy
            let motion = MotionDetector()
            var recognizer: (any Recognizer)?
            var lastInference = CACurrentMediaTime() - 10   // due immediately

            pollLoop: while !Task.isCancelled {
                guard let self, !self.isEnded else { break }
                if self.isPaused {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                self.diagnostics.loopTicks += 1
                guard let buffer = self.camera.latestBuffer else {
                    self.diagnostics.nilBufferCount += 1
                    try? await Task.sleep(for: Self.pollInterval)
                    continue
                }
                let now = CACurrentMediaTime()
                if self.orientedImageSize == .zero {
                    self.orientedImageSize = RecognizerFrame.buffer(buffer, orientation: .right).orientedPixelSize
                }

                // Motion every tick (~8 Hz), independent of inference — feeds
                // both the breathing phase and the cadence decision.
                let sample = motion.sample(buffer, at: now)
                if sample == nil { self.diagnostics.nilMotionSampleCount += 1 }
                let level = sample?.level ?? 0
                self.diagnostics.motionLevel = level
                self.updatePhase(active: level >= motionActive)

                let thermalBucket = CadencePolicy.Thermal(
                    processInfoRawValue: ProcessInfo.processInfo.thermalState.rawValue)
                let wasThrottled = self.thermal == .throttled
                self.thermal = thermalBucket >= .serious ? .throttled : .nominal
                if self.thermal == .throttled, !wasThrottled {
                    Self.logger.notice("thermal throttled — cadence backing off (state: \(thermalBucket.rawValue, privacy: .public))")
                } else if wasThrottled, self.thermal == .nominal {
                    Self.logger.notice("thermal recovered — cadence back to nominal")
                }

                switch cadence.decide(motionLevel: level, thermal: thermalBucket,
                                      timeSinceLastInference: now - lastInference) {
                case .suspend:
                    self.diagnostics.suspendDecisions += 1
                    self.thermal = .throttled          // thermal `.critical`: inference paused
                case .skip:
                    self.diagnostics.skipDecisions += 1
                case .infer:
                    self.diagnostics.inferDecisions += 1
                    lastInference = now
                    if recognizer == nil {
                        recognizer = await recognizerProvider()
                        let typeName = recognizer.map { String(describing: type(of: $0)) } ?? "nil"
                        self.diagnostics.recognizerType = typeName
                        self.detectorUnavailable = recognizer is MockRecognizer
                        Self.logger.notice("recognizer resolved: \(typeName, privacy: .public), detectorUnavailable=\(self.detectorUnavailable, privacy: .public)")
                    }
                    if self.isEnded { break pollLoop }
                    guard let rec = recognizer else { break }
                    self.diagnostics.inferencesRun += 1
                    let frame = RecognizerFrame.buffer(buffer, orientation: .right)
                    let result: RecognitionResult
                    do {
                        result = try await rec.recognize(frame)
                        self.lastPipelineError = nil
                    } catch {
                        self.recognizerErrorCount += 1
                        self.lastPipelineError = String(describing: error)
                        Self.logger.error("recognize() threw (\(self.recognizerErrorCount, privacy: .public) total): \(String(describing: error), privacy: .public)")
                        result = .empty
                    }
                    // First real inference completed — the camera is delivering
                    // frames and the detector is loaded; drop the "Starting…" pill.
                    self.isWarmingUp = false
                    self.diagnostics.lastRawDetectionCount = result.tiles.count
                    self.diagnostics.lastTopDetections = result.tiles
                        .sorted { $0.confidence > $1.confidence }
                        .prefix(3)
                        .map { "\($0.tile.code)@\(String(format: "%.2f", $0.confidence))" }
                    if self.isEnded { break pollLoop }
                    guard let tracker = self.tracker else { break }
                    // The loop is serial, so at most one inference is ever in
                    // flight — the "drop-if-in-flight" guard is structural.
                    let outcome = tracker.ingest(result.tiles, at: CACurrentMediaTime(), motion: sample)
                    if !outcome.newEvents.isEmpty {
                        Self.logger.debug("tracker committed \(outcome.newEvents.count, privacy: .public) event(s); live=\(tracker.diagnostics.live, privacy: .public) tentative=\(tracker.diagnostics.tentative, privacy: .public) missing=\(tracker.diagnostics.missing, privacy: .public)")
                    }
                    if outcome.newEvents.contains(where: {
                        if case .myHandComplete = $0.kind { return true }; return false
                    }) {
                        // Snapshot the exact winning-hand frame for the score handoff.
                        self.lastFrameSnapshot = ScanView.photo(from: buffer)
                    }
                }

                await self.publishIfDue(now: CACurrentMediaTime())
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Phase drives the breathing split (plan §8) and may change every tick —
    /// deliberately NOT coalesced. `.action` while tiles move; `.thinking` when
    /// still and it's my decision (my turn, or I'm holding a 14th tile);
    /// `.rest` otherwise.
    private func updatePhase(active: Bool) {
        let turn = tracker?.state.currentTurn
        let handCount = tracker?.state.myHand.count ?? 0
        let myTurn = turn == .me || handCount % 3 == 2
        let newPhase: Phase = active ? .action : (myTurn ? .thinking : .rest)
        if phase != newPhase { phase = newPhase }
    }

    /// Coalesced publish: at most once per `publishInterval`, and only when the
    /// tracker committed a change (`state.revision` bumped).
    @MainActor
    private func publishIfDue(now: TimeInterval) async {
        guard let tracker else { return }
        let state = tracker.state
        guard state.revision != lastPublishedRevision, now - lastPublishTime >= Self.publishInterval else { return }
        applyState(state, pending: tracker.pendingHandEnd, log: tracker.events)
        await refreshAdvice(for: state)
    }

    /// Wait-impact annotator (plan §4.6). Pure `@Sendable` — depends only on
    /// the passed event + tracked state, so it's a static closure. Flags a
    /// discard/meld whose tile I was waiting on (would drop that wait's live
    /// count). Computed against the seen histogram *minus* this event's own
    /// tiles, so a discard that kills a wait outright is still flagged.
    private static let waitImpactAnnotator: @Sendable (GameEvent, TrackedTableState) -> Set<GameEvent.Flag> = { event, state in
        let tiles: [Tile]
        switch event.kind {
        case let .discard(_, tile, _): tiles = [tile]
        case let .meld(_, _, meldTiles, _, _): tiles = meldTiles
        default: return []
        }
        // Only meaningful for a settled 13-tile wait shape (opponents discard
        // on my off-turns); skip mid-draw 14-tile hands.
        guard state.myHand.count % 3 == 1 else { return [] }
        var seen = state.seenHistogram
        for t in tiles where !t.isBonus && seen.indices.contains(t.classIndex) {
            seen[t.classIndex] = max(0, seen[t.classIndex] - 1)
        }
        let waits = EfficiencyEngine.ukeire(state.myHand.map(\.face), melds: state.meldsAsMelds, seen: seen)
        guard !waits.isEmpty else { return [] }
        return tiles.contains { waits[$0] != nil } ? [.reducesMyWaits] : []
    }

    /// Sends an unresolved tile to a zone. Real path: lock the track's zone via
    /// the facade (`.myHand` / `.pond`) and republish. Mock path: the original
    /// local mutation, so the correction sheet stays interactive in MJ_SCREEN
    /// scenes with no tracker behind it.
    func assignUnresolved(_ id: UUID, to zone: ZoneKind) {
        if let tracker, let trackID = unresolvedTrackByUUID[id] {
            switch zone {
            case .mine:  tracker.overrideZone(track: trackID, to: .myHand)
            case .table: tracker.overrideZone(track: trackID, to: .pond)
            }
            publishAfterCorrection()
            return
        }
        guard let index = unresolved.firstIndex(where: { $0.id == id }) else { return }
        let item = unresolved.remove(at: index)
        guard let face = item.tile else { return }   // truly unknown face — nothing to place
        switch zone {
        case .mine:
            let track = TrackedTile(id: nextTrackID(), face: face, box: item.box,
                                    zone: .myHand, state: .live, firstSeen: 0, lastSeen: 0)
            if drawnTile == nil, handTiles.count >= 13 {
                drawnTile = track
            } else {
                handTiles.append(track)
            }
        case .table:
            seenHistogram[face.classIndex] += 1
            seenTotal += 1
        }
        recomputeAdvice()
    }

    func dismissUnresolved(_ id: UUID) {
        if let tracker, let trackID = unresolvedTrackByUUID[id] {
            tracker.removeTrack(trackID)
            publishAfterCorrection()
            return
        }
        unresolved.removeAll { $0.id == id }
    }

    func overrideHandTile(_ id: TrackID, as tile: Tile) {
        if let tracker {
            tracker.pin(track: id, as: tile)     // `handTiles`/`drawnTile` carry real TrackIDs
            publishAfterCorrection()
            return
        }
        if let index = handTiles.firstIndex(where: { $0.id == id }) {
            handTiles[index].face = tile
            handTiles[index].isPinned = true
        } else if drawnTile?.id == id {
            drawnTile?.face = tile
            drawnTile?.isPinned = true
        }
        recomputeAdvice()
    }

    /// Adjust the seen count for a tile class. No single facade call maps to
    /// this, so the real path reaches the target by inserting/removing pond
    /// tracks of that face (both count toward `seenHistogram`).
    func setSeenCount(classIndex: Int, count: Int) {
        if let tracker {
            let hist = tracker.state.seenHistogram
            let current = hist.indices.contains(classIndex) ? hist[classIndex] : 0
            let target = max(0, min(4, count))
            if target > current, let face = Tile(classIndex: classIndex) {
                for _ in 0..<(target - current) {
                    tracker.insertMissedTile(face: face, zone: .pond, seat: nil, near: nil)
                }
            } else if target < current {
                let removable = tracker.state.pond.filter { $0.face.classIndex == classIndex }
                for track in removable.prefix(current - target) { tracker.removeTrack(track.id) }
            }
            publishAfterCorrection()
            return
        }
        guard seenHistogram.indices.contains(classIndex) else { return }
        seenHistogram[classIndex] = max(0, min(4, count))
        seenTotal = seenHistogram.reduce(0, +)
        recomputeAdvice()
    }

    /// Fix an event: `actor` → `amendEvent(seat:)` (re-attributes the discard/
    /// meld); `tile` → `pin` the underlying pond track. Mock path mutates the
    /// projected event directly.
    func amendEvent(_ id: UUID, tile: Tile?, actor: Wind?) {
        if let tracker, let backingID = eventBackingIDByUUID[id] {
            if let tile, let trackID = eventTileTrackByBackingID[backingID] {
                tracker.pin(track: trackID, as: tile)
            }
            if let actor {
                tracker.amendEvent(backingID, seat: relativeSeat(forAbsolute: actor,
                                                                 mySeatWind: tracker.state.mySeatWind))
            }
            publishAfterCorrection()
            return
        }
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        if let tile { events[index].tiles = [tile] }
        if let actor { events[index].actor = actor }
        recomputeAdvice()
    }

    func deleteEvent(_ id: UUID) {
        if let tracker, let backingID = eventBackingIDByUUID[id] {
            tracker.deleteEvent(backingID)
            publishAfterCorrection()
            return
        }
        events.removeAll { $0.id == id }
    }

    /// Applies the confirmed rotation and continues into the next hand. Real
    /// path: the facade rotates the winds + resets the table (`confirmHandEnd`);
    /// `applyState` then pulls the fresh winds/empty table. Mock path: the
    /// original local reset.
    func confirmHandEnd(winner: Wind?, isDraw: Bool) {
        if let tracker {
            let seat: RelativeSeat? = isDraw ? nil
                : winner.map { relativeSeat(forAbsolute: $0, mySeatWind: tracker.state.mySeatWind) }
            tracker.confirmHandEnd(winner: seat)
            winDetected = nil
            wasHandComplete = false
            phase = .rest
            publishAfterCorrection()
            return
        }
        if let boundary = handBoundary {
            seatWind = boundary.predictedSeatWind
            roundWind = boundary.predictedRoundWind
        }
        handBoundary = nil
        pond = []
        events = []
        unresolved = []
        myMelds = []
        opponentMelds = [:]
        handTiles = []
        drawnTile = nil
        winDetected = nil
        phase = .rest
        recomputeAdvice()
    }

    /// Dismisses a hand-end proposal without ending the hand (a mis-detected
    /// table clear — a walk-by, a lean-over). Facade counterpart on the real
    /// path; a local clear otherwise.
    func dismissHandEnd() {
        if let tracker {
            tracker.dismissHandEnd()
            publishAfterCorrection()
            return
        }
        handBoundary = nil
    }

    /// Ends the session: cancels the tracking loop. The camera is owned by
    /// `ScanView` (the §5 hoist) and keeps running for the return to Scan, so
    /// it's deliberately NOT stopped here; the idle timer is reset by
    /// `CoachLiveFlowView.onDisappear` + `ScanCoordinator.endCoachLive()`.
    /// Idempotent — safe to call from multiple teardown paths.
    func end() {
        isEnded = true
        loopTask?.cancel()
        loopTask = nil
    }

    /// scenePhase → background: idle the loop (the flow view stops the camera).
    func pauseLoop() { isPaused = true }
    /// scenePhase → foreground: resume polling.
    func resumeLoop() { isPaused = false }

    // MARK: - Publish (real path: TrackedTableState → UI surface)

    /// Immediately reflects a correction on the UI surface (bypassing the 300 ms
    /// coalescing so edits feel instant), then refreshes advice off-main.
    private func publishAfterCorrection() {
        guard let tracker else { return }
        let state = tracker.state
        applyState(state, pending: tracker.pendingHandEnd, log: tracker.events)
        Task { @MainActor [weak self] in await self?.refreshAdvice(for: state) }
    }

    /// Projects a fresh `TrackedTableState` (+ pending boundary + event log)
    /// onto the published surface. Synchronous — advice is refreshed separately
    /// (`refreshAdvice`). Preserves one UUID per underlying tracker id across
    /// republishes so ForEach identity (and the pond append / event insert
    /// transitions) stays stable.
    private func applyState(_ state: TrackedTableState, pending: HandEndProposal?, log: [GameEvent]) {
        lastPublishedRevision = state.revision
        lastPublishTime = CACurrentMediaTime()

        seatWind = state.mySeatWind
        roundWind = state.roundWind

        // Hand / drawn split: a 14th (drawn) tile exists iff the concealed count
        // is 2 mod 3 (melds come in 3s). The drawn tile is the freshest one.
        let hand = state.myHand
        if hand.count % 3 == 2, let drawn = hand.max(by: { $0.firstSeen < $1.firstSeen }) {
            drawnTile = drawn
            handTiles = hand.filter { $0.id != drawn.id }
        } else {
            drawnTile = nil
            handTiles = hand
        }

        myMelds = state.meldsAsMelds

        // Opponent melds → scored Melds; concealed chips for meld-less seats.
        var oppMelds: [RelativeSeat: [Meld]] = [:]
        for (seat, groups) in state.opponentMelds {
            let melds = groups.compactMap { group -> Meld? in
                let faces = group.map(\.face)
                guard let kind = MeldClassifier.classify(faces) else { return nil }
                return Meld(kind: kind, tiles: faces, isConcealed: false)
            }
            if !melds.isEmpty { oppMelds[seat] = melds }
        }
        opponentMelds = oppMelds
        var counts: [RelativeSeat: Int] = [:]
        for seat in [RelativeSeat.left, .across, .right] where (oppMelds[seat]?.isEmpty ?? true) {
            counts[seat] = 13
        }
        concealedCounts = counts

        // Pond (stable UUIDs; ring the two freshest discards).
        let newestPond = Set(state.pond.sorted { $0.firstSeen > $1.firstSeen }.prefix(2).map(\.id))
        var newPondUUID: [TrackID: UUID] = [:]
        pond = state.pond.map { track in
            let uuid = pondUUIDByTrack[track.id] ?? UUID()
            newPondUUID[track.id] = uuid
            return PondEntry(id: uuid, tile: track.face, isNewest: newestPond.contains(track.id))
        }
        pondUUIDByTrack = newPondUUID

        // Unresolved (stable UUIDs + UUID→TrackID for the assign sheet).
        var newUnresUUID: [TrackID: UUID] = [:]
        var newUnresTrack: [UUID: TrackID] = [:]
        unresolved = state.unresolved.map { track in
            let uuid = unresolvedUUIDByTrack[track.id] ?? UUID()
            newUnresUUID[track.id] = uuid
            newUnresTrack[uuid] = track.id
            let face: Tile? = track.faceConfidence >= trackerConfig.faceConfidenceFloor ? track.face : nil
            return UnresolvedTile(id: uuid, tile: face, box: track.box)
        }
        unresolvedUUIDByTrack = newUnresUUID
        unresolvedTrackByUUID = newUnresTrack

        seenHistogram = state.seenHistogram
        seenTotal = state.seenHistogram.reduce(0, +)

        // Zone geometry for the bracket overlay (§7): union boxes per zone.
        zoneBoxes = ZoneBoxes(
            mine: (state.myHand + state.myBonus + state.myMelds.flatMap { $0 }).map(\.box),
            table: state.pond.map(\.box) + state.opponentMelds.values.flatMap { $0.flatMap { $0 } }.map(\.box),
            unresolved: state.unresolved.map(\.box))

        applyEvents(log)

        // Lifecycle signals.
        if let pending, let winds = pending.predictedWinds {
            handBoundary = HandBoundaryPrediction(predictedRoundWind: winds.roundWind,
                                                  predictedSeatWind: winds.mySeatWind,
                                                  guessedWinner: wasHandComplete ? state.mySeatWind : nil)
        } else {
            handBoundary = nil
        }
        if state.isMyHandComplete && !wasHandComplete {
            // Rising edge only — so "Keep playing" (which clears winDetected)
            // isn't overridden by the next republish.
            winDetected = WinInfo(isSelfDraw: true, winningTile: drawnTile?.face)
        }
        wasHandComplete = state.isMyHandComplete
    }

    /// One projected UI event, plus the pond track it references (for a tile fix).
    private struct ProjectedEvent {
        var actor: Wind
        var kind: TableEvent.Kind
        var tiles: [Tile]
        var track: TrackID?
    }

    private func applyEvents(_ log: [GameEvent]) {
        // Monotonic `at` → wall-clock date for `compactAge` display, recomputed
        // each publish (`Date()` is banned in the tracker, not the UI).
        let nowMono = CACurrentMediaTime()
        let nowWall = Date()
        var newUUID: [Int: UUID] = [:]
        var newBacking: [UUID: Int] = [:]
        var newTileTrack: [Int: TrackID] = [:]
        var out: [TableEvent] = []
        for event in log {
            guard let p = projectedEvent(event.kind) else { continue }
            let uuid = eventUUIDByBackingID[event.id] ?? UUID()
            newUUID[event.id] = uuid
            newBacking[uuid] = event.id
            if let track = p.track { newTileTrack[event.id] = track }
            out.append(TableEvent(id: uuid, actor: p.actor, kind: p.kind, tiles: p.tiles,
                                  date: nowWall.addingTimeInterval(event.at - nowMono),
                                  waitDelta: event.flags.contains(.reducesMyWaits) ? -1 : nil))
        }
        events = out
        eventUUIDByBackingID = newUUID
        eventBackingIDByUUID = newBacking
        eventTileTrackByBackingID = newTileTrack
    }

    /// Maps a tracker `GameEvent.Kind` to the UI's `TableEvent` projection.
    /// Lifecycle kinds (handStarted/proposed/cancelled/ended/stateRevised/
    /// myHandComplete) return nil — they surface as flags/banners, not log rows.
    private func projectedEvent(_ kind: GameEvent.Kind) -> ProjectedEvent? {
        switch kind {
        case let .discard(seat, tile, track):
            return ProjectedEvent(actor: seat.wind(mySeatWind: seatWind), kind: .discard, tiles: [tile], track: track)
        case let .myDiscard(tile, track):
            return ProjectedEvent(actor: seatWind, kind: .discard, tiles: [tile], track: track)
        case let .myDraw(tile):
            return ProjectedEvent(actor: seatWind, kind: .draw, tiles: tile.map { [$0] } ?? [], track: nil)
        case let .meld(seat, meldKind, tiles, _, _):
            return ProjectedEvent(actor: seat.wind(mySeatWind: seatWind), kind: .meld(meldKind), tiles: tiles, track: nil)
        default:
            return nil
        }
    }

    /// Advice via the off-main memoizing cache (plan §5), then published on main.
    /// `@MainActor` so the post-`await` `advice` assignment always resumes on
    /// the main actor (SwiftUI reads it there).
    @MainActor
    private func refreshAdvice(for state: TrackedTableState) async {
        guard let advisorCache else { return }
        advice = await advisorCache.advice(for: coachTable(from: state))
    }

    /// `TrackedTableState` → `CoachEngine.TableState` (context from the tracked
    /// winds + standard house rules; `drawsRemaining` nil so the advisor derives
    /// go-arounds from `unseenCount`).
    private func coachTable(from state: TrackedTableState) -> CoachEngine.TableState {
        CoachEngine.TableState(
            concealed: state.myHand.map(\.face),
            melds: state.meldsAsMelds,
            bonusTiles: state.myBonus.map(\.face),
            seenHistogram: state.seenHistogram,
            unseenCount: state.unseenCount,
            drawsRemaining: nil,
            opponentMeldCount: state.opponentMelds.values.reduce(0) { $0 + $1.count },
            context: GameContext(seatWind: state.mySeatWind, prevailingWind: state.roundWind, houseRules: .standard))
    }

    /// Absolute `Wind` → seat relative to `mySeatWind` (for facade corrections).
    private func relativeSeat(forAbsolute wind: Wind, mySeatWind: Wind) -> RelativeSeat {
        RelativeSeat(rawValue: (wind.rawValue - mySeatWind.rawValue + 4) % 4) ?? .me
    }

    // MARK: - Local recomputation (pure — safe to call from any mutation above)

    private var nextTrackRaw = 10_000
    private func nextTrackID() -> TrackID {
        defer { nextTrackRaw += 1 }
        return TrackID(raw: nextTrackRaw)
    }

    /// Re-derives `advice` from the current hand + seen counts via the real
    /// (placeholder) `CoachAdvisor` — pure and cheap, so every mutation above
    /// calls it directly instead of waiting on a later async pipeline. Once
    /// the tracker's own commit loop lands, it can call this same function
    /// after each settle instead of the UI doing it eagerly per-edit.
    func recomputeAdvice() {
        let concealed = handTiles.map(\.face) + (drawnTile.map { [$0.face] } ?? [])
        let meldTileCount = myMelds.reduce(0) { $0 + $1.tiles.filter { !$0.isBonus }.count }
        let seen = seenHistogram.reduce(0, +)
        let unseen = max(1, 136 - concealed.count - meldTileCount - seen)
        let table = TableState(concealed: concealed,
                               melds: myMelds,
                               seenHistogram: seenHistogram,
                               unseenCount: unseen,
                               opponentMeldCount: opponentMelds.values.reduce(0) { $0 + $1.count },
                               context: GameContext(seatWind: seatWind, prevailingWind: roundWind))
        advice = CoachAdvisor.advise(table)
    }

    /// Synthesizes a `[DetectedTile]` "table pool" from the pond + opponent
    /// melds for `ScanCoordinator.beginScoreHandoff` — good enough for
    /// `ScanSession.seenHistogram`/`unseenCount` post-handoff; boxes are
    /// placeholders since scoring never reads them.
    var tablePoolAsDetected: [DetectedTile] {
        let placeholderBox = TileBoundingBox(x: 0, y: 0, width: 0.05, height: 0.05)
        let pondTiles = pond.map { DetectedTile(tile: $0.tile, confidence: 1, box: placeholderBox) }
        let meldTiles = opponentMelds.values.flatMap { $0 }.flatMap(\.tiles)
            .map { DetectedTile(tile: $0, confidence: 1, box: placeholderBox) }
        return pondTiles + meldTiles
    }
}

// MARK: - Supporting value types (app-local; see plan §1's shorthand structs)

/// Where a corrected unresolved tile belongs.
enum ZoneKind { case mine, table }

/// One pond (discard) tile. `isNewest` rings the most-recently-discarded 1–2
/// entries per the mockup.
struct PondEntry: Identifiable, Hashable {
    let id: UUID
    var tile: Tile
    var isNewest: Bool

    init(id: UUID = UUID(), tile: Tile, isNewest: Bool = false) {
        self.id = id
        self.tile = tile
        self.isNewest = isNewest
    }
}

/// A detected tile the tracker couldn't confidently place in a zone yet.
/// `tile` is nil when even the face is unknown (rendered as a "?" ghost tile).
struct UnresolvedTile: Identifiable, Hashable {
    let id: UUID
    var tile: Tile?
    var box: TileBoundingBox

    init(id: UUID = UUID(), tile: Tile?, box: TileBoundingBox) {
        self.id = id
        self.tile = tile
        self.box = box
    }
}

/// One append-only entry in the UI-facing event log (a simplified projection
/// of `Recognition.GameEvent` — this type only carries what the Events tab
/// renders).
struct TableEvent: Identifiable, Hashable {
    enum Kind: Hashable { case discard, draw, meld(MeldKind), win }

    let id: UUID
    var actor: Wind
    var kind: Kind
    var tiles: [Tile]
    var date: Date
    var waitDelta: Int?

    init(id: UUID = UUID(), actor: Wind, kind: Kind, tiles: [Tile], date: Date, waitDelta: Int? = nil) {
        self.id = id
        self.actor = actor
        self.kind = kind
        self.tiles = tiles
        self.date = date
        self.waitDelta = waitDelta
    }

    /// EventsTab's verb text — "discarded", "drew", "declared a pung of", …
    var verb: String {
        switch kind {
        case .discard: return "discarded"
        case .draw:    return "drew"
        case .win:     return "won with"
        case let .meld(meldKind):
            switch meldKind {
            case .chow: return "declared a chow of"
            case .pung: return "declared a pung of"
            case .kong: return "declared a kong of"
            case .pair: return "declared a pair of"
            }
        }
    }
}

/// Zone geometry for the bracket overlay a later chunk adds to `LiveFeedPane`.
struct ZoneBoxes {
    var mine: [TileBoundingBox] = []
    var table: [TileBoundingBox] = []
    var unresolved: [TileBoundingBox] = []
}

/// A table-cleared → predicted next-hand rotation, surfaced as `HandEndedCard`.
struct HandBoundaryPrediction {
    var predictedRoundWind: Wind
    var predictedSeatWind: Wind
    var guessedWinner: Wind?
}

/// My hand went complete — surfaced as `WinBanner`.
struct WinInfo {
    var isSelfDraw: Bool
    var winningTile: Tile?
}

/// The tracker's cadence state under thermal pressure — see `LivePill`.
enum ThermalCadence { case nominal, throttled }

/// Dev-only diagnostics the live loop records every tick (plan §3: "debug
/// HUD" the triple-tapped LIVE pill reveals). Not read by any production UI
/// path — purely a bisect aid for "why does the pill say 0 tiles seen".
/// `CoachLiveMock` fills what it can (no real loop runs on that path) so the
/// HUD still shows something sensible in mock/screenshot mode.
struct LiveDiagnostics {
    /// Total poll-loop iterations this session (whether or not paused/idle
    /// ticks are excluded — see `CoachLiveSession.startLoop`).
    var loopTicks = 0
    /// Ticks where `camera.latestBuffer` was nil (no frame yet / camera not
    /// running) — a run of these on device means the camera never delivered
    /// a frame, not a recognition problem.
    var nilBufferCount = 0
    /// The most recent `MotionDetector` reading (0 when the last sample was
    /// nil, same as the phase/cadence signal's own fallback).
    var motionLevel: Double = 0
    /// Ticks where `MotionDetector.sample` returned nil (unsupported pixel
    /// format or an unreadable plane/base address — see that type's doc).
    var nilMotionSampleCount = 0
    /// Cadence decision tallies this session.
    var inferDecisions = 0
    var skipDecisions = 0
    var suspendDecisions = 0
    /// Count of `rec.recognize(_:)` calls actually made (⊆ `inferDecisions`
    /// — a cadence "infer" decision still needs a resolved recognizer/live
    /// session to turn into a real call).
    var inferencesRun = 0
    /// `result.tiles.count` from the most recent recognize call, before
    /// tracker ingestion — the rawest "did the model see anything" signal.
    var lastRawDetectionCount = 0
    /// Up to 3 `"code@confidence"` strings for the highest-confidence raw
    /// detections in the most recent recognize call (e.g. `"1m@0.87"`).
    var lastTopDetections: [String] = []
    /// The recognizer's runtime type name (`"VisionRecognizer"` /
    /// `"MockRecognizer"`), resolved once the loop has loaded one.
    var recognizerType = "—"
}
