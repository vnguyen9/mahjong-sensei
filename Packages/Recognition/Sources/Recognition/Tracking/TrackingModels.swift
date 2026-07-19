import Foundation
import MahjongCore

/// Coach Live tracking — public data contract.
///
/// Everything in this file is a pure value type: identity, zones, published
/// tiles/state, and the event log. The algorithms that *produce* these
/// values — `TrackStore` (association/votes/rebirth), `ZoneModel`
/// (calibration/hysteresis), `TurnEngine` (settle-diff event derivation),
/// `HandBoundaryDetector`, and the `TableTracker` facade that wires them
/// together — are later, separate chunks and are deliberately not present
/// here. Where a member would require one of those (e.g. turning a raw
/// `[TrackedTile]` meld group into a scored `Meld`), it is omitted with a
/// note pointing at the chunk that adds it, rather than half-implemented.
///
/// Hard rules honored throughout (see the tracker plan's "Hard rules"): no
/// `Date()`/`Date.now`, no `UUID()` in logic paths — track/event ids are
/// monotonic `Int`s so replays are deterministic; every timestamp is an
/// injected `TimeInterval`.

// MARK: - Identity & zones

/// Stable per-track identity, monotonic within a session. Assigned by
/// `TrackStore` (a later chunk) on birth — never a UUID, so a replayed
/// session produces byte-identical ids run after run.
public struct TrackID: Hashable, Sendable, Codable, Comparable {
    public let raw: Int
    public init(raw: Int) { self.raw = raw }
    public static func < (l: TrackID, r: TrackID) -> Bool { l.raw < r.raw }
}

/// Where a tracked tile currently lives on the table, as classified by
/// `ZoneModel` (a later chunk) from `TableSceneParser`'s raw buckets plus
/// per-track voting/hysteresis.
public enum TileZone: String, Sendable, Codable, Hashable {
    case myHand, myBonus, myMeld, pond, opponentMeld, unresolved
}

/// Seats relative to the camera, which sits at MY seat. Turn order
/// E→S→W→N is counterclockwise around the physical table, so the player who
/// goes *after* me sits on my RIGHT in the frame — `next` walks the turn
/// order, not clockwise screen position.
///
/// Frame convention: bottom edge = me, right edge = next player, top edge =
/// across, left edge = previous player.
public enum RelativeSeat: Int, CaseIterable, Sendable, Codable, Hashable {
    case me = 0, right = 1, across = 2, left = 3

    /// Turn order: me → right → across → left → me.
    public var next: RelativeSeat { RelativeSeat(rawValue: (rawValue + 1) % 4)! }

    /// This seat's wind for the hand, given my own seat wind.
    public func wind(mySeatWind: Wind) -> Wind {
        Wind(rawValue: (mySeatWind.rawValue + rawValue) % 4)!
    }
}

// MARK: - Tracked tile

/// One physically-tracked tile, published to the UI/advice layers. Built and
/// mutated by `TrackStore` (a later chunk); this type itself carries no
/// tracking behavior — it's the read-only-from-outside snapshot `TrackedTableState`
/// is made of. (Internal-only bookkeeping the plan calls for — the vote ring
/// buffer, box history ring, missing-since timestamp — lives inside
/// `TrackStore`, not here; only the published projection is public.)
public struct TrackedTile: Sendable, Identifiable, Hashable {
    public var id: TrackID
    /// Current majority-vote face, or the pinned override when `isPinned`.
    public var face: Tile
    /// Vote share of the winning face, 0...1 (meaningless — always 1 —
    /// while `isPinned`, since voting is bypassed).
    public var faceConfidence: Double
    /// User override via `TableTracker.pin(_:as:)` — wins forever; voting
    /// keeps accumulating internally for diagnostics but never republishes.
    public var isPinned: Bool
    /// Latest (or, while missing, last-seen) box in normalized oriented
    /// coordinates — see `TileBoundingBox`.
    public var box: TileBoundingBox
    public var zone: TileZone
    /// Discarder (`.pond`) or owner (`.opponentMeld`); nil elsewhere.
    public var seat: RelativeSeat?
    /// Index into `TrackedTableState.myMelds` / the owning seat's meld array.
    public var meldGroup: Int?
    public var state: Life
    public var firstSeen: TimeInterval
    public var lastSeen: TimeInterval
    public var observationCount: Int
    /// Inserted via `TableTracker.insertMissedTile` — never auto-removed by
    /// misses, only by an explicit `removeTrack`.
    public var isManual: Bool

    /// Track lifecycle. Tentative tracks never publish events; live tracks
    /// are the confirmed, event-producing steady state; missing tracks are
    /// within grace and still counted; retired tracks are gone but kept in
    /// a short ring for rebirth (`TrackerConfig.retiredRetention`).
    public enum Life: String, Sendable, Codable, Hashable {
        case tentative, live, missing, retired
    }

    public init(id: TrackID, face: Tile, faceConfidence: Double = 1.0, isPinned: Bool = false,
                box: TileBoundingBox, zone: TileZone, seat: RelativeSeat? = nil,
                meldGroup: Int? = nil, state: Life = .tentative,
                firstSeen: TimeInterval, lastSeen: TimeInterval,
                observationCount: Int = 1, isManual: Bool = false) {
        self.id = id
        self.face = face
        self.faceConfidence = faceConfidence
        self.isPinned = isPinned
        self.box = box
        self.zone = zone
        self.seat = seat
        self.meldGroup = meldGroup
        self.state = state
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.observationCount = observationCount
        self.isManual = isManual
    }
}

// MARK: - Published table state

/// Coarse session phase, independent of the fine-grained per-tile `Life`.
public enum TrackedHandPhase: String, Sendable, Codable {
    /// First `TrackerConfig.calibrationFrames` settled frames of a hand:
    /// locking the hand-band/pond geometry before any zone is trusted.
    case calibrating
    /// Steady state — tracking, voting, and emitting events normally.
    case playing
    /// A table-clear is in progress (tiles disappearing) but hasn't yet
    /// sustained long enough to become a `handEndProposed` event.
    case clearing
    /// `handEndProposed` has fired; `TableTracker.pendingHandEnd` is set and
    /// awaiting `confirmHandEnd`/`dismissHandEnd`.
    case endProposed
}

/// The tracker's published table snapshot — mirrors `ScanSession` semantics
/// exactly so the advice slice drops in unchanged: `seenHistogram` is pond +
/// opponent melds only (non-bonus; my own hand/melds excluded), which is
/// exactly what `EfficiencyEngine.ukeire(seen:)` expects, and `unseenCount`
/// = 136 − mine − myMelds − seen.
///
/// Pure data: `TableTracker` (a later chunk) is the only writer, always
/// producing a brand-new `TrackedTableState` on each committed change (`revision`
/// bumps). Nothing here computes anything from tracker internals.
public struct TrackedTableState: Sendable {
    /// Bumps on every committed change — the advice/UI slices watch this
    /// instead of diffing the struct themselves.
    public var revision: Int
    public var phase: TrackedHandPhase
    /// 0-based hand counter for this session.
    public var handIndex: Int
    public var mySeatWind: Wind
    public var roundWind: Wind
    /// nil until the first anchoring event (first settled discard/draw).
    public var currentTurn: RelativeSeat?

    /// Reading order, left→right.
    public var myHand: [TrackedTile]
    /// Displayed flowers/seasons.
    public var myBonus: [TrackedTile]
    public var myMelds: [[TrackedTile]]
    /// Discard order (event order; tiles whose face hasn't settled sort
    /// last).
    public var pond: [TrackedTile]
    public var opponentMelds: [RelativeSeat: [[TrackedTile]]]
    public var unresolved: [TrackedTile]

    /// 34-slot histogram; pond + opponentMelds, non-bonus only.
    public var seenHistogram: [Int]
    public var unseenCount: Int
    /// `myHand` non-bonus count — the 13/14 signal.
    public var handTileCount: Int
    /// The injected win predicate fired on the last commit.
    public var isMyHandComplete: Bool

    public init(revision: Int = 0, phase: TrackedHandPhase = .calibrating, handIndex: Int = 0,
                mySeatWind: Wind = .east, roundWind: Wind = .east, currentTurn: RelativeSeat? = nil,
                myHand: [TrackedTile] = [], myBonus: [TrackedTile] = [], myMelds: [[TrackedTile]] = [],
                pond: [TrackedTile] = [], opponentMelds: [RelativeSeat: [[TrackedTile]]] = [:],
                unresolved: [TrackedTile] = [],
                seenHistogram: [Int] = Array(repeating: 0, count: Tile.baseClassCount),
                unseenCount: Int = 136, handTileCount: Int = 0, isMyHandComplete: Bool = false) {
        self.revision = revision
        self.phase = phase
        self.handIndex = handIndex
        self.mySeatWind = mySeatWind
        self.roundWind = roundWind
        self.currentTurn = currentTurn
        self.myHand = myHand
        self.myBonus = myBonus
        self.myMelds = myMelds
        self.pond = pond
        self.opponentMelds = opponentMelds
        self.unresolved = unresolved
        self.seenHistogram = seenHistogram
        self.unseenCount = unseenCount
        self.handTileCount = handTileCount
        self.isMyHandComplete = isMyHandComplete
    }

    /// The empty pre-session state, before `TableTracker.beginSession`.
    public static let empty = TrackedTableState()
}

// NOTE: the tracker plan's §2.3 `func hand(isSelfDraw: Bool) -> Hand` and
// `var meldsAsMelds: [Meld]` — deferred by chunk 1 pending `MeldClassifier` —
// now live as an `extension TrackedTableState` in `MeldClassifier.swift`,
// which is exactly the natural home this comment originally pointed at.

// MARK: - Events

/// Why a `.stateRevised` event fired — the correction or engine mechanism
/// that rippled through previously-committed history.
public enum RevisionReason: String, Sendable, Codable, Hashable {
    case pin, zoneOverride, insertMissedTile, removeTrack, reattribute
    case handEndConfirmed, handEndDismissed, turnResync
    /// `TableTracker.deleteEvent` — chunk-6 addition (the plan's §5
    /// corrections table doesn't name an event-level delete; only
    /// track-level `removeTrack`). See `TableTracker.deleteEvent`'s doc for
    /// exactly what "delete" means for an append-only log.
    case eventDeleted
}

/// One append-only entry in the session's event log — the UI's diffable
/// feed and the advice engine's trigger stream. `id` is stable across
/// corrections (a correction appends a *new* revision event with
/// `.amended` instead of mutating history), so UI diffing never has to
/// guess.
public struct GameEvent: Sendable, Identifiable, Codable, Hashable {
    /// Monotonic per session — never a UUID (determinism: see `TrackID`).
    public var id: Int
    /// Stream time: video PTS or the session's monotonic clock. Never a
    /// wall clock (`Date()` is banned in tracking code).
    public var at: TimeInterval
    public var handIndex: Int
    public var kind: Kind
    /// Attribution confidence, 0...1 (meaning depends on `kind`; e.g. the
    /// seat softmax score for `.discard`/`.meld`).
    public var confidence: Double
    public var flags: Set<Flag>

    public init(id: Int, at: TimeInterval, handIndex: Int, kind: Kind,
                confidence: Double, flags: Set<Flag> = []) {
        self.id = id
        self.at = at
        self.handIndex = handIndex
        self.kind = kind
        self.confidence = confidence
        self.flags = flags
    }

    public enum Kind: Sendable, Codable, Hashable {
        case handStarted(mySeatWind: Wind, roundWind: Wind)
        case discard(seat: RelativeSeat, tile: Tile, track: TrackID)
        /// `tile` is nil until the drawn tile's face settles past the
        /// confidence floor; the event is amended in place once it does.
        case myDraw(tile: Tile?)
        case myDiscard(tile: Tile, track: TrackID)
        case meld(seat: RelativeSeat, kind: MeldKind, tiles: [Tile],
                  claimedTile: Tile?, claimedFrom: RelativeSeat?)
        /// The injected `TrackerConfig.winPredicate` fired.
        case myHandComplete
        case handEndProposed(missingFraction: Double)
        /// Missing tiles came back (occlusion, not a real hand end) — state
        /// is restored untouched.
        case handEndCancelled
        case handEnded(winner: RelativeSeat?)
        /// A correction (or the turn engine's resync) rippled through
        /// history; see `RevisionReason`.
        case stateRevised(reason: RevisionReason)
    }

    public enum Flag: String, Sendable, Codable {
        /// Seat evidence fell below `TrackerConfig.attributionConfidenceFloor`
        /// — amber in the UI, tappable to fix via `TableTracker.reattribute`.
        case uncertainAttribution
        /// Face vote share fell below `TrackerConfig.faceConfidenceFloor`.
        case uncertainFace
        /// Set by the app/CLI's amber annotator (`EfficiencyEngine.WaitImpact`,
        /// a different package) — Recognition never sets this itself.
        case reducesMyWaits
        /// An opponent pung cluster gained a matching 4th track.
        case upgradedFromPung
        /// This event was corrected after it was first emitted.
        case amended
    }
}

// MARK: - Motion (support types for the live loop / offline harness)

/// Coarse motion-detector bucket — the oriented frame split into left/
/// center/right thirds plus a `top` region for far-side (across-seat)
/// motion. See `MotionDetector` (a later chunk) for how pixels map to this;
/// consumed by `TurnEngine`'s seat-attribution scoring.
public enum MotionRegion: String, Sendable, Codable, Hashable, CaseIterable {
    case left, center, right, top
}

/// One motion reading — sampled every poll tick (~8 Hz), independent of
/// whether an inference happened that tick. `t` is captured at buffer-grab
/// time (a monotonic clock), never a wall clock.
public struct MotionSample: Sendable, Hashable, Codable {
    public var t: TimeInterval
    /// EMA-smoothed level, compared against `TrackerConfig.motionActive` /
    /// `.motionSettle`.
    public var level: Double
    /// nil when no third of the frame clearly dominates the motion.
    public var dominantRegion: MotionRegion?
    /// Mean luma (0–255) of the already-downscaled grid this sample was
    /// built from — available even on the FIRST sample (computed before
    /// `MotionDetector.sample`'s previous-grid diff guard, since brightness
    /// needs no prior frame). Feeds the app-side `DarkTableDetector` for the
    /// torch-suggestion chip (Lane A5); the tracker itself never reads it.
    public var meanLuma: Double

    public init(t: TimeInterval, level: Double, dominantRegion: MotionRegion? = nil, meanLuma: Double = 255) {
        self.t = t
        self.level = level
        self.dominantRegion = dominantRegion
        self.meanLuma = meanLuma
    }

    /// Explicit `CodingKeys` + a hand-written `init(from:)` (paired with the
    /// still-synthesized `encode(to:)`, which the compiler generates from
    /// these same keys) so `meanLuma` decodes tolerantly: existing
    /// `.frames.jsonl` fixtures/goldens and any other archived `MotionSample`
    /// JSON predate this field and simply won't have it — `decodeIfPresent`
    /// defaults it to 255 (bright) rather than failing the decode.
    private enum CodingKeys: String, CodingKey {
        case t, level, dominantRegion, meanLuma
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decode(TimeInterval.self, forKey: .t)
        level = try container.decode(Double.self, forKey: .level)
        dominantRegion = try container.decodeIfPresent(MotionRegion.self, forKey: .dominantRegion)
        meanLuma = try container.decodeIfPresent(Double.self, forKey: .meanLuma) ?? 255
    }
}

/// Per-cell change grid, mirroring the same downscaled 32×18 luma grid
/// `MotionDetector.sample(_:at:)` diffs internally — additive for Lane B
/// chunk E's ROI scheduler. Where `MotionSample.level`/`.dominantRegion`
/// COLLAPSE the per-cell diff into one scalar / one coarse quadrant,
/// `MotionField.changed` keeps it uncollapsed so the app can intersect it
/// against projected zone rects and infer only the zones that actually
/// changed. Deliberately NOT `Codable` — app-consumable only, never written
/// to a `.frames.jsonl` golden (unlike `MotionSample`, whose `Codable`
/// conformance the harness/goldens depend on).
public struct MotionField: Sendable, Hashable {
    /// Grid width/height — the exact dimensions `MotionDetector`'s internal
    /// grid uses (see that type's own doc for why 32×18), exposed here so
    /// app-side ROI code can index `changed` without hardcoding the number.
    public static let gridWidth = MotionDetector.gridWidth
    public static let gridHeight = MotionDetector.gridHeight

    public var sample: MotionSample
    /// Row-major (`row * gridWidth + col`), same RAW (landscape,
    /// sensor-native, unrotated) buffer space `MotionDetector`'s type doc
    /// describes for the underlying grid — `true` where this cell's luma
    /// changed by more than the internal per-cell threshold since the
    /// previous sampled frame. All `false` on the first sample of a session
    /// (nothing to diff against yet), exactly like `sample.level == 0`.
    public var changed: [Bool]

    public init(sample: MotionSample, changed: [Bool]) {
        self.sample = sample
        self.changed = changed
    }
}

/// A pending, non-destructive hand-end candidate — `TableTracker.pendingHandEnd`
/// (a later chunk) surfaces this to the UI as a confirm/dismiss card.
/// Nothing about the tracked state changes until `confirmHandEnd`/
/// `dismissHandEnd` is called.
public struct HandEndProposal: Sendable, Codable, Hashable {
    /// When `handEndProposed` fired.
    public var at: TimeInterval
    /// Fraction of confirmed tracks currently missing.
    public var missingFraction: Double
    /// `WindRotation`'s prediction for the next hand, for the confirm card;
    /// nil if not yet computed. The rotation math itself lives in
    /// `WindRotation.swift` (a later chunk) — this struct only carries the
    /// result.
    public var predictedWinds: PredictedWinds?

    public struct PredictedWinds: Sendable, Codable, Hashable {
        public var mySeatWind: Wind
        public var roundWind: Wind
        public init(mySeatWind: Wind, roundWind: Wind) {
            self.mySeatWind = mySeatWind
            self.roundWind = roundWind
        }
    }

    public init(at: TimeInterval, missingFraction: Double, predictedWinds: PredictedWinds? = nil) {
        self.at = at
        self.missingFraction = missingFraction
        self.predictedWinds = predictedWinds
    }
}

// MARK: - Ingest outcome

/// What one `TableTracker.ingest` call actually did — lets the caller (app
/// loop / CLI) decide whether to republish state, run the amber annotator
/// on `newEvents`, etc., without diffing `TrackedTableState` itself.
public struct IngestOutcome: Sendable {
    public var newEvents: [GameEvent]
    /// True when `state.revision` bumped this call.
    public var stateChanged: Bool
    /// True when this frame was a settle commit (motion below gate) rather
    /// than a during-motion ingest that only fed tracks/votes.
    public var settled: Bool

    public init(newEvents: [GameEvent] = [], stateChanged: Bool = false, settled: Bool = false) {
        self.newEvents = newEvents
        self.stateChanged = stateChanged
        self.settled = settled
    }
}

// MARK: - Persistence (plan A6: survive relaunch)

/// A state-EXPORT snapshot of a `TableTracker` session, for on-disk
/// persistence across a process relaunch — `TableTracker.snapshot(at:)` /
/// `.restore(_:at:)`. Deliberately NOT an internal-state dump: `TrackStore`'s
/// vote rings/box history and `ZoneModel`'s hand-band/pond-centroid
/// calibration are private, order-sensitive bookkeeping, and — since the
/// camera may well be repropped in a different spot after a relaunch —
/// re-learning that geometry from a few fresh frames is safer than trusting
/// stale numbers anyway. What *is* exported is the durable, camera-position-
/// independent part: winds, the hand/round counters, the append-only event
/// log, and every CONFIRMED tile's identity/face/box/zone/seat/timestamps
/// (see `TableTracker.snapshot`'s own doc for exactly what "confirmed"
/// excludes and why).
///
/// Pure data, `Codable` so the app can round-trip it through JSON. Every
/// timestamp here is the tracker's own monotonic `TimeInterval` — never a
/// wall clock (the app pairs this with a wall-clock `savedAt` of its own and
/// remaps every timestamp to the new process's clock origin on load; see
/// `CoachLiveSessionPersistence.remapped(toNowMono:)`).
public struct TrackerSnapshot: Sendable, Codable {
    public var mySeatWind: Wind
    public var roundWind: Wind
    /// 0-based hand counter — see `TrackedTableState.handIndex`.
    public var handIndex: Int
    /// See `WindRotation`'s own doc for why this is required, caller-owned
    /// state rather than something derivable from the winds alone.
    public var dealsSinceRoundStart: Int
    /// The full append-only event log at save time, restored verbatim (these
    /// events already happened — nothing about them needs re-deriving).
    public var events: [GameEvent]
    /// Every CONFIRMED tile as of save time. `.unresolved` tracks are
    /// deliberately excluded — see `TableTracker.snapshot`'s doc.
    public var tiles: [SnapshotTile]
    /// The tracker's own monotonic clock at save time.
    public var savedAtMono: TimeInterval

    public init(mySeatWind: Wind, roundWind: Wind, handIndex: Int, dealsSinceRoundStart: Int,
                events: [GameEvent], tiles: [SnapshotTile], savedAtMono: TimeInterval) {
        self.mySeatWind = mySeatWind
        self.roundWind = roundWind
        self.handIndex = handIndex
        self.dealsSinceRoundStart = dealsSinceRoundStart
        self.events = events
        self.tiles = tiles
        self.savedAtMono = savedAtMono
    }

    /// One persisted tile — exactly the fields `TrackStore.restoreTrack`
    /// needs to resurrect it under its ORIGINAL identity, box, and
    /// timestamps (as opposed to `insertManualTrack`, which mints a fresh id
    /// and stamps `firstSeen`/`lastSeen` at insertion time).
    public struct SnapshotTile: Sendable, Codable {
        public var id: TrackID
        public var face: Tile
        public var box: TileBoundingBox
        public var zone: TileZone
        /// Discarder (`.pond`) or owner (`.opponentMeld`); nil elsewhere —
        /// mirrors `TrackedTile.seat`.
        public var seat: RelativeSeat?
        public var firstSeen: TimeInterval
        public var lastSeen: TimeInterval
        public var observationCount: Int

        public init(id: TrackID, face: Tile, box: TileBoundingBox, zone: TileZone, seat: RelativeSeat?,
                    firstSeen: TimeInterval, lastSeen: TimeInterval, observationCount: Int) {
            self.id = id
            self.face = face
            self.box = box
            self.zone = zone
            self.seat = seat
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
            self.observationCount = observationCount
        }
    }
}
