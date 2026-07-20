import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import QuartzCore
import UIKit
import Observation
import MahjongCore
import Recognition
import CoachEngine
import EfficiencyEngine
import ScoringEngine
import simd
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

    /// The startup waterfall the small LIVE-pill spinner alone proved too
    /// subtle for ("Start tracking did nothing") — `StartupStatusOverlay`
    /// reads this for a prominent center-feed card. Purely additive over
    /// `isWarmingUp` (kept working exactly as before) — see `startLoop` for
    /// the transition sites. Mock path never sets this off `.ready`, so
    /// MJ_SCREEN scenes are unaffected.
    enum StartupStage: Equatable {
        case ready, startingCamera, findingTable, loadingDetector, lookingForTiles
    }
    var startupStage: StartupStage = .ready

    /// True while the AR loop's `CameraMotionGate` reads the camera pose as
    /// moving — the loop skips motion-sample/cadence/inference/ingest
    /// entirely during this window (Lane B chunk D). Drives
    /// `LiveFeedPane`'s "Hold steady…" chip; never set on the mock/fallback
    /// paths (no `CameraMotionGate` runs there).
    var cameraMoving = false

    /// True once `startARLoop`'s never-locks/unavailable fallback has handed
    /// off to the classic `startLoop` — `arCapture` stays non-nil (this
    /// session was still constructed with one), but the LOOP actually
    /// driving the table is the image-space one. Drives the debug HUD's
    /// one-word "AR"/"2D" mode indicator (`LiveFeedPane.debugHUD`); never
    /// set true again once set (a session doesn't re-attempt AR mid-flight).
    var usingFallbackCapture = false

    /// Lane B chunk E: when true (default), `startARLoop` asks
    /// `ROIScheduler` what to infer each still tick — a full frame, one or
    /// two cropped zones, or nothing — instead of always recognizing the
    /// full captured frame. `false` forces the pre-chunk-E behavior (always
    /// full-frame) — an A/B escape hatch for isolating a recall/thermal
    /// regression to the ROI path specifically. Never read by
    /// `startLoop`/the mock path.
    var useROIScheduler = true
    /// One honest source for every published count. A LiDAR session never
    /// silently substitutes legacy tracks while presenting spatial geometry.
    var countSource: CoachLiveCountSource = .legacy2D(.arUnavailable)
    var spatialTrackingHealth: SpatialTrackingHealth = .calibrating
    private var depthMissingSince: TimeInterval?
    private var depthRestartAttempted = false

    /// Continuity counters make the calibration → Live handoff observable in
    /// DEBUG without changing any live behavior. A future continuous-flow
    /// change must keep the session ID and pipeline generation stable while
    /// only this revision changes for an accepted calibration edit.
    private(set) var spatialPipelineGeneration = 0
    private(set) var calibrationRevision = 0

    /// True once the loop's per-tick `MotionSample.meanLuma` has read
    /// "dark" for `DarkTableDetector`'s sustain window — drives
    /// `LiveFeedPane`'s "Dark table — turn on flash?" chip. Never set on the
    /// mock path (no loop runs there).
    var isDark = false
    /// Set when the user dismisses the dark-table chip's "×" — suppresses it
    /// for the rest of the session even if the table stays dark. Reset in
    /// `begin()` so a fresh session always gets one chance to suggest again.
    var torchSuggestionDismissed = false
    /// Pure hysteresis over `isDark` — see `DarkTableDetector`. Single-owner,
    /// fed by the one `darkTableDetector.update` call site in `startLoop`.
    private var darkTableDetector = DarkTableDetector()
    /// Lane B chunk H item 2 (per-zone staleness): monotonic
    /// (`CACurrentMediaTime()`-comparable) timestamp each zone was last
    /// seen ≥60% inside the frame during a still, inferred tracking-mode
    /// tick. A zone with no entry reads as "stale since tracking began" —
    /// see `zoneTrackingStartedAt`.
    private var zoneLastSeenOnScreen: [TableZoneID: TimeInterval] = [:]
    /// Whether a zone has EVER carried live tracks this session — the
    /// staleness prompt only nags about zones the tracker actually has (or
    /// had) a stake in, not geometry the table simply never had tiles in.
    /// Updated every publish (`applyState`).
    private var zoneEverHadTracks: Set<TableZoneID> = []
    /// Per-zone rescan-prompt cooldown: the timestamp a zone was last
    /// actually shown, so it doesn't re-fire within 90s of its own last
    /// showing (a DIFFERENT stale zone can still interrupt sooner).
    private var zoneLastPromptedAt: [TableZoneID: TimeInterval] = [:]
    /// When the current tracker started (table-lock time, real or
    /// resumed) — the staleness baseline for a zone that's never once been
    /// seen this session.
    private var zoneTrackingStartedAt: TimeInterval = 0

    /// Lane B chunk H item 2's directional rescan-prompt chip, or `nil`
    /// when nothing's stale enough (or the throttle/action-phase gates
    /// suppress it). `LiveFeedPane` renders it under the pill, priority
    /// below `holdSteadyChip`, above `darkTableChip`. Never set on the
    /// mock/fallback paths (no per-zone tracking runs there).
    struct RescanPrompt: Equatable {
        var zone: TableZoneID
        var text: String
    }
    var rescanPrompt: RescanPrompt?

    /// A recount is an inference request, not a capture lifecycle. It stays
    /// pending through camera motion, relocalization, and thermal suspension,
    /// and is consumed only after the loop selects an executable inference
    /// plan on a still frame.
    private enum RecountRequest {
        case fullTable
        case zone(TableZoneID)
    }
    private var recountRequest: RecountRequest?

    /// Dev-only diagnostics the loop records every tick — powers the
    /// triple-tap debug HUD; see `LiveDiagnostics`.
    var diagnostics = LiveDiagnostics()
    /// Authoritative LiDAR census. It receives the exact detections already
    /// produced by Coach Live and never schedules model work of its own.
    private(set) var worldCensusController: WorldCensusController?
    private var lastARImageOrientation: CGImagePropertyOrientation?
    /// `tracker.diagnostics` passthrough for the HUD — `nil` tracker (mock
    /// path) reads as all-zero rather than requiring the HUD to unwrap.
    var trackerDiagnostics: Recognition.TrackerDiagnostics { tracker?.diagnostics ?? Recognition.TrackerDiagnostics() }

    /// Drives guided marking on the same continuous ARSession as Live.
    var showARCalibration = false
    var isRecenterPondActive = false

    private struct CalibrationDraft {
        let acceptedCalibration: WorldTableCalibration?
        let acceptedLegacyGeometry: TrackerConfig.TableGeometry?
        let acceptedCountSource: CoachLiveCountSource
        let acceptedHealth: SpatialTrackingHealth
        let isInitialSetup: Bool
        let sessionID: UUID?
        let pipelineGeneration: Int
        let resetTrackingRunCount: Int
        let removeExistingAnchorsRunCount: Int
    }
    private var calibrationDraft: CalibrationDraft?
    private var calibrationHasBeenFinalized = false
    private var needsFreshARStartAfterCalibrationCancel = false

    @MainActor
    func beginARCalibration() {
        guard !showARCalibration else { return }
        let ar = arCapture?.sessionDiagnostics
        calibrationDraft = CalibrationDraft(
            acceptedCalibration: worldTableCalibration,
            acceptedLegacyGeometry: calibratedTableGeometry,
            acceptedCountSource: countSource,
            acceptedHealth: spatialTrackingHealth,
            isInitialSetup: worldTableCalibration == nil && !calibrationHasBeenFinalized,
            sessionID: ar?.sessionID,
            pipelineGeneration: spatialPipelineGeneration,
            resetTrackingRunCount: ar?.resetTrackingRunCount ?? 0,
            removeExistingAnchorsRunCount: ar?.removeExistingAnchorsRunCount ?? 0
        )
        // Draft calibration is never allowed to publish legacy geometry/counts
        // alongside spatial review. The calibration view owns its preview;
        // Live remains bootstrap-empty until final acceptance.
        countSource = .spatialBootstrapping
        spatialTrackingHealth = .calibrating
        publishBootstrapState()
        refreshSpatialContinuityDiagnostics()
        showARCalibration = true
    }

    @MainActor
    func applyARCalibrationDraft(_ calibration: WorldTableCalibration) {
        guard calibrationDraft != nil else { return }
        applyCalibration(calibration, persist: false)
        countSource = .spatialBootstrapping
        spatialTrackingHealth = .calibrating
        publishBootstrapState()
    }

    @MainActor
    func finishARCalibration(_ calibration: WorldTableCalibration?) {
        guard let draft = calibrationDraft else {
            showARCalibration = false
            return
        }
        guard let calibration else {
            cancelARCalibration(draft)
            return
        }

        // Apply once more so confirmation always finalizes the last displayed
        // review geometry, then invalidate/replace persistence exactly once.
        applyCalibration(calibration, persist: false)
        arCapture?.invalidatePersistedCalibration()
        arCapture?.updateTableCalibration(calibration)
        recountRequest = .fullTable
        calibrationHasBeenFinalized = true
        if ARTableCapture.supportsSceneDepth {
            countSource = .worldCensus
            spatialTrackingHealth = .healthy
        } else {
            countSource = .legacy2D(.depthUnsupported)
            spatialTrackingHealth = .depthUnavailable
        }
        startupStage = .ready
        verifyCalibrationContinuity(from: draft, phase: "finalize")
        calibrationDraft = nil
        showARCalibration = false
        let state = presentationState(preserving: tracker?.state ?? .empty)
        applyState(state, pending: tracker?.pendingHandEnd, log: tracker?.events ?? [])
        refreshSpatialContinuityDiagnostics()
    }

    /// Cancels an initial guided run and makes the setup card's next Start a
    /// genuinely fresh loop. Live recalibration instead restores its accepted
    /// geometry/controller/source in place.
    @MainActor
    func cancelInitialARCalibration() {
        guard let draft = calibrationDraft, draft.isInitialSetup else { return }
        cancelARCalibration(draft)
    }

    @MainActor
    private func cancelARCalibration(_ draft: CalibrationDraft) {
        if draft.isInitialSetup {
            showARCalibration = false
            calibrationDraft = nil
            calibrationHasBeenFinalized = false
            loopTask?.cancel()
            loopTask = nil
            tracker = nil
            worldCensusController = nil
            worldTableCalibration = draft.acceptedCalibration
            calibratedTableGeometry = draft.acceptedLegacyGeometry
            isEnded = false
            isPaused = false
            usingFallbackCapture = false
            arCapture?.discardInMemoryUnacceptedOrigin()
            arCapture?.pause()
            needsFreshARStartAfterCalibrationCancel = true
            return
        }
        if let calibration = draft.acceptedCalibration {
            applyCalibration(calibration, persist: false)
        } else {
            worldTableCalibration = nil
            calibratedTableGeometry = draft.acceptedLegacyGeometry
        }
        countSource = draft.acceptedCountSource
        spatialTrackingHealth = draft.acceptedHealth
        calibrationDraft = nil
        showARCalibration = false
        let state = presentationState(preserving: tracker?.state ?? .empty)
        applyState(state, pending: tracker?.pendingHandEnd, log: tracker?.events ?? [])
        refreshSpatialContinuityDiagnostics()
    }

    @MainActor
    private func applyCalibration(_ calibration: WorldTableCalibration, persist: Bool) {
        calibrationRevision += 1
        worldTableCalibration = calibration
        calibratedTableGeometry = Self.legacyGeometry(from: calibration, mySeatWind: seatWind)
        worldCensusController?.apply(calibration, at: CACurrentMediaTime())
        arCapture?.updateTableCalibration(calibration, persist: persist)
        refreshSpatialContinuityDiagnostics()
    }

    @MainActor
    private func publishBootstrapState() {
        guard let tracker else { return }
        let state = CensusStateAdapter.makeBootstrapState(preserving: tracker.state)
        applyState(state, pending: tracker.pendingHandEnd, log: tracker.events)
    }

    @MainActor
    private func verifyCalibrationContinuity(from draft: CalibrationDraft, phase: String) {
        guard let capture = arCapture else { return }
        let current = capture.sessionDiagnostics
        let continuous = current.sessionID == draft.sessionID
            && spatialPipelineGeneration == draft.pipelineGeneration
            && current.resetTrackingRunCount == draft.resetTrackingRunCount
            && current.removeExistingAnchorsRunCount == draft.removeExistingAnchorsRunCount
        guard !continuous else { return }
        let message = "AR continuity violation at \(phase): session/pipeline/reset changed during calibration"
        Self.logger.error("\(message, privacy: .public)")
        #if DEBUG
        assertionFailure(message)
        #endif
    }

    /// User-confirmed table geometry from the ARKit-native calibration flow
    /// (`ARCalibrationView`). `TableGeometry`'s three scalars are orientation-
    /// normalized (extent in metres, hand-band depth / pond radius as fractions),
    /// so a geometry captured during calibration transfers cleanly onto the play
    /// loop's own plane lock. This scalar compatibility geometry is used only
    /// by the explicit legacy event/count fallback; spatial ROI, ownership,
    /// brackets, and overlays consume `worldTableCalibration`.
    var calibratedTableGeometry: TrackerConfig.TableGeometry?
    private(set) var worldTableCalibration: WorldTableCalibration?

    private static func legacyGeometry(
        from calibration: WorldTableCalibration,
        mySeatWind: Wind
    ) -> TrackerConfig.TableGeometry {
        // The legacy event-only tracker still accepts a scalar extent. Use
        // the mean solely for that compatibility adapter; AR ownership, ROI,
        // brackets, and counts consume the rectangular calibration directly.
        let extent = Double((calibration.extent.x + calibration.extent.y) * 0.5)
        let hand = calibration.handPolygon
        let pond = calibration.pondPolygon
        return TableCalibrationGeometry.geometry(
            extentMetres: extent,
            handPostA: hand.first.map { SIMD2(Double($0.x), Double($0.y)) },
            handPostB: hand.dropFirst().first.map { SIMD2(Double($0.x), Double($0.y)) },
            pondCornerA: pond.first.map { SIMD2(Double($0.x), Double($0.y)) },
            pondCornerB: pond.dropFirst(2).first.map { SIMD2(Double($0.x), Double($0.y)) },
            pondQuad: pond.map { SIMD2(Double($0.x), Double($0.y)) },
            mySeatWind: mySeatWind
        )
    }

    /// Mirrors key pipeline transitions to Console.app (subsystem matches the
    /// bundle id) — plan §3: works even off a connected debugger.
    private static let logger = Logger(subsystem: "com.lumiodatalabs.MahjongSensei", category: "coachlive")

    /// The most recent camera frame, snapshotted for `beginScoreHandoff`'s
    /// `CapturedBackdrop` continuity. Nil until the real capture loop (a
    /// later chunk) starts writing it.
    var lastFrameSnapshot: UIImage?

    // MARK: Camera — the UI needs only `.session` (preview) and `.setTorch(_:)`.
    // Retained even when `arCapture` drives the live loop: it's still the
    // permanent fallback (never-locks degrade, Lane B chunk D) and the
    // continuity device Scan resumes on exit (chunk G) — `ScanFlow` owns its
    // lifecycle (`stop()`/`requestAndStart()`) around the AR session's own.
    let camera: CameraCapture

    /// ARKit table capture (Lane B) — `nil` on the mock/headless path
    /// (`CoachLiveMock`, MJ_SCREEN, and the Simulator's `ScanCoordinator`
    /// entry all construct a session without one) and on any real session
    /// built before Lane B's device wiring landed. Non-nil ⇒ `begin()`/
    /// `resume(from:)` drive the AR loop (`startARLoop`) instead of the
    /// classic image-space camera loop (`startLoop`, which stays the
    /// permanent fallback both for plane-lock failure and for this literal
    /// nil case).
    let arCapture: ARTableCapture?

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
    /// When true, the AR loop SKIPS inference/ingest while the camera reads as
    /// moving (`CameraMotionGate`) — the old thermal/blur guard. Now **false**
    /// by default: detection runs continuously so tracking keeps up while you
    /// pan a handheld iPad (per-track position smoothing, `TrackerConfig
    /// .positionSmoothing`, absorbs the extra motion-frame noise). The `moving`
    /// signal is still computed for the "hold steady" chip + bracket re-project.
    private static let motionPausesInference = false
    /// When true, the AR loop's `.fullFrame` refresh passes (the periodic
    /// safety net + each moving→still settle) are recognized via
    /// `TiledTileRecognizer` — an overlapping NATIVE-resolution 3×4 grid over
    /// the whole table — instead of one 640-letterboxed full-frame pass. This
    /// is the recall fix for the dense central pond (~45 tiles, ~15px each when
    /// the 4:3 frame is squished to 640) AND the opponents' revealed melds.
    /// Between refreshes the cheap per-zone crop path keeps latency down.
    private static let tilesFullFrameRefresh = true
    private var lastPublishedRevision = -1
    private var lastPublishTime: TimeInterval = 0

    // Persistence (plan A6: survive relaunch) — throttled disk snapshot,
    // real path only. See `persistIfDue`.
    private static let persistInterval: TimeInterval = 5.0
    private var lastPersistTime: TimeInterval = 0
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

    init(camera: CameraCapture, arCapture: ARTableCapture? = nil,
        recognizerProvider: (@Sendable () async -> any Recognizer)? = nil) {
        self.camera = camera
        self.arCapture = arCapture
        self.recognizerProvider = recognizerProvider
    }

    // MARK: - Intents (UI → tracker)

    /// Starts a session at the given winds.
    ///
    /// On the real (camera-backed) path this spins up the polling loop —
    /// `startARLoop` (which itself defers building the tracker until the
    /// table plane locks) when `arCapture` is set, else the classic
    /// `startLoop` (which builds the tracker immediately, injecting the win
    /// predicate + wait-impact annotator and beginning the tracker session
    /// up front). On the mock/headless path (`recognizerProvider == nil`) it
    /// stays the original stub — assign the winds and let `CoachLiveMock`
    /// drive the published state directly.
    func begin(roundWind: Wind, seatWind: Wind) {
        if needsFreshARStartAfterCalibrationCancel {
            MainActor.assumeIsolated { arCapture?.start() }
            needsFreshARStartAfterCalibrationCancel = false
        }
        isEnded = false
        isPaused = false
        self.roundWind = roundWind
        self.seatWind = seatWind
        phase = .rest
        // Fresh session ⇒ fresh chance to suggest the torch, even if a prior
        // session on this same instance had it dismissed.
        torchSuggestionDismissed = false
        isDark = false
        darkTableDetector = DarkTableDetector()
        resetSpatialTrackingState()

        guard let recognizerProvider, tracker == nil else { return }
        // Fresh start supersedes any stale resume — a new `begin()` means the
        // user explicitly chose not to (or had nothing to) resume.
        Task { await CoachLiveSessionStore.shared.clear() }
        isWarmingUp = true
        startupStage = .startingCamera
        if arCapture != nil {
            startARLoop(recognizerProvider: recognizerProvider)
        } else {
            startLoop(recognizerProvider: recognizerProvider)
        }
    }

    /// Restores a previously persisted 2D session instead of starting empty:
    /// winds/event log/confirmed tiles from `persisted.snapshot` become this
    /// session's starting point. AR sessions intentionally retain only their
    /// relocalized `WorldTableCalibration`; tile identities/counts never cross
    /// a launch.
    ///
    /// Real
    /// (camera-backed) path only, exactly like `begin()` — the mock/headless
    /// path (`recognizerProvider == nil`, e.g. `CoachLiveSetupView`'s
    /// synthetic MJ_SCREEN resumable) has no tracker to restore onto and
    /// simply stays put.
    func resume(from persisted: PersistedCoachLiveSession) {
        seatWind = persisted.snapshot.mySeatWind
        roundWind = persisted.snapshot.roundWind
        phase = .rest
        torchSuggestionDismissed = false
        isDark = false
        darkTableDetector = DarkTableDetector()
        resetSpatialTrackingState()

        guard let recognizerProvider, tracker == nil else { return }
        isWarmingUp = true
        startupStage = .startingCamera

        if arCapture != nil {
            Task { await CoachLiveSessionStore.shared.clear() }
            startARLoop(recognizerProvider: recognizerProvider)
            return
        }

        // Cross-mode resume guard (Lane B chunk D): a table-space archive's
        // boxes are anchor-local metres, an image-space archive's are
        // oriented-image fractions — restoring the wrong one onto this
        // session's capture mode would plant every tile at a nonsense
        // position. Degrade to a fresh start (still at the archive's winds)
        // rather than restore geometry that doesn't mean what it looks like.
        let currentMode = PersistedCoachLiveSession.CoordinateSpaceMarker.imageSpace
        var restoring: PersistedCoachLiveSession? = persisted
        if persisted.coordinateSpace != currentMode {
            Self.logger.notice("resume archive coordinate space (\(persisted.coordinateSpace.rawValue, privacy: .public)) doesn't match the current capture mode (\(currentMode.rawValue, privacy: .public)) — starting fresh instead")
            restoring = nil
        }

        startLoop(recognizerProvider: recognizerProvider, restoredFrom: restoring)
    }

    // MARK: - Live loop

    /// `restoredFrom` non-nil ⇒ a resume (plan A6): seeds the tracker via
    /// `TableTracker.restore` instead of `beginSession` and immediately
    /// republishes the restored state (+ advice) synchronously so the live
    /// view never shows a blank table while the first tick warms up. Every
    /// other line — the loop task body itself — is unchanged by which branch
    /// ran, exactly the same polling/cadence/publish machinery either way.
    private func startLoop(recognizerProvider: @escaping @Sendable () async -> any Recognizer,
                           restoredFrom persisted: PersistedCoachLiveSession? = nil) {
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
        if let persisted {
            tracker.restore(persisted.remapped(toNowMono: start), at: start)
            let state = tracker.state
            applyState(state, pending: tracker.pendingHandEnd, log: tracker.events)
            Task { @MainActor [weak self] in await self?.refreshAdvice(for: state) }
        } else {
            tracker.beginSession(mySeatWind: seatWind, roundWind: roundWind, at: start)
        }

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
                // First frame the camera has actually delivered — the camera
                // itself is up; next the detector needs to load.
                if self.startupStage == .startingCamera { self.startupStage = .loadingDetector }
                let now = CACurrentMediaTime()
                if self.orientedImageSize == .zero {
                    self.orientedImageSize = RecognizerFrame.buffer(buffer, orientation: .right).orientedPixelSize
                }

                // Motion every tick (~8 Hz), independent of inference — feeds
                // both the breathing phase and the cadence decision.
                let sample = motion.sample(buffer, at: now)
                if sample == nil { self.diagnostics.nilMotionSampleCount += 1 }
                // A5: dark-table torch suggestion — the one call site feeding
                // `DarkTableDetector`'s hysteresis; `meanLuma` rides the same
                // per-tick motion sample, so this costs nothing extra to read.
                if let luma = sample?.meanLuma {
                    self.darkTableDetector.update(meanLuma: luma, at: now)
                    self.isDark = self.darkTableDetector.isDark
                }
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
                    if self.startupStage == .loadingDetector { self.startupStage = .lookingForTiles }
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

                await self.finishTick(loopStart: start)
            }
        }
    }

    /// Shared end-of-tick bookkeeping for both loops (`startLoop`'s
    /// image-space camera path and `startARLoop`'s AR path): coalesced
    /// publish, the final startup-overlay promotion, and the shared poll
    /// sleep. Extracted verbatim from `startLoop`'s original tail — a pure
    /// relocation, not a behavior change.
    @MainActor
    private func finishTick(loopStart: TimeInterval) async {
        await publishIfDue(now: CACurrentMediaTime())
        // Final startup promotion: once tiles are actually on the table
        // there's nothing left to wait for, and a genuinely empty table (or
        // a slow first settle) shouldn't leave the overlay up forever — 10s
        // after loop start is the safety net.
        if startupStage != .ready, liveTileCount > 0 || CACurrentMediaTime() - loopStart >= 10 {
            startupStage = .ready
        }
        try? await Task.sleep(for: Self.pollInterval)
    }

    /// The AR-driven live loop (Lane B chunk D; freeze-while-relocalizing
    /// added chunk H). Mirrors `startLoop`'s overall shape
    /// (same 120ms poll, same cadence/breathing/dark/publish machinery
    /// feeding the same published surface — `finishTick` is shared) but
    /// sources frames from `self.arCapture` instead of `camera`, defers
    /// building the tracker until the table plane locks (`config
    /// .coordinateSpace = .tableSpace`), gates every tick on
    /// `CameraMotionGate` (skip motion-sample/cadence/inference/ingest
    /// entirely while the phone is visibly moving), and projects detections
    /// through `Recognition.TableProjection`/`DetectionProjector` before
    /// `tracker.ingest`. Falls back to `startLoop` — verbatim, no
    /// special-casing needed there — when the table never locks within 25s
    /// or ARKit reports `.unavailable` (in practice only the Simulator, and
    /// only if it were ever reached with a live `arCapture`, which
    /// `ScanCoordinator.startCoachLive` never does — see that method).
    ///
    /// Table lock enters tracking immediately and forces one full-frame
    /// inference. `captureStage == .relocalizing` freezes the tick entirely
    /// until ARKit's pose is trustworthy again.
    ///
    /// Reads `self.arCapture` fresh each tick (rather than capturing the
    /// non-`Sendable` `ARTableCapture` instance directly into the `Task`
    /// closure) — the same "go through `self`" discipline `startLoop`
    /// already uses for `self.tracker`/`self.camera`.
    private func startARLoop(
        recognizerProvider: @escaping @Sendable () async -> any Recognizer
    ) {
        spatialPipelineGeneration += 1
        let loopStart = CACurrentMediaTime()
        let arLockDeadline = loopStart + 25

        loopTask = Task { @MainActor [weak self] in
            var cadence = CadencePolicy()
            var motionGate = CameraMotionGate()
            let motion = MotionDetector()
            var roiScheduler = ROIScheduler()
            let pixelBufferCropper = PixelBufferCropper()
            var recognizer: (any Recognizer)?
            var lastInference = CACurrentMediaTime() - 10   // due immediately once tracking starts
            var wasMoving = false
            var forceNextInference = false

            pollLoop: while !Task.isCancelled {
                guard let self, !self.isEnded, let arCapture = self.arCapture else { break }
                if self.isPaused {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                self.diagnostics.loopTicks += 1
                self.refreshSpatialContinuityDiagnostics(capture: arCapture)

                // Startup overlay: `.starting` → `.findingTable` the instant
                // ARKit is delivering frames and hunting for the table.
                if self.startupStage == .startingCamera, arCapture.captureStage == .findingTable {
                    self.startupStage = .findingTable
                }

                // Never-locks / unsupported fallback — checked every tick
                // before the table locks (once locked, `self.tracker` is
                // non-nil and this branch never runs again).
                if self.tracker == nil, arCapture.captureStage == .unavailable || CACurrentMediaTime() >= arLockDeadline {
                    Self.logger.notice("AR table capture unavailable/never locked (stage: \(String(describing: arCapture.captureStage), privacy: .public)) — falling back to image-space capture")
                    self.usingFallbackCapture = true
                    self.countSource = .legacy2D(.arUnavailable)
                    self.spatialTrackingHealth = .trackingLimited
                    arCapture.pause()
                    #if !targetEnvironment(simulator)
                    self.camera.requestAndStart()
                    #endif
                    // AR tile identities never persist. A fallback therefore
                    // starts a clean image-space tracker at the selected winds.
                    self.startLoop(recognizerProvider: recognizerProvider, restoredFrom: nil)
                    break pollLoop
                }

                guard let frame = arCapture.latestFrame else {
                    self.diagnostics.nilBufferCount += 1
                    try? await Task.sleep(for: Self.pollInterval)
                    continue
                }
                if self.orientedImageSize == .zero {
                    self.orientedImageSize = frame.orientedImageSize
                }
                if let previous = self.lastARImageOrientation,
                   previous != frame.imageOrientation {
                    self.lastARImageOrientation = frame.imageOrientation
                    self.orientedImageSize = frame.orientedImageSize
                    self.worldCensusController?.recordOrientationTransition()
                    try? await Task.sleep(for: Self.pollInterval)
                    continue
                }
                self.lastARImageOrientation = frame.imageOrientation
                let now = CACurrentMediaTime()
                self.updateDepthHealth(frame: frame, capture: arCapture, at: now)

                // Table lock → build the tracker HERE, in table space, then
                // begin/restore the session. Nothing above this point ever
                // ingests — `self.tracker` staying nil IS "still hunting."
                if self.tracker == nil {
                    guard let lockedPlaneTransform = arCapture.lockedPlaneTransform else {
                        try? await Task.sleep(for: Self.pollInterval)
                        continue
                    }
                    guard arCapture.captureStage != .relocalizing else {
                        try? await Task.sleep(for: Self.pollInterval)
                        continue
                    }
                    var config = TrackerConfig()
                    config.winPredicate = { concealed, melds in
                        ScoringEngine.isWinningShape(Hand(concealedTiles: concealed, melds: melds))
                    }
                    config.coordinateSpace = .tableSpace
                    // Detections are pose-projected table points, so smooth each
                    // track's center to stop pond/hand boundary flicker (steadier
                    // counts) — see `TrackerConfig.positionSmoothing`.
                    config.positionSmoothing = 0.35
                    // Auto table-clear hand-end is off in AR: camera motion /
                    // relocalization / TrackID churn mimic a "swept table". The
                    // user ends a hand manually (`requestHandEnd()`).
                    config.autoHandEndEnabled = false
                    // Legacy geometry exists only for explicit 2D event/count
                    // fallback. Healthy spatial ownership, ROI, and overlays
                    // use `WorldTableCalibration` directly.
                    let planeExtent = arCapture.lockedPlaneExtent ?? TrackerConfig.TableGeometry().extent
                    config.tableGeometry = self.calibratedTableGeometry
                    self.trackerConfig = config

                    let newTracker = TableTracker(config: config)
                    newTracker.waitImpactAnnotator = Self.waitImpactAnnotator
                    self.tracker = newTracker
                    self.advisorCache = AdvisorCache()
                    if !self.calibrationHasBeenFinalized {
                        self.startupStage = .loadingDetector
                    }
                    self.zoneLastSeenOnScreen = [:]
                    self.zoneEverHadTracks = []
                    self.zoneLastPromptedAt = [:]
                    self.rescanPrompt = nil
                    arCapture.enterTracking()
                    forceNextInference = true

                    let sessionStart = CACurrentMediaTime()
                    self.zoneTrackingStartedAt = sessionStart
                    let cameraPosition = SIMD3<Float>(
                        frame.cameraTransform.columns.3.x,
                        frame.cameraTransform.columns.3.y,
                        frame.cameraTransform.columns.3.z
                    )
                    if let calibration = self.worldTableCalibration {
                        self.worldCensusController = WorldCensusController(
                            calibration: calibration,
                            at: sessionStart
                        )
                    } else if let restored = arCapture.restoredTableCalibration {
                        self.worldTableCalibration = restored
                        self.calibratedTableGeometry = Self.legacyGeometry(
                            from: restored,
                            mySeatWind: self.seatWind
                        )
                        self.worldCensusController = WorldCensusController(
                            calibration: restored,
                            at: sessionStart
                        )
                    } else {
                        self.worldCensusController = WorldCensusController(
                            lockedPlaneTransform: lockedPlaneTransform,
                            lockedExtent: Float(planeExtent),
                            cameraPosition: cameraPosition,
                            at: sessionStart
                        )
                    }
                    if let calibration = self.worldCensusController?.calibration {
                        arCapture.updateTableCalibration(calibration)
                    } else if let origin = self.worldCensusController?.tableOrigin {
                        arCapture.updateTableOrigin(
                            transform: origin.tableToWorld,
                            extent: origin.extent
                        )
                    }
                    newTracker.beginSession(
                        mySeatWind: self.seatWind,
                        roundWind: self.roundWind,
                        at: sessionStart
                    )
                    lastInference = sessionStart - 10   // due immediately
                }

                guard let tracker = self.tracker else {
                    try? await Task.sleep(for: Self.pollInterval)
                    continue
                }

                // Lane B chunk H item 3: freeze everything while ARKit is
                // relocalizing — the camera pose is untrustworthy until
                // tracking recovers, so motion gating/projection/ingest
                // would all be working off bad data this tick.
                // `StartupStatusOverlay` shows its own "re-finding your
                // table…" copy by reading `arCapture.captureStage` directly
                // (independent of `startupStage`, which only governs the
                // once-through pre-`.ready` startup waterfall).
                if arCapture.captureStage == .relocalizing {
                    self.cameraMoving = false
                    self.spatialTrackingHealth = .relocalizing
                    await self.finishTick(loopStart: loopStart)
                    continue
                }

                let moving = motionGate.update(transform: frame.cameraTransform, at: frame.timestamp)
                let justSettled = (wasMoving && !moving) || forceNextInference
                wasMoving = moving
                self.cameraMoving = moving

                if justSettled {
                    // Pose changed while we weren't ingesting — brackets need
                    // re-projecting even though the tracker STATE didn't.
                    forceNextInference = true
                    self.updateARZoneBoxes(from: tracker.state)
                }
                if moving, Self.motionPausesInference {
                    await self.finishTick(loopStart: loopStart)
                    continue
                }

                // Local (hand/tile) motion — settle gate + breathing signal,
                // unchanged from the image-space loop. `sampleField` (not
                // `sample`) so the SAME grid diff also yields the per-cell
                // `changed` grid the ROI scheduler needs (chunk E) — calling
                // both would double-diff against `motion`'s single
                // `previousGrid` and desync them; see `MotionDetector`'s doc.
                let field = motion.sampleField(frame.pixelBuffer, at: now)
                let sample = field?.sample
                if sample == nil { self.diagnostics.nilMotionSampleCount += 1 }
                // Prefer ARKit's own light estimate (a real hardware
                // reading) over the pixel-luma proxy when one's available.
                if let lux = frame.lightLux {
                    self.darkTableDetector.update(lightLux: lux, at: now)
                    self.isDark = self.darkTableDetector.isDark
                } else if let luma = sample?.meanLuma {
                    self.darkTableDetector.update(meanLuma: luma, at: now)
                    self.isDark = self.darkTableDetector.isDark
                }
                let level = sample?.level ?? 0
                self.diagnostics.motionLevel = level
                self.updatePhase(active: level >= self.trackerConfig.motionActive)

                let thermalBucket = CadencePolicy.Thermal(
                    processInfoRawValue: ProcessInfo.processInfo.thermalState.rawValue)
                let wasThrottled = self.thermal == .throttled
                self.thermal = thermalBucket >= .serious ? .throttled : .nominal
                if self.thermal == .throttled, !wasThrottled {
                    Self.logger.notice("thermal throttled — cadence backing off (state: \(thermalBucket.rawValue, privacy: .public))")
                } else if wasThrottled, self.thermal == .nominal {
                    Self.logger.notice("thermal recovered — cadence back to nominal")
                }

                var decision = cadence.decide(motionLevel: level, thermal: thermalBucket,
                                              timeSinceLastInference: now - lastInference)
                // Moving→still edge: bypass cadence once to catch the
                // settled table promptly rather than waiting out idle/burst.
                if forceNextInference, decision == .skip { decision = .infer }
                forceNextInference = false
                if self.recountRequest != nil, decision == .skip { decision = .infer }

                switch decision {
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
                    guard let lockedPlaneTransform = arCapture.lockedPlaneTransform else { break }
                    let tableOrigin = self.worldCensusController?.tableOrigin
                    let planeTransform = tableOrigin?.tableToWorld ?? lockedPlaneTransform

                    // Pixel-space ↔ table-space projection for this tick —
                    // built once, shared by the ROI zone projection, the
                    // full-frame path, and the crop path's visible-region
                    // mapping (all need the SAME camera pose).
                    let projection = TableProjection(cameraTransform: frame.cameraTransform, intrinsics: frame.intrinsics,
                                                     imageResolution: SIMD2<Float>(Float(frame.imageResolution.width),
                                                                                   Float(frame.imageResolution.height)),
                                                     planeTransform: planeTransform)
                    let geometry = self.trackerConfig.tableGeometry
                        ?? TrackerConfig.TableGeometry()
                    let extent = geometry.extent
                    let calibration = self.worldCensusController?.calibration
                        ?? self.worldTableCalibration

                    // Lane B chunk H item 2: zone rects are needed for
                    // staleness tracking regardless of `useROIScheduler` —
                    // hoisted out of that flag's block (was chunk E-only).
                    let zones = calibration.map {
                        ROIScheduler.projectedZoneRects(
                            calibration: $0,
                            projection: projection,
                            imageTransform: frame.imageTransform
                        )
                    } ?? ROIScheduler.ZoneRects()
                    let zoneCenters = calibration.map {
                        ROIScheduler.zoneCenters(calibration: $0)
                    } ?? [:]
                    self.updateZoneStaleness(tracker: tracker, zones: zones, centers: zoneCenters,
                                             projection: projection,
                                             imageTransform: frame.imageTransform,
                                             now: now)

                    // Lane B chunk E: ask the ROI scheduler what to infer.
                    // `useROIScheduler == false` always forces the original
                    // full-frame behavior (an A/B escape hatch).
                    //
                    let plan: ROIScheduler.InferencePlan
                    if let request = self.recountRequest {
                        let requestedZone: TableZoneID?
                        switch request {
                        case .fullTable: requestedZone = nil
                        case .zone(let zone): requestedZone = zone
                        }
                        if requestedZone == nil {
                            plan = .fullFrame
                        } else if let requestedZone,
                                  let rect = zones.identified.first(where: { $0.id == requestedZone })?.rect {
                            let cropRect = ROICropMapper.cropRect(forZoneImageRect: rect, orientedImageSize: frame.orientedImageSize,
                                                                  imageResolution: frame.imageResolution,
                                                                  imageOrientation: frame.imageOrientation)
                            plan = cropRect.width >= 2 && cropRect.height >= 2 ? .crops([cropRect]) : .fullFrame
                        } else {
                            // Requested zone isn't on screen right now — fall
                            // back to full-frame rather than drop the tap.
                            plan = .fullFrame
                        }
                    } else if self.useROIScheduler {
                        let myTurn = tracker.state.currentTurn == .me || tracker.state.myHand.count % 3 == 2
                        plan = roiScheduler.decide(motionField: field, zones: zones, myTurn: myTurn,
                                                   justSettled: justSettled, orientedImageSize: frame.orientedImageSize,
                                                   imageResolution: frame.imageResolution,
                                                   imageOrientation: frame.imageOrientation,
                                                   at: now)
                    } else {
                        plan = .fullFrame
                    }
                    let roiLabel: String
                    switch plan {
                    case .fullFrame: roiLabel = "full"
                    case .crops: roiLabel = roiScheduler.lastPlanLabels.isEmpty ? "crop" : roiScheduler.lastPlanLabels.joined(separator: "+")
                    case .none: roiLabel = "none"
                    }
                    self.diagnostics.roiPlan = self.useROIScheduler ? "roi: \(roiLabel)" : "roi: off"

                    switch plan {
                    case .fullFrame:
                        // Consume a recount only once its recognizer plan is
                        // actually about to execute. Earlier guards (motion,
                        // relocalization, thermal suspension, or unavailable
                        // projection) therefore leave it pending.
                        self.recountRequest = nil
                        // Recognize the FULL captured frame — the periodic
                        // safety net, the moving→still edge, or ROI scheduling
                        // disabled. In AR this is TILED into an overlapping
                        // native-resolution 3×4 grid (`TiledTileRecognizer`) so
                        // the dense central pond + opponents' revealed melds —
                        // ~15px each when the whole 4:3 frame is letterboxed to
                        // 640 — clear the detector's gate instead of vanishing.
                        let fullTiles: [DetectedTile]
                        let fullRecognizerSucceeded: Bool
                        if Self.tilesFullFrameRefresh {
                            var tiledRecognizerFailed = false
                            self.diagnostics.inferencesRun += TiledTileRecognizer.gridCols * TiledTileRecognizer.gridRows
                            fullTiles = await TiledTileRecognizer.recognize(
                                buffer: frame.pixelBuffer, roi: nil, minConfidence: 0.30,
                                imageOrientation: frame.imageOrientation,
                                using: { f in
                                    do {
                                        return try await rec.recognize(f)
                                    } catch {
                                        tiledRecognizerFailed = true
                                        return .empty
                                    }
                                })
                            fullRecognizerSucceeded = !tiledRecognizerFailed
                            self.lastPipelineError = tiledRecognizerFailed
                                ? "one or more tiled recognizer calls failed"
                                : nil
                        } else {
                            self.diagnostics.inferencesRun += 1
                            let recognizerFrame = RecognizerFrame.buffer(
                                frame.pixelBuffer,
                                orientation: frame.imageOrientation
                            )
                            do {
                                fullTiles = try await rec.recognize(recognizerFrame).tiles
                                fullRecognizerSucceeded = true
                                self.lastPipelineError = nil
                            } catch {
                                fullRecognizerSucceeded = false
                                self.recognizerErrorCount += 1
                                self.lastPipelineError = String(describing: error)
                                Self.logger.error("recognize() threw (\(self.recognizerErrorCount, privacy: .public) total): \(String(describing: error), privacy: .public)")
                                fullTiles = []
                            }
                        }
                        self.isWarmingUp = false
                        if self.startupStage == .loadingDetector { self.startupStage = .lookingForTiles }
                        self.diagnostics.lastRawDetectionCount = fullTiles.count
                        self.diagnostics.lastTopDetections = fullTiles
                            .sorted { $0.confidence > $1.confidence }
                            .prefix(3)
                            .map { "\($0.tile.code)@\(String(format: "%.2f", $0.confidence))" }
                        if self.isEnded { break pollLoop }

                        // Pixel-space detections → table-space `DetectedTile`s
                        // (the seam that keeps `Recognition` ARKit-free — see
                        // `TableProjection`/`DetectionProjector`'s own docs).
                        let projected = DetectionProjector.projectToTableSpace(
                            fullTiles, projection: projection, imageTransform: frame.imageTransform,
                            tableExtent: extent, tileSize: SIMD2<Double>(0.024, 0.032))

                        self.worldCensusController?.ingest(
                            detections: fullTiles,
                            frame: frame,
                            projection: projection,
                            coverageRects: [
                                TileBoundingBox(x: 0, y: 0, width: 1, height: 1),
                            ],
                            recognizerSucceeded: fullRecognizerSucceeded,
                            trackingIsNormal: arCapture.captureStage == .tracking,
                            allowsQualifiedMisses: self.calibrationDraft == nil,
                            at: now
                        )
                        self.updateWorldCensusDiagnostics()
                        if let outcome = self.ingestEventEngine(
                            tracker: tracker,
                            legacyDetections: projected,
                            legacyVisibleRegion: nil,
                            motion: sample,
                            at: now
                        ) {
                            self.logAndSnapshot(
                                outcome,
                                frame: frame.pixelBuffer,
                                tracker: tracker
                            )
                        }

                    case let .crops(rects):
                        self.recountRequest = nil
                        // Cap 2 crops/tick (thermal/latency budget) even
                        // though `ROIScheduler` may return more candidates.
                        var mergedImageSpace: [DetectedTile] = []
                        var visibleRegionRect: TileBoundingBox?
                        var censusCoverageRects: [TileBoundingBox] = []
                        var cropRecognizerSucceeded = true
                        var attemptedCrop = false
                        for rect in rects.prefix(2) {
                            guard let cropBuffer = pixelBufferCropper.crop(frame.pixelBuffer, to: rect) else { continue }
                            attemptedCrop = true
                            self.diagnostics.inferencesRun += 1
                            // Crop the NATIVE (un-rotated) buffer, then
                            // orient it exactly like the full frame — Vision
                            // rotates+detects the crop on its own terms, so
                            // its boxes come back normalized to the CROP's
                            // own oriented size. `ROICropMapper.fullImageBox`
                            // is the exact inverse chain back to full-image
                            // oriented space (see that method's own doc).
                            let cropFrame = RecognizerFrame.buffer(
                                cropBuffer,
                                orientation: frame.imageOrientation
                            )
                            let cropResult: RecognitionResult
                            do {
                                cropResult = try await rec.recognize(cropFrame)
                                self.lastPipelineError = nil
                            } catch {
                                cropRecognizerSucceeded = false
                                self.recognizerErrorCount += 1
                                self.lastPipelineError = String(describing: error)
                                Self.logger.error("recognize() threw on ROI crop (\(self.recognizerErrorCount, privacy: .public) total): \(String(describing: error), privacy: .public)")
                                cropResult = .empty
                            }
                            if self.isEnded { break pollLoop }
                            let mapped = cropResult.tiles.map { tile in
                                DetectedTile(id: tile.id, tile: tile.tile, confidence: tile.confidence,
                                            box: ROICropMapper.fullImageBox(fromCropNormalized: tile.box, cropRect: rect,
                                                                             imageResolution: frame.imageResolution,
                                                                             orientedImageSize: frame.orientedImageSize,
                                                                             imageOrientation: frame.imageOrientation),
                                            inReticle: tile.inReticle)
                            }
                            mergedImageSpace.append(contentsOf: mapped)

                            // Table-space visible region: the crop's own
                            // native rect → oriented-normalized (the exact
                            // inverse of `ROICropMapper.cropRect`) → table
                            // space via `TableProjection.tablePoint`, unioned
                            // across every crop this tick.
                            let cropOriented = ROICropMapper.orientedNormalizedRect(
                                fromRawRect: rect,
                                rawSize: frame.imageResolution,
                                orientedSize: frame.orientedImageSize,
                                imageOrientation: frame.imageOrientation)
                            censusCoverageRects.append(cropOriented)
                            if let tableRect = Self.tableSpaceRect(ofOrientedRect: cropOriented, projection: projection,
                                                                   imageTransform: frame.imageTransform,
                                                                   tableExtent: extent) {
                                visibleRegionRect = visibleRegionRect.map { Self.union($0, tableRect) } ?? tableRect
                            }
                        }
                        self.isWarmingUp = false
                        if self.startupStage == .loadingDetector { self.startupStage = .lookingForTiles }

                        // Every crop failed outright (pixel crop AND
                        // table-projection) — nothing learned this tick;
                        // don't let an empty detection set masquerade as "the
                        // whole table is empty" (that would accrue full-view
                        // misses on every track from a plumbing glitch, not
                        // real evidence).
                        guard !(mergedImageSpace.isEmpty && visibleRegionRect == nil) else { break }

                        // Overlapping crops (padding) can see the same
                        // physical tile twice — de-dupe before projecting,
                        // or it would phantom-birth a ghost track.
                        let deduped = Self.deduplicatingOverlaps(mergedImageSpace)
                        self.diagnostics.lastRawDetectionCount = deduped.count
                        self.diagnostics.lastTopDetections = deduped
                            .sorted { $0.confidence > $1.confidence }
                            .prefix(3)
                            .map { "\($0.tile.code)@\(String(format: "%.2f", $0.confidence))" }
                        if self.isEnded { break pollLoop }

                        let projected = DetectionProjector.projectToTableSpace(
                            deduped, projection: projection, imageTransform: frame.imageTransform,
                            tableExtent: extent, tileSize: SIMD2<Double>(0.024, 0.032))
                        self.worldCensusController?.ingest(
                            detections: deduped,
                            frame: frame,
                            projection: projection,
                            coverageRects: censusCoverageRects,
                            recognizerSucceeded: attemptedCrop && cropRecognizerSucceeded,
                            trackingIsNormal: arCapture.captureStage == .tracking,
                            allowsQualifiedMisses: self.calibrationDraft == nil,
                            at: now
                        )
                        self.updateWorldCensusDiagnostics()
                        if let outcome = self.ingestEventEngine(
                            tracker: tracker,
                            legacyDetections: projected,
                            legacyVisibleRegion: visibleRegionRect,
                            motion: sample,
                            at: now
                        ) {
                            self.logAndSnapshot(
                                outcome,
                                frame: frame.pixelBuffer,
                                tracker: tracker
                            )
                        }

                    case .none:
                        break
                    }
                }

                await self.finishTick(loopStart: loopStart)
            }
        }
    }

    @MainActor
    private func ingestEventEngine(
        tracker: TableTracker,
        legacyDetections: [DetectedTile],
        legacyVisibleRegion: TileBoundingBox?,
        motion: MotionSample?,
        at time: TimeInterval
    ) -> IngestOutcome? {
        guard case .legacy2D = countSource else {
            guard let controller = worldCensusController,
                  controller.calibration != nil else {
                return nil
            }
            return tracker.ingestCensus(
                controller.census.snapshot(at: time),
                tableExtent: controller.tableOrigin.extent,
                at: time,
                motion: motion
            )
        }
        return tracker.ingest(
            legacyDetections,
            at: time,
            motion: motion,
            visibleRegion: legacyVisibleRegion
        )
    }

    /// Updates per-zone `zoneLastSeenOnScreen` from this tick's projected
    /// zone rects (≥60% inside the frame counts as "seen"), then decides
    /// whether a directional rescan-prompt chip should appear. The "seen"
    /// update itself runs regardless of `phase` — camera-pose visibility
    /// doesn't care whether tiles are mid-move — but the PROMPT decision is
    /// gated on `phase != .action` per the plan's throttle rules (never
    /// interrupt while tiles are visibly moving).
    ///
    /// Simplification worth flagging for device QA: "inferred tick" here
    /// means the cadence policy decided `.infer` (this method's one call
    /// site), not that this SPECIFIC zone was the one actually recognized
    /// this tick (relevant only when `useROIScheduler` crops to a subset of
    /// zones) — a zone counts as "seen" whenever it was geometrically
    /// ≥60% on screen during any inferred tick, regardless of which zone(s)
    /// `ROIScheduler` chose to crop. Good enough for a proactive UX nudge;
    /// not meant to be a precise audit trail.
    private func updateZoneStaleness(tracker: TableTracker, zones: ROIScheduler.ZoneRects,
                                     centers: [TableZoneID: SIMD2<Double>],
                                     projection: TableProjection,
                                     imageTransform: FrameImageTransform, now: TimeInterval) {
        for (id, rect) in zones.identified where ROIScheduler.fractionInsideFrame(rect) >= 0.6 {
            zoneLastSeenOnScreen[id] = now
        }

        guard phase != .action else { return }   // never prompt while tiles are moving

        // Auto-clear: the currently-prompted zone just came back into view.
        if let current = rescanPrompt, zoneLastSeenOnScreen[current.zone] == now {
            rescanPrompt = nil
        }
        guard rescanPrompt == nil else { return }   // at most one prompt visible

        let hasUnresolvedPressure = !tracker.state.unresolved.isEmpty
        for zone in TableZoneID.allCases {
            let staleSince = zoneLastSeenOnScreen[zone] ?? zoneTrackingStartedAt
            guard now - staleSince > 45 else { continue }
            guard zoneEverHadTracks.contains(zone) || hasUnresolvedPressure else { continue }
            let cooldownUntil = (zoneLastPromptedAt[zone] ?? -.infinity) + 90
            guard now >= cooldownUntil else { continue }
            guard let center = centers[zone],
                  let projected = projection.normalizedOrientedPoint(
                    ofTablePoint: center,
                    imageTransform: imageTransform
                  ),
                  let direction = Self.rescanDirection(for: projected)
            else { continue }
            zoneLastPromptedAt[zone] = now
            rescanPrompt = RescanPrompt(zone: zone,
                                        text: "Pan \(direction.verb) to check \(zone.displayName) \(direction.arrow)")
            break
        }
    }

    /// Which way a zone's projected table-space center fell outside the
    /// visible `[0,1]` frame — `updateZoneStaleness`'s pure classification;
    /// `LiveFeedPane` never sees this directly, only the assembled
    /// `RescanPrompt.text`. Picks whichever axis overflowed more.
    private enum RescanDirection {
        case left, right, up, down
        var verb: String {
            switch self {
            case .left: return "left"
            case .right: return "right"
            case .up: return "up"
            case .down: return "down"
            }
        }
        var arrow: String {
            switch self {
            case .left: return "←"
            case .right: return "→"
            case .up: return "↑"
            case .down: return "↓"
            }
        }
    }

    private static func rescanDirection(for projected: SIMD2<Double>) -> RescanDirection? {
        let overflowX = projected.x < 0 ? -projected.x : max(0, projected.x - 1)
        let overflowY = projected.y < 0 ? -projected.y : max(0, projected.y - 1)
        guard overflowX > 0 || overflowY > 0 else { return nil }   // on screen — no direction to give
        if overflowX >= overflowY {
            return projected.x < 0 ? .left : .right
        } else {
            return projected.y < 0 ? .up : .down
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
        let state = presentationState(preserving: tracker.state)
        guard state.revision != lastPublishedRevision, now - lastPublishTime >= Self.publishInterval else { return }
        applyState(state, pending: tracker.pendingHandEnd, log: tracker.events)
        await refreshAdvice(for: state)
        persistIfDue(now: now)
    }

    /// Throttled disk persistence (plan A6) — real path only (`tracker` is
    /// nil on the mock path, so this is a no-op there; MJ_SCREEN scenes never
    /// touch disk). At most once per `persistInterval` unless `force`
    /// (`pauseLoop()` forces it — backgrounding is exactly when a kill is
    /// most likely, so that save can't be starved by the throttle).
    /// Snapshotting itself is synchronous and cheap (the same cost as a
    /// correction's `assembleState`); only the JSON write happens off-main,
    /// via the store actor. `savedAt` is stamped here, app-side — the
    /// tracker itself is forbidden from touching a wall clock.
    private func persistIfDue(now: TimeInterval, force: Bool = false) {
        guard arCapture == nil else { return }
        guard let tracker else { return }
        guard force || now - lastPersistTime >= Self.persistInterval else { return }
        lastPersistTime = now
        let coordinateSpace: PersistedCoachLiveSession.CoordinateSpaceMarker =
            trackerConfig.coordinateSpace == .tableSpace ? .tableSpace : .imageSpace
        let persisted = PersistedCoachLiveSession(snapshot: tracker.snapshot(at: now), savedAt: Date(),
                                                  coordinateSpace: coordinateSpace)
        Task { await CoachLiveSessionStore.shared.save(persisted) }
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
            let handledByCensus = MainActor.assumeIsolated { () -> Bool in
                guard worldCensusIsActive, let controller = worldCensusController else {
                    return false
                }
                let target: SemanticZoneID
                switch zone {
                case .mine: target = .mineHand
                case .table: target = .tablePond
                }
                controller.overrideZone(target, trackID: trackID)
                return true
            }
            if handledByCensus {
                publishAfterCorrection()
                return
            }
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

    /// Bracket-reassign correction (plan A3): the whole cluster wrapped by
    /// one zone bracket actually belongs to the other. `zone` is which chip
    /// was tapped — `.table` (the POND chip) offers "these are my hand" and
    /// moves every currently-pond track to `.myHand`; `.mine` (the MINE chip)
    /// offers "these are the pond" and moves every currently-hand(+bonus)
    /// track to `.pond`. (The observed failure this fixes is the POND
    /// bracket wrapping the user's own rank — not the reverse — but both
    /// directions are offered since either can go wrong.)
    ///
    /// Real path: snapshot the CURRENT opposite-zone track ids straight off
    /// `tracker.state` (not any cached UI list), one bulk `overrideZone`
    /// call, one republish. Mock path: mirrors the same move locally (pond
    /// entries → synthesized-TrackID hand tiles, or hand tiles → pond
    /// entries — there's no separate mock `myBonus` list, so only
    /// `handTiles`/`drawnTile` participate on that side) and recomputes
    /// advice — same dual-path convention as `assignUnresolved`.
    func reassignZoneBracket(_ zone: ZoneKind) {
        if let tracker {
            let handledByCensus = MainActor.assumeIsolated { () -> Bool in
                guard worldCensusIsActive, let controller = worldCensusController else {
                    return false
                }
                let source: Set<SemanticZoneID>
                let target: SemanticZoneID
                switch zone {
                case .table:
                    source = [.tablePond]
                    target = .mineHand
                case .mine:
                    source = [.mineHand, .mineMeld]
                    target = .tablePond
                }
                for track in controller.snapshot.tracks
                    where source.contains(track.semanticZone) {
                    controller.overrideZone(
                        target,
                        trackID: TrackID(raw: track.id.value)
                    )
                }
                return true
            }
            if handledByCensus {
                publishAfterCorrection()
                return
            }
            let ids: [TrackID]
            let target: TileZone
            switch zone {
            case .table:   // POND chip tapped → "these are my hand"
                ids = tracker.state.pond.map(\.id)
                target = .myHand
            case .mine:    // MINE chip tapped → "these are the pond"
                ids = (tracker.state.myHand + tracker.state.myBonus).map(\.id)
                target = .pond
            }
            tracker.overrideZone(tracks: ids, to: target)
            publishAfterCorrection()
            return
        }
        switch zone {
        case .table:
            let moved = pond
            pond = []
            for entry in moved {
                let box = TileBoundingBox(x: 0.5, y: 0.84, width: 0.06, height: 0.1)
                handTiles.append(TrackedTile(id: nextTrackID(), face: entry.tile, box: box,
                                             zone: .myHand, state: .live, firstSeen: 0, lastSeen: 0))
                if seenHistogram.indices.contains(entry.tile.classIndex) {
                    seenHistogram[entry.tile.classIndex] = max(0, seenHistogram[entry.tile.classIndex] - 1)
                }
            }
            seenTotal = seenHistogram.reduce(0, +)
        case .mine:
            let moved = handTiles + (drawnTile.map { [$0] } ?? [])
            handTiles = []
            drawnTile = nil
            for track in moved {
                pond.append(PondEntry(tile: track.face))
                seenHistogram[track.face.classIndex] += 1
            }
            seenTotal = seenHistogram.reduce(0, +)
        }
        recomputeAdvice()
    }

    func dismissUnresolved(_ id: UUID) {
        if let tracker, let trackID = unresolvedTrackByUUID[id] {
            let handledByCensus = MainActor.assumeIsolated { () -> Bool in
                guard worldCensusIsActive, let controller = worldCensusController else {
                    return false
                }
                controller.remove(trackID: trackID)
                return true
            }
            if handledByCensus {
                publishAfterCorrection()
                return
            }
            tracker.removeTrack(trackID)
            publishAfterCorrection()
            return
        }
        unresolved.removeAll { $0.id == id }
    }

    func overrideHandTile(_ id: TrackID, as tile: Tile) {
        if let tracker {
            let handledByCensus = MainActor.assumeIsolated { () -> Bool in
                guard worldCensusIsActive, let controller = worldCensusController else {
                    return false
                }
                controller.pinFace(tile, trackID: id)
                return true
            }
            if handledByCensus {
                publishAfterCorrection()
                return
            }
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
        let handledByCensus = MainActor.assumeIsolated { () -> Bool in
            guard worldCensusIsActive, let controller = worldCensusController else {
                return false
            }
            controller.setSeenCount(
                classIndex: classIndex,
                desiredCount: count,
                at: CACurrentMediaTime()
            )
            return true
        }
        if handledByCensus {
            publishAfterCorrection()
            return
        }
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
                let handledByCensus = MainActor.assumeIsolated { () -> Bool in
                    guard worldCensusIsActive,
                          let controller = worldCensusController else {
                        return false
                    }
                    controller.pinFace(tile, trackID: trackID)
                    return true
                }
                if !handledByCensus {
                    tracker.pin(track: trackID, as: tile)
                }
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

    /// Manually proposes a hand end (the AR path's automatic table-clear
    /// detector is off — `config.autoHandEndEnabled == false`). Surfaces the
    /// existing `HandEndedCard` (pick winner / dismiss) via the facade's
    /// `requestHandEnd`. No-op on the mock path (no tracker).
    func requestHandEnd() {
        guard let tracker else { return }
        tracker.requestHandEnd()
        publishAfterCorrection()
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
            MainActor.assumeIsolated {
                worldCensusController?.resetTiles()
            }
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

    /// Ends the session: cancels the tracking loop and pauses the AR capture
    /// (if any — chunk G's `ScanCoordinator.endCoachLive()`/
    /// `beginScoreHandoff` then restart Scan's own camera). The fallback
    /// `camera` itself is owned by `ScanView` (the §5 hoist) and keeps
    /// running for the return to Scan on THAT path, so it's deliberately NOT
    /// stopped here; the idle timer is reset by
    /// `CoachLiveFlowView.onDisappear` + `ScanCoordinator.endCoachLive()`.
    /// Idempotent — safe to call from multiple teardown paths. A clean end
    /// (score handoff, exit) clears the persisted archive (plan A6) — only a
    /// KILL should ever leave one behind for `CoachLiveSetupView` to resume.
    func end() {
        isEnded = true
        loopTask?.cancel()
        loopTask = nil
        // `ARTableCapture` is `@MainActor`-isolated; `CoachLiveSession`
        // itself isn't (its intent methods are called directly from SwiftUI
        // action closures, which already run on the main actor at runtime
        // but aren't statically typed `@MainActor` all the way through) —
        // `assumeIsolated` bridges that gap without spreading `@MainActor`
        // through this whole class's call graph. Every call site of `end()`
        // is a SwiftUI teardown path (view `onDisappear`/coordinator
        // methods), so this is always true in practice.
        MainActor.assumeIsolated { arCapture?.pause() }
        if tracker != nil {
            Task { await CoachLiveSessionStore.shared.clear() }
        }
    }

    /// scenePhase → background: idle the loop and force a persist —
    /// backgrounding is exactly when the app is most likely to be killed
    /// next, so that save can't be starved by the throttle.
    func pauseLoop() {
        isPaused = true
        persistIfDue(now: CACurrentMediaTime(), force: true)
    }
    /// scenePhase → foreground: resume polling.
    func resumeLoop() { isPaused = false }

    /// scenePhase → background, whole-capture version (Lane B chunk G):
    /// pauses the loop AND whichever capture backend is actually live, so
    /// `CoachLiveFlowView` never needs to reach into capture internals (or
    /// know which backend this session is running) to do the right thing.
    func sceneDidBackground() {
        pauseLoop()
        MainActor.assumeIsolated { arCapture?.pause() }
        #if !targetEnvironment(simulator)
        // `isARCaptureActive` (not `arCapture == nil`): after the never-locks
        // fallback (`usingFallbackCapture`) `arCapture` is still non-nil but
        // the loop is actually driven by `camera`, so the camera — not the
        // (already-paused) AR session — is what must be stopped here.
        if !isARCaptureActive { camera.stop() }
        #endif
    }

    /// scenePhase → active, the mirror image of `sceneDidBackground()`. Never
    /// restarts `camera` while `arCapture` is live — doing so would fight
    /// ARKit for the capture device — and, symmetrically, never re-runs the AR
    /// session once we've degraded to the image-space `camera` fallback
    /// (`usingFallbackCapture`): resuming ARKit there would reclaim the capture
    /// device out from under the fallback camera loop.
    func sceneDidActivate() {
        resumeLoop()
        if isARCaptureActive {
            MainActor.assumeIsolated { arCapture?.resume() }
        }
        #if !targetEnvironment(simulator)
        if !isARCaptureActive { camera.requestAndStart() }
        #endif
    }

    /// True when the AR capture loop (not the mock/headless path, and not
    /// a session that's degraded to the image-space fallback) is actually
    /// driving this session — Lane B chunk H gates the "Rescan table" link
    /// (`CoachLiveView`'s state pane) on this, since `rescanTable()` only
    /// makes sense on this path.
    var isARCaptureActive: Bool { arCapture != nil && !usingFallbackCapture }

    /// Workstream G: true while ARKit has lost world tracking and is trying
    /// to relocalize (`ARCamera.trackingState == .limited(.relocalizing)`,
    /// surfaced as `CaptureStage.relocalizing`) — `LiveFeedPane`'s calm
    /// dim-and-nudge overlay keys off this. World-anchored geometry survives
    /// a relocalization (the locked plane transform doesn't change), so the
    /// overlay is purely reassurance, not a re-setup flow.
    ///
    /// Guarded by `!usingFallbackCapture`: once the loop degrades to the
    /// image-space fallback, `arCapture.pause()` freezes `captureStage`
    /// wherever it last was — including possibly `.relocalizing` — and
    /// nothing ever moves it off that again. Without this guard the overlay
    /// could get stuck on forever after a fallback that happened to trip
    /// mid-relocalization.
    @MainActor
    var isRelocalizing: Bool { arCapture?.captureStage == .relocalizing && !usingFallbackCapture }

    /// Workstream G: the 2D-fallback banner's "Retry AR setup" button
    /// (`LiveFeedPane`). `usingFallbackCapture` is documented as one-way —
    /// "a session doesn't re-attempt AR mid-flight" (see that property) —
    /// because once the loop falls back, the plain `camera` AVCaptureSession
    /// owns the capture device and `arCapture` is paused; re-establishing a
    /// live `ARSession` from here would need to tear `camera` down first and
    /// rebuild an `ARTableCapture`, which risks fighting the two capture
    /// backends for the device and isn't something this class currently does
    /// anywhere. `rescanTable()` is the closest REAL, already-wired
    /// affordance reachable from this view — it no-ops while
    /// `usingFallbackCapture` is true (via its own `isARCaptureActive`
    /// guard), which is an honest "there's nothing to rescan" rather than a
    /// silent lie about retrying AR.
    /// TODO: G — a genuine retry needs to stop `camera`, construct a fresh
    /// `ARTableCapture`, and re-run `startARLoop` (or have `ScanCoordinator`
    /// re-enter `CoachLiveFlowView` with a new session) — neither is safely
    /// reachable from `CoachLiveSession` alone today.
    func retryARSetup() {
        rescanTable()
    }

    /// Requests one full-table inference without changing capture state or
    /// presenting blocking UI. A no-op off the AR path.
    func rescanTable() {
        guard isARCaptureActive else { return }
        recountRequest = .fullTable
    }

    func beginPondRecenter() {
        guard isARCaptureActive, worldCensusController != nil else { return }
        isRecenterPondActive = true
    }

    @MainActor
    func applyPondRecenter(
        tapInFeed point: CGPoint,
        previewBounds: CGRect
    ) {
        guard isRecenterPondActive,
              let arCapture,
              let controller = worldCensusController,
              let frame = arCapture.latestFrame else { return }
        let normalized = AspectFillMapping.normalizedImageRect(
            of: CGRect(origin: point, size: .zero),
            previewBounds: previewBounds,
            orientedImageSize: frame.orientedImageSize
        )
        let rawNormalized = frame.imageTransform.rawNormalized(
            fromOriented: SIMD2(
                Double(normalized.x),
                Double(normalized.y)
            )
        )
        guard let world = arCapture.raycastWorldPoint(
            atNormalizedImagePoint: CGPoint(
                x: rawNormalized.x,
                y: rawNormalized.y
            )
        ) else { return }
        controller.recenterPond(at: world)
        worldTableCalibration = controller.calibration
        arCapture.invalidatePersistedCalibration()
        if let calibration = controller.calibration {
            arCapture.updateTableCalibration(calibration)
        }
        isRecenterPondActive = false
        let state = presentationState(preserving: tracker?.state ?? .empty)
        applyState(state, pending: tracker?.pendingHandEnd, log: tracker?.events ?? [])
    }

    /// The force-recount FAB. A nil zone requests one tiled full-frame pass;
    /// a non-nil zone requests one crop, falling back to full-frame when the
    /// requested zone is offscreen. Both are AR-path-only;
    /// off that path this degrades to a harmless advice recompute — there is
    /// no "zone" concept on the image-space fallback or mock loops, and no
    /// per-tick force-inference hook on `startLoop` to redirect either.
    /// TODO: F — a real per-zone (or even per-tick force) hook for the
    /// non-AR `startLoop` path is out of scope here; wire one if the
    /// image-space fallback ever needs this FAB to do more than no-op.
    func requestRecount(zone: TableZoneID? = nil) {
        if isARCaptureActive {
            recountRequest = zone.map(RecountRequest.zone) ?? .fullTable
        }
        if tracker != nil {
            publishAfterCorrection()
        } else {
            recomputeAdvice()
        }
    }

    /// Dismisses the current rescan-prompt chip's "×". The zone's normal
    /// 90s re-prompt cooldown already started when the prompt was first
    /// shown (see `updateZoneStaleness`), so dismissal doesn't need to
    /// touch it — this is "not right now," not "never again."
    func dismissRescanPrompt() { rescanPrompt = nil }

    /// Torch control that works whichever capture backend is live: AR mode
    /// routes through `ARTableCapture.setTorch` (community-proven alongside
    /// ARKit — see that method's own doc for the verify-on-device caveat),
    /// the fallback path through `CameraCapture.setTorch`.
    func setTorch(_ on: Bool) {
        if let arCapture {
            MainActor.assumeIsolated { arCapture.setTorch(on) }
        } else {
            camera.setTorch(on)
        }
    }

    // MARK: - Publish (real path: TrackedTableState → UI surface)

    /// Immediately reflects a correction on the UI surface (bypassing the 300 ms
    /// coalescing so edits feel instant), then refreshes advice off-main.
    private func publishAfterCorrection() {
        guard let tracker else { return }
        let state = MainActor.assumeIsolated {
            presentationState(preserving: tracker.state)
        }
        applyState(state, pending: tracker.pendingHandEnd, log: tracker.events)
        Task { @MainActor [weak self] in await self?.refreshAdvice(for: state) }
    }

    @MainActor
    private var worldCensusIsActive: Bool {
        countSource == .worldCensus
    }

    @MainActor
    private func presentationState(
        preserving legacy: TrackedTableState
    ) -> TrackedTableState {
        switch countSource {
        case .legacy2D:
            return legacy
        case .spatialBootstrapping:
            return CensusStateAdapter.makeBootstrapState(preserving: legacy)
        case .worldCensus:
            break
        }
        guard let controller = worldCensusController else { return .empty }
        return CensusStateAdapter.makeState(
            snapshot: controller.snapshot,
            preserving: legacy,
            tableExtent: controller.tableOrigin.extent,
            censusRevision: controller.revision
        )
    }

    @MainActor
    private func updateWorldCensusDiagnostics() {
        guard let controller = worldCensusController else { return }
        let snapshot = controller.snapshot
        diagnostics.worldCensusTracks = snapshot.tracks.count
        diagnostics.worldCensusTentative = snapshot.tracks.filter {
            $0.lifecycle == .tentative
        }.count
        diagnostics.worldCensusConfirmed = snapshot.tracks.filter {
            $0.lifecycle == .confirmed
        }.count
        diagnostics.worldCensusStale = snapshot.tracks.filter {
            $0.lifecycle == .stale
        }.count
        diagnostics.worldCensusMissing = snapshot.tracks.filter {
            $0.lifecycle == .temporarilyMissing
        }.count
        if calibrationHasBeenFinalized,
           calibrationDraft == nil,
           countSource == .spatialBootstrapping,
           controller.calibration != nil,
           spatialTrackingHealth != .depthUnavailable,
           spatialTrackingHealth != .relocalizing {
            countSource = .worldCensus
            spatialTrackingHealth = .healthy
            Self.logger.notice(
                "spatial source=CENSUS health=healthy calibration=\(controller.calibration?.source.rawValue ?? "none", privacy: .public)"
            )
        }
        diagnostics.worldCensus = controller.census.diagnostics
        diagnostics.worldCensusDepthRejections = controller.diagnostics.depthRejections
        diagnostics.worldCensusDepthAcceptance =
            controller.diagnostics.depthAcceptanceRate
        diagnostics.worldCensusAnchorErrorPixels =
            controller.diagnostics.anchorReprojectionErrorPixels
        diagnostics.worldCensusCalibrationSource =
            controller.calibration?.source.rawValue ?? "unmarked"
        diagnostics.worldCensusMilliseconds = controller.diagnostics.lastIngestMilliseconds
        refreshSpatialContinuityDiagnostics()
        if let calibration = controller.calibration {
            arCapture?.updateTableCalibration(
                calibration,
                persist: calibrationDraft == nil
            )
        } else {
            arCapture?.updateTableOrigin(
                transform: controller.tableOrigin.tableToWorld,
                extent: controller.tableOrigin.extent
            )
        }
        let liveTracks = snapshot.tracks.filter {
            $0.lifecycle == .confirmed
                || $0.lifecycle == .stale
                || $0.lifecycle == .temporarilyMissing
        }
        let opponentCount = liveTracks.count {
            $0.semanticZone == .tableRevealedLeft
                || $0.semanticZone == .tableRevealedFar
                || $0.semanticZone == .tableRevealedRight
        }
        diagnostics.worldCensusZoneSummary = [
            "hand \(liveTracks.count { $0.semanticZone == .mineHand })",
            "meld \(liveTracks.count { $0.semanticZone == .mineMeld })",
            "pond \(liveTracks.count { $0.semanticZone == .tablePond })",
            "opp \(opponentCount)",
            "unres \(liveTracks.count { $0.semanticZone == .boundaryUnresolved })"
        ].joined(separator: " · ")
        diagnostics.worldCensusDepthSummary = controller.diagnostics.depthRejections
            .sorted { String(describing: $0.key) < String(describing: $1.key) }
            .map { "\(String(describing: $0.key))=\($0.value)" }
            .joined(separator: ", ")
        if diagnostics.worldCensusDepthSummary.isEmpty {
            diagnostics.worldCensusDepthSummary = "—"
        }
        Self.logger.debug(
            "census source=\(self.countSource.diagnosticName, privacy: .public) health=\(self.spatialTrackingHealth.diagnosticName, privacy: .public) tracks=\(snapshot.tracks.count, privacy: .public) tentative=\(self.diagnostics.worldCensusTentative, privacy: .public) confirmed=\(self.diagnostics.worldCensusConfirmed, privacy: .public) stale=\(self.diagnostics.worldCensusStale, privacy: .public) missing=\(self.diagnostics.worldCensusMissing, privacy: .public) depthAcceptance=\(self.diagnostics.worldCensusDepthAcceptance, privacy: .public) reprojectionPx=\(self.diagnostics.worldCensusAnchorErrorPixels, privacy: .public) ms=\(self.diagnostics.worldCensusMilliseconds, privacy: .public) arSession=\(self.diagnostics.spatialSessionID, privacy: .public) pipeline=\(self.diagnostics.spatialPipelineGeneration, privacy: .public) calibration=\(self.diagnostics.calibrationRevision, privacy: .public) resets=\(self.diagnostics.resetTrackingRunCount, privacy: .public)"
        )
    }

    /// Mirrors ARKit configuration facts into the existing HUD/Console
    /// diagnostics. It deliberately observes rather than drives the capture
    /// owner, so adding this audit seam cannot reset or reconfigure ARKit.
    @MainActor
    private func refreshSpatialContinuityDiagnostics(
        capture: ARTableCapture? = nil
    ) {
        guard let capture = capture ?? arCapture else { return }
        let ar = capture.sessionDiagnostics
        diagnostics.spatialSessionID = String(ar.sessionID.uuidString.prefix(8))
        diagnostics.spatialPipelineGeneration = spatialPipelineGeneration
        diagnostics.calibrationRevision = calibrationRevision
        diagnostics.configurationRunCount = ar.configurationRunCount
        diagnostics.resetTrackingRunCount = ar.resetTrackingRunCount
        diagnostics.removeExistingAnchorsRunCount = ar.removeExistingAnchorsRunCount
        diagnostics.lastConfigurationUsedReset = ar.lastRunUsedResetTracking
            || ar.lastRunUsedRemoveExistingAnchors
        diagnostics.lastConfigurationReason = ar.lastReason?.rawValue ?? "—"
    }

    private func resetSpatialTrackingState() {
        depthMissingSince = nil
        depthRestartAttempted = false
        if arCapture == nil {
            countSource = .legacy2D(.arUnavailable)
            spatialTrackingHealth = .trackingLimited
        } else if ARTableCapture.supportsSceneDepth {
            countSource = .spatialBootstrapping
            spatialTrackingHealth = .calibrating
        } else {
            countSource = .legacy2D(.depthUnsupported)
            spatialTrackingHealth = .depthUnavailable
        }
    }

    @MainActor
    private func updateDepthHealth(
        frame: ARTableFrame,
        capture: ARTableCapture,
        at time: TimeInterval
    ) {
        guard ARTableCapture.supportsSceneDepth else {
            enterLegacyFallback(.depthUnsupported, at: time)
            spatialTrackingHealth = .depthUnavailable
            return
        }
        guard frame.depthMap != nil, frame.depthConfidence != nil else {
            let missingSince = depthMissingSince ?? time
            depthMissingSince = missingSince
            spatialTrackingHealth = .depthUnavailable
            let elapsed = time - missingSince
            if elapsed >= 2, !depthRestartAttempted {
                depthRestartAttempted = true
                capture.retryDepthSemantics()
            } else if elapsed >= 4, depthRestartAttempted {
                enterLegacyFallback(.depthUnavailable, at: time)
            }
            return
        }

        depthMissingSince = nil
        if countSource != .legacy2D(.depthUnavailable) {
            spatialTrackingHealth = countSource == .worldCensus
                ? .healthy
                : .calibrating
        }
    }

    @MainActor
    private func enterLegacyFallback(
        _ reason: LegacyFallbackReason,
        at time: TimeInterval
    ) {
        let target = CoachLiveCountSource.legacy2D(reason)
        guard countSource != target else { return }
        countSource = target

        // A tracker previously synchronized from census must never become the
        // legacy count source. Start a clean 2D read model instead of mixing
        // physical identities with image-space association.
        guard tracker != nil else { return }
        let replacement = TableTracker(config: trackerConfig)
        replacement.waitImpactAnnotator = Self.waitImpactAnnotator
        replacement.beginSession(
            mySeatWind: seatWind,
            roundWind: roundWind,
            at: time
        )
        tracker = replacement
        advisorCache = AdvisorCache()
        applyState(
            replacement.state,
            pending: replacement.pendingHandEnd,
            log: replacement.events
        )
        recountRequest = .fullTable
        Self.logger.notice(
            "spatial source=LEGACY_2D reason=\(reason.rawValue, privacy: .public); census tracks discarded from event read model"
        )
    }

    @MainActor
    func retrySpatialTracking() {
        guard let arCapture, ARTableCapture.supportsSceneDepth else { return }
        depthMissingSince = nil
        depthRestartAttempted = false
        countSource = .spatialBootstrapping
        spatialTrackingHealth = .calibrating
        arCapture.retryDepthSemantics()
        recountRequest = .fullTable
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
        // Table-space (AR) mode re-projects those union rects through the
        // CURRENT camera pose first (Lane B chunk D/F — see
        // `updateARZoneBoxes`), so brackets stay glued to the table through
        // camera movement; image-space mode (the harness/fallback default)
        // is byte-for-byte unchanged — `DetectedTile.box` already lives in
        // the exact oriented-image space `ZoneBracketsOverlay` expects.
        if trackerConfig.coordinateSpace == .tableSpace {
            updateARZoneBoxes(from: state)
            // Lane B chunk H item 2: "ever had tracks" per `TableZoneID` —
            // the edge↔seat mapping is `ZoneModel`'s own fixed table-space
            // convention (left edge → `.left`, far/low-y edge → `.across`,
            // right edge → `.right`; see that type's doc).
            if !state.myHand.isEmpty || !state.myBonus.isEmpty || state.myMelds.contains(where: { !$0.isEmpty }) {
                zoneEverHadTracks.insert(.hand)
            }
            if !state.pond.isEmpty { zoneEverHadTracks.insert(.pond) }
            if !(state.opponentMelds[.left]?.isEmpty ?? true) { zoneEverHadTracks.insert(.meldLeft) }
            if !(state.opponentMelds[.right]?.isEmpty ?? true) { zoneEverHadTracks.insert(.meldRight) }
            if !(state.opponentMelds[.across]?.isEmpty ?? true) { zoneEverHadTracks.insert(.meldFar) }
        } else {
            zoneBoxes = ZoneBoxes(
                mine: (state.myHand + state.myBonus + state.myMelds.flatMap { $0 }).map(\.box),
                table: state.pond.map(\.box) + state.opponentMelds.values.flatMap { $0.flatMap { $0 } }.map(\.box),
                unresolved: state.unresolved.map(\.box))
        }

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

    /// AR-only (Lane B chunk D/F): re-projects each zone's TABLE-space union
    /// rect into normalized oriented-image space off the CURRENT camera pose
    /// (`arCapture.latestFrame`/`.lockedPlaneTransform` — NOT the pose the
    /// detections that produced `state` were captured against, which may be
    /// stale by the time this publishes) so `ZoneBracketsOverlay` — which
    /// only ever understands oriented-image-space boxes — keeps working
    /// completely unchanged. Leaves `zoneBoxes` as-is (rather than clearing
    /// it) when there's no current pose to project against yet, so brackets
    /// don't flash away for a single tick. Also the entry point for the
    /// camera moving→still edge's forced refresh (`startARLoop`) — that call
    /// re-projects the LAST published state's boxes without waiting for a
    /// new tracker revision, since the pose (not the state) is what changed.
    ///
    /// Plain (nonisolated) method, like `applyState` itself — the
    /// `arCapture`-touching body is wrapped in `MainActor.assumeIsolated`
    /// (see `end()`'s doc for why) rather than marking this `@MainActor`,
    /// which would force `applyState` (and everything that calls it) to
    /// become `@MainActor`/`async` too.
    private func updateARZoneBoxes(from _: TrackedTableState) {
        MainActor.assumeIsolated {
            guard countSource == .worldCensus,
                  spatialTrackingHealth == .healthy,
                  let arCapture,
                  let frame = arCapture.latestFrame,
                  let controller = worldCensusController,
                  let calibration = controller.calibration else {
                zoneBoxes = ZoneBoxes()
                return
            }
            let projection = TableProjection(cameraTransform: frame.cameraTransform, intrinsics: frame.intrinsics,
                                             imageResolution: SIMD2<Float>(Float(frame.imageResolution.width),
                                                                           Float(frame.imageResolution.height)),
                                             planeTransform: calibration.tableToWorld)

            var minePolygons = [calibration.handPolygon]
            if let mineMeld = calibration.revealedZonePolygons[.mineMeld] {
                minePolygons.append(mineMeld)
            }
            let unresolved = controller.snapshot.tracks.filter {
                $0.lifecycle != .tentative
                    && $0.lifecycle != .retired
                    && $0.semanticZone == .boundaryUnresolved
            }.compactMap {
                Self.projectedLocalRect(
                    center: $0.tablePoint,
                    size: SIMD2(0.024, 0.032),
                    projection: projection,
                    imageTransform: frame.imageTransform
                )
            }
            zoneBoxes = ZoneBoxes(
                mine: minePolygons.compactMap {
                    Self.projectedLocalPolygon(
                        $0,
                        projection: projection,
                        imageTransform: frame.imageTransform
                    )
                },
                table: Self.projectedLocalPolygon(
                    calibration.pondPolygon,
                    projection: projection,
                    imageTransform: frame.imageTransform
                ).map { [$0] } ?? [],
                unresolved: unresolved
            )
        }
    }

    private static func projectedLocalPolygon(
        _ localPolygon: [SIMD2<Float>],
        projection: TableProjection,
        imageTransform: FrameImageTransform
    ) -> TileBoundingBox? {
        let projected = localPolygon.compactMap {
            projection.normalizedOrientedPoint(
                ofTablePoint: SIMD2(Double($0.x), Double($0.y)),
                imageTransform: imageTransform
            )
        }
        guard !projected.isEmpty else { return nil }
        let xs = projected.map(\.x)
        let ys = projected.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }
        return TileBoundingBox(
            x: minX, y: minY,
            width: maxX - minX, height: maxY - minY
        )
    }

    private static func projectedLocalRect(
        center: SIMD2<Float>,
        size: SIMD2<Float>,
        projection: TableProjection,
        imageTransform: FrameImageTransform
    ) -> TileBoundingBox? {
        let half = size * 0.5
        return projectedLocalPolygon(
            [
                center - half,
                SIMD2(center.x + half.x, center.y - half.y),
                center + half,
                SIMD2(center.x - half.x, center.y + half.y),
            ],
            projection: projection,
            imageTransform: imageTransform
        )
    }

    /// Lane B chunk E: the table-space (normalized [0,1], plane anchor at
    /// (0.5, 0.5)) bounding box of an oriented-normalized image rect.
    /// `TableProjection.tablePoint` projects each corner onto the locked
    /// plane (anchor-local metres),
    /// then the same `/extent + 0.5` normalization
    /// `DetectionProjector.projectToTableSpace` uses turns that into
    /// table-space units. A corner behind the camera or parallel to the
    /// plane is dropped (`tablePoint` returns nil for it); `nil` only when
    /// every corner fails (the crop wasn't actually looking at the table
    /// this frame) — the caller then just skips visibility-gating that
    /// crop's tracks for this tick, same as a full-view ingest.
    private static func tableSpaceRect(ofOrientedRect rect: TileBoundingBox, projection: TableProjection,
                                       imageTransform: FrameImageTransform,
                                       tableExtent: Double) -> TileBoundingBox? {
        let corners = [SIMD2<Double>(rect.x, rect.y), SIMD2<Double>(rect.x + rect.width, rect.y),
                       SIMD2<Double>(rect.x + rect.width, rect.y + rect.height), SIMD2<Double>(rect.x, rect.y + rect.height)]
        return tableSpaceBoundingBox(ofPoints: corners, projection: projection, imageTransform: imageTransform,
                                     tableExtent: tableExtent, minimumProjected: 1)
    }

    /// Projects `points` (oriented-normalized image space) through
    /// `projection.tablePoint`, then normalizes into table-space units the
    /// same way `DetectionProjector.projectToTableSpace` does.
    private static func tableSpaceBoundingBox(ofPoints points: [SIMD2<Double>], projection: TableProjection,
                                              imageTransform: FrameImageTransform, tableExtent: Double,
                                              minimumProjected: Int) -> TileBoundingBox? {
        guard tableExtent > 0 else { return nil }
        let table = points.compactMap {
            projection.tablePoint(
                ofNormalizedOrientedPoint: $0,
                imageTransform: imageTransform
            )
        }
        guard table.count >= minimumProjected else { return nil }
        let xs = table.map { $0.x / tableExtent + 0.5 }
        let ys = table.map { $0.y / tableExtent + 0.5 }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return TileBoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Union of two normalized boxes — folds each crop's table-space
    /// coverage into one `visibleRegion` for `tracker.ingest` (chunk E).
    private static func union(_ a: TileBoundingBox, _ b: TileBoundingBox) -> TileBoundingBox {
        let minX = min(a.x, b.x), minY = min(a.y, b.y)
        let maxX = max(a.x + a.width, b.x + b.width), maxY = max(a.y + a.height, b.y + b.height)
        return TileBoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// De-duplicates detections that came from overlapping ROI crops
    /// (padding means adjacent zone crops can share a strip of pixels, so
    /// the same physical tile can be detected once per crop it falls
    /// inside) — greedy class-agnostic NMS, the same idea as
    /// `VisionRecognizer.suppressingOverlaps`'s own within-frame dedup (that
    /// method is `Recognition`-internal, so this is a small App-side
    /// reimplementation, not a duplicate of a public API). The full-frame
    /// plan never needs this — one recognize call can't self-overlap.
    private static func deduplicatingOverlaps(_ tiles: [DetectedTile], iouThreshold: Double = 0.55) -> [DetectedTile] {
        let ranked = tiles.sorted { $0.confidence > $1.confidence }
        var kept: [DetectedTile] = []
        for tile in ranked where kept.allSatisfy({ Self.boxIoU($0.box, tile.box) <= iouThreshold }) {
            kept.append(tile)
        }
        return kept
    }

    private static func boxIoU(_ a: TileBoundingBox, _ b: TileBoundingBox) -> Double {
        let interW = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let interH = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let intersection = interW * interH
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Shared post-`ingest` bookkeeping (chunk E) — both the full-frame and
    /// crop-merged AR ingest paths need the identical event-log/snapshot
    /// handling `startARLoop` used to inline once, before ROI branching
    /// split it in two.
    private func logAndSnapshot(_ outcome: IngestOutcome, frame buffer: CVPixelBuffer, tracker: TableTracker) {
        if !outcome.newEvents.isEmpty {
            Self.logger.debug("tracker committed \(outcome.newEvents.count, privacy: .public) event(s); live=\(tracker.diagnostics.live, privacy: .public) tentative=\(tracker.diagnostics.tentative, privacy: .public) missing=\(tracker.diagnostics.missing, privacy: .public)")
        }
        if outcome.newEvents.contains(where: {
            if case .myHandComplete = $0.kind { return true }; return false
        }) {
            // Snapshot the exact winning-hand frame for the score handoff.
            lastFrameSnapshot = ScanView.photo(from: buffer)
        }
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

/// My hand went complete — surfaced as `HandEndedCard` (win mode).
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
    /// Lane B chunk E: the AR loop's most recent `ROIScheduler` decision,
    /// formatted for the debug HUD — `"roi: full"` / `"roi: hand+pond"` /
    /// `"roi: none"` / `"roi: off"` (`useROIScheduler == false`). Never set
    /// on `startLoop`'s image-space path or the mock path (no scheduler
    /// runs there).
    var roiPlan = "—"
    var worldCensusTracks = 0
    var worldCensusTentative = 0
    var worldCensusConfirmed = 0
    var worldCensusStale = 0
    var worldCensusMissing = 0
    var worldCensus = CensusDiagnostics()
    var worldCensusDepthRejections: [DepthSampleRejection: Int] = [:]
    var worldCensusDepthAcceptance: Double = 0
    var worldCensusAnchorErrorPixels: Double = 0
    var worldCensusCalibrationSource = "—"
    var worldCensusMilliseconds: Double = 0
    var worldCensusZoneSummary = "—"
    var worldCensusDepthSummary = "—"
    /// Calibration-to-Live continuity audit. These values come from
    /// `ARTableCapture`'s run wrapper; they never control ARKit behavior.
    var spatialSessionID = "—"
    var spatialPipelineGeneration = 0
    var calibrationRevision = 0
    var configurationRunCount = 0
    var resetTrackingRunCount = 0
    var removeExistingAnchorsRunCount = 0
    var lastConfigurationUsedReset = false
    var lastConfigurationReason = "—"
}
