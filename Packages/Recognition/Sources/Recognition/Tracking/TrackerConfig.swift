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
