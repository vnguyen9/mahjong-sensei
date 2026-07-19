import Foundation
import MahjongCore

/// Every tunable threshold the tracker (`TrackStore` / `ZoneModel` /
/// `TurnEngine` / `HandBoundaryDetector` — later chunks) reads, gathered in
/// one place so a harness run on real video
/// (`Planning/Mahjong Tables/Videos/IMG_6249.mov`, via `Tools/detect-dump`)
/// can retune the whole pipeline by editing one struct's `var`s — no
/// constant is buried inside an algorithm file. Defaults are the tracker
/// plan's §7 table.
///
/// `TrackerConfig` is itself pure data — a value passed into `TableTracker`
/// (`TableTracker.init(config:)`, a later chunk) — plus the two injected
/// rule-engine closures the dependency rule requires (Recognition depends
/// only on MahjongCore; the touchpoints into ScoringEngine/EfficiencyEngine
/// are seams, not imports).
///
/// `CadencePolicy`'s own constants (`pollInterval`, `idleInterval`,
/// `burstInterval`, `settleBurstCount`, `settleBurstInterval`, thermal
/// multipliers) are **not** duplicated here even though the plan's §7 table
/// lists them alongside these — they belong to `CadencePolicy` itself (a
/// separate, later chunk/file), so tuning them can't drift out of sync with
/// two copies of the same number.
public struct TrackerConfig: Sendable {

    // MARK: - Association (TrackStore) — ByteTrack adapted to a static table

    /// High-confidence band floor: detections at/above this are matched
    /// against every live+missing track first, and are the only detections
    /// allowed to birth a *new* track (together with `birthConfidence`).
    public var highConfidence: Double = 0.50

    /// Minimum confidence for an unmatched high-band detection to birth a
    /// brand-new tentative track (after the rebirth check fails first).
    public var birthConfidence: Double = 0.45

    /// Face-vote weight applied to a low-band (`0.30..<highConfidence`)
    /// match. Low-band detections sustain an existing track and vote, but
    /// can never birth one — the ByteTrack trick that absorbs nano-misses on
    /// rotated/occluded pond tiles without ever losing the track's identity.
    public var lowBandVoteWeight: Double = 0.5

    /// Minimum IoU for a detection↔track candidate pair (either gate below
    /// admits the pair — see `centerGateFactor`).
    public var iouGate: Double = 0.30

    /// Alternate association gate: center distance ≤ this × the tile's
    /// diagonal also admits a candidate pair. Pond tiles are ~0.03 wide, so
    /// jitter alone can kill IoU while the centers barely move.
    public var centerGateFactor: Double = 0.75

    /// Matches required (within `confirmWindow` ingests) before a tentative
    /// track is admitted as `live` and starts producing events. The
    /// M-frames admission gate.
    public var confirmFrames: Int = 3

    /// Ingest window `confirmFrames` matches must fall within. Tentative
    /// tracks that don't reach `confirmFrames` inside this window die
    /// silently (never emit an event) after 2 misses.
    public var confirmWindow: Int = 5

    // MARK: - Face voting

    /// Capacity of each track's weighted face-vote ring buffer
    /// (observations, not seconds).
    public var voteWindow: Int = 15

    /// A challenger face only *becomes* the published face once its
    /// weighted vote total leads the incumbent by this margin — stops a
    /// 50/50 7s/8s flicker from ever churning the published state or the
    /// histogram.
    public var voteHysteresisMargin: Double = 2.0

    /// Below this winning-vote share, the face is published as uncertain
    /// (`GameEvent.Flag.uncertainFace`).
    public var faceConfidenceFloor: Double = 0.6

    // MARK: - Track lifecycle & rebirth

    /// Grace period before a missing track retires when the scene has been
    /// calm (no recent motion burst).
    public var missingGraceSettled: TimeInterval = 2.0

    /// Grace period before a missing track retires when motion exceeded
    /// `motionActive` within the last `motionCooldown` seconds — long
    /// enough for an arm to occlude a tile for several seconds without
    /// losing it.
    public var missingGraceMotion: TimeInterval = 6.0

    /// How long a motion burst above `motionActive` keeps "recent motion"
    /// true for the purposes of choosing `missingGraceMotion` over
    /// `missingGraceSettled`.
    public var motionCooldown: TimeInterval = 3.0

    /// How long a retired track's identity (face votes, pin, zone history)
    /// is kept in a ring so a later rebirth can resurrect it.
    public var retiredRetention: TimeInterval = 10.0

    /// Rebirth search radius, in multiples of the tile's own diagonal. Also
    /// doubles as the ghost-suppression radius after `TableTracker.removeTrack`:
    /// the same box is checked against the suppression list before it's
    /// allowed to birth a new track.
    public var rebirthRadius: Double = 2.5

    /// How long after retirement a same-face detection nearby still counts
    /// as a rebirth rather than a brand-new track.
    public var rebirthWindow: TimeInterval = 10.0

    // MARK: - Settle-diff commit (TurnEngine)

    /// Motion must stay below `motionSettle` for this long before the
    /// tracker diffs the last committed snapshot against the current one
    /// and emits events. Nothing commits mid-motion — this is what makes
    /// occlusion chaos and half-moved tiles harmless.
    public var settleDelay: TimeInterval = 0.7

    /// Motion level (see `MotionDetector`, a later chunk) above which the
    /// scene counts as "in action" — cadence bursts, dropout rises, grace
    /// extends. Tuned against real video (`IMG_6249.mov`) via the offline
    /// harness.
    public var motionActive: Double = 0.045

    /// Motion level below which the scene counts as settled — staying below
    /// this for `settleDelay` triggers a commit.
    public var motionSettle: Double = 0.02

    /// A 13↔14 hand-count change must hold for this long (of settled time)
    /// before it is trusted as a real draw/discard rather than an occlusion
    /// wobble (e.g. 13→11→14).
    public var handCountSustain: TimeInterval = 1.2

    // MARK: - Zones (ZoneModel)

    /// Settled-frame window a track's zone vote is majority-decided over.
    public var zoneVoteWindow: Int = 9

    /// Net-vote margin required to actually switch a track's published
    /// zone — a couple of bad parser frames should never flip it.
    public var zoneSwitchMargin: Int = 3

    /// Number of settled frames (with a parsed rank) used to lock the
    /// persistent image-space calibration: the hand-band and the pond
    /// centroid/covariance. Legitimate because the camera is static.
    public var calibrationFrames: Int = 5

    /// Mahalanobis-distance cut (in pond-covariance sigmas) a table
    /// cluster's centroid must clear to be judged "outside the pond core"
    /// — the meld-vs-pond split for undifferentiated table detections.
    public var pondCoreSigma: Double = 2.0

    /// Stand/photo geometry knobs handed straight to `TableSceneParser` —
    /// exposed here so the harness can tune, e.g., `minHandTileHeight` for a
    /// stand viewpoint, without touching tracker code.
    public var sceneConfig: TableSceneParser.Config = TableSceneParser.Config()

    /// Standing zone-vote bonus (added, per settled frame, to the effective
    /// `myHand` tally) for a track whose box sits inside the calibrated
    /// hand-band but which the parser bucketed as *not* mine that frame — the
    /// static-camera prior the plan calls for ("tracks inside the band bias to
    /// myHand even when the parser has an off frame"). Kept modest so it nudges
    /// borderline/off frames without overpowering `zoneSwitchMargin` votes.
    /// (Chunk-4 addition: the plan names the hand-band prior but leaves its
    /// weight to the implementer.)
    public var zonePriorWeight: Double = 0.5

    /// The calibrated hand-band is the observed rank-tile center-Y range grown
    /// by this × the rank's median tile height on each side — slack that keeps
    /// a hand tile whose box jitters a little above/below the rank line inside
    /// the band. (Chunk-4 addition: the plan's "rank line ± slack".)
    public var handBandSlackFactor: Double = 1.0

    /// Initial isotropic pond spread (normalized-image sigma) used to seed the
    /// online pond centroid/covariance with a prior of `calibrationFrames`
    /// pseudo-observations at the table centre. This makes the covariance
    /// non-degenerate from the very first discard (so Mahalanobis is always
    /// well-defined), lets a lone early meld read as an outlier before enough
    /// discards accumulate, and is progressively washed out as real pond tiles
    /// fold in. Also the displacement floor below which pond-entry geometry is
    /// treated as uninformative in seat attribution. (Chunk-4 addition: the
    /// plan specifies pond centroid+covariance but not its bootstrap.)
    public var pondInitialSigma: Double = 0.12

    /// Interim-fix rescue gate (harness-tunable): minimum tile count for a
    /// table cluster to be considered for the `.myHand` rescue vote on a
    /// frame where `TableSceneParser` found no hand at all
    /// (`scene.mine.isEmpty`) — deliberately stricter than the parser's own
    /// `minHandCount` (4) so the rescue only fires on a cluster that's
    /// unambiguously a full rank, never a stray handful of table tiles.
    public var handRescueMinTiles: Int = 8

    /// Interim-fix rescue gate (harness-tunable): minimum mean/center-Y
    /// (normalized image space, top-left origin) for a rescued cluster —
    /// keeps the rescue confined to the bottom band a player's-seat rank
    /// actually occupies, so a big near-camera pond cluster elsewhere on the
    /// table can never be mistaken for the hand just because the parser
    /// whiffed this frame.
    public var handRescueMinY: Double = 0.55

    // MARK: - Coordinate space (image-space harness ↔ ARKit table-space live path)

    /// Which coordinate frame the tracker's boxes live in — the seam that lets
    /// the *same* `TableTracker` serve both the offline image-space harness
    /// (and the live fallback when plane detection fails) and the ARKit
    /// table-space live path (Lane B). The default preserves ALL current
    /// behavior — `TrackStore`/`TurnEngine`/the harness never look at it; only
    /// `ZoneModel`'s vote source branches on it.
    public enum CoordinateSpace: Sendable {
        /// Boxes are normalized oriented-image coordinates (top-left origin,
        /// larger y toward me) — what the detector and the whole harness emit.
        /// Zones come from `TableSceneParser` + learned hand-band/pond
        /// calibration.
        case imageSpace
        /// Boxes are normalized table-plane coordinates produced by
        /// `DetectionProjector`: the locked plane anchor sits at (0.5, 0.5),
        /// the [0,1] range spans `TableGeometry.extent` metres, and — by the
        /// app's oriented-lock contract — larger y still points toward me
        /// (matching image space's `seatFromDisplacement` convention). Zones
        /// come from fixed `tableGeometry`, the parser is bypassed.
        case tableSpace
    }

    /// Active coordinate space. Default `.imageSpace` — every existing call
    /// site, test, and golden runs unchanged.
    public var coordinateSpace: CoordinateSpace = .imageSpace

    /// Fixed table geometry for `.tableSpace` zoning — the app fills this at
    /// table-lock time from the locked plane's real dimensions. In
    /// `.tableSpace` mode it *replaces* image space's learned hand-band/pond
    /// calibration (which a world-anchored plane makes unnecessary): geometry
    /// is a session constant read straight off the plane, not something to
    /// accumulate. `nil` in `.imageSpace` (never read there).
    public struct TableGeometry: Sendable {
        /// Physical metres spanned by table-space's normalized [0,1] range —
        /// the same value the app passes as `DetectionProjector.tableExtent`.
        /// Not read by `ZoneModel` (which works purely in the already-
        /// normalized units below), but carried alongside them so the one
        /// geometry the app fills at table-lock lives in one struct. Default
        /// 0.9 ≈ a standard ~0.9m playing area.
        public var extent: Double
        /// Depth of the hand-rank band measured inward from an edge, as a
        /// fraction of `extent`. My concealed rank sits within this of my
        /// edge (the high-y side, y = 1); the *same* depth is how close an
        /// opponent's meld must hug one of the other three edges to be read as
        /// theirs. Default 0.18 ≈ a rank resting within ~15cm of the edge on a
        /// ~0.9m table.
        public var handBandDepth: Double
        /// Radius of the central pond disk around the plane anchor (0.5, 0.5),
        /// as a fraction of `extent`. A tile inside it — that isn't part of a
        /// hand row or an edge meld — is a pond discard. Default 0.30 ≈ the
        /// pond occupying the central ~50cm of a ~0.9m table.
        public var pondRadius: Double

        public init(extent: Double = 0.9, handBandDepth: Double = 0.18, pondRadius: Double = 0.30) {
            self.extent = extent
            self.handBandDepth = handBandDepth
            self.pondRadius = pondRadius
        }
    }

    /// The active table geometry in `.tableSpace` mode; `nil` in `.imageSpace`.
    /// In table-space mode `ZoneModel.isBandCalibrated` (the facade's
    /// "geometry ready?" readout, which drives the `.calibrating`→`.playing`
    /// phase) reports readiness off whether this is set — there is no
    /// per-frame band to accumulate, so a set geometry *is* readiness.
    public var tableGeometry: TableGeometry?

    // MARK: - Turn attribution

    /// Weight of "this seat is the expected next discarder" in the seat
    /// attribution softmax.
    public var attributionPriorWeight: Double = 2.0

    /// Weight of "the motion burst's dominant frame third matches this
    /// seat's side" in the seat attribution softmax.
    public var attributionMotionWeight: Double = 1.0

    /// Weight of "the pond-entry position is nearest this seat's pond edge"
    /// in the seat attribution softmax.
    public var attributionGeometryWeight: Double = 0.5

    /// Below this softmax-normalized confidence, a discard/meld attribution
    /// is flagged `.uncertainAttribution` (amber, tappable to fix) rather
    /// than trusted outright.
    public var attributionConfidenceFloor: Double = 0.55

    /// When fresh motion+geometry evidence disagrees with the rotation
    /// prior's expected seat by at least this much score, trust the
    /// evidence and re-anchor the rotation from it — keeps the turn machine
    /// self-correcting instead of brittle to a single missed discard.
    public var resyncMargin: Double = 1.5

    // MARK: - Hand boundary (HandBoundaryDetector)

    /// Fraction of confirmed tracks that must be simultaneously `missing`
    /// before a hand-end is even considered.
    public var handClearFraction: Double = 0.6

    /// Minimum number of missing tracks required alongside
    /// `handClearFraction` — keeps a big claim (≤5 tiles moving) from ever
    /// being mistaken for the table being swept clear.
    public var handClearMinTiles: Int = 8

    /// How long the clear must be sustained before `handEndProposed` fires.
    public var handClearSustain: TimeInterval = 5.0

    /// Fraction of the missing tracks that must re-associate at their old
    /// spots to auto-cancel a pending hand-end proposal (the walk-by /
    /// leaned-over-the-table case).
    public var reappearFraction: Double = 0.5

    /// Window after a hand-end proposal during which reappearing tracks
    /// still count toward `reappearFraction`.
    public var reappearWindow: TimeInterval = 8.0

    /// After a manual `dismiss`, how long a *subset* of the dismissed missing
    /// set is suppressed from re-proposing — ~4× `handClearSustain`. Long
    /// enough to cover a lean-over-the-table misfire (the same handful of
    /// tiles going missing again within seconds) without masking a real next
    /// clear: genuinely new missing tracks (not a subset of what was
    /// dismissed) lift the cooldown immediately.
    public var handEndDismissCooldown: TimeInterval = 20.0

    // MARK: - Bookkeeping

    /// Per-track box-history ring capacity (observations, not seconds).
    public var boxHistoryCap: Int = 12

    /// After `TableTracker.removeTrack`, the removed box is suppressed
    /// (radius = `rebirthRadius`) for this long so the same ghost detection
    /// can't immediately birth a replacement track.
    public var suppressionWindow: TimeInterval = 5.0

    // MARK: - Injected rule-engine seams

    /// `(concealed tiles, melds) -> won?`. The app and `track-replay` inject
    /// `{ ScoringEngine.isWinningShape(Hand(concealedTiles: $0, melds: $1)) }`;
    /// unit tests inject stubs. Recognition never imports ScoringEngine —
    /// this closure is the entire dependency-rule seam for the win check.
    public typealias WinPredicate = @Sendable ([Tile], [Meld]) -> Bool

    /// Injected win-check, nil until the app/CLI wires it up. `TurnEngine`
    /// (a later chunk) calls this once per hand-count-14 settle and emits
    /// `.myHandComplete` on the rising edge (re-armed when the hand
    /// changes).
    public var winPredicate: WinPredicate?

    public init() {}
}
