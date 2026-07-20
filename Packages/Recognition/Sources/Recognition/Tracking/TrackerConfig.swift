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
    /// One **oriented** band = the swept rectangle from segment A→B extruded
    /// inward (toward the table centre (0.5, 0.5)) by `depth`. All points are
    /// normalized table-space (anchor (0.5, 0.5); my edge y = 1). Unlike the
    /// old axis-aligned "depth from an edge", A→B may sit at *any* angle, so a
    /// hand row that isn't parallel to the table edge is still classified
    /// correctly. Membership is distance-to-oriented-rectangle, and
    /// `penetration` (perpendicular depth past the A→B line) generalizes the
    /// old "distance to this edge" used for corner tie-breaking. The
    /// axis-aligned cases are a strict special case (see `TableGeometry`'s
    /// legacy init), so `penetration` reproduces the old `nearestEdge`
    /// distances exactly.
    public struct OrientedBand: Sendable, Equatable, Codable {
        /// One end-post of the band's near edge (on the physical table edge).
        public var a: SIMD2<Double>
        /// The other end-post of the band's near edge.
        public var b: SIMD2<Double>
        /// Band thickness inward from the A→B line, as a fraction of `extent`.
        public var depth: Double

        public init(a: SIMD2<Double>, b: SIMD2<Double>, depth: Double) {
            self.a = a
            self.b = b
            self.depth = depth
        }

        /// Unit tangent along A→B, its length, and the inward unit normal
        /// (perpendicular to A→B, rotated toward the table centre). Degenerate
        /// A==B falls back to a horizontal band so callers never divide by 0.
        @inline(__always)
        private var basis: (t: SIMD2<Double>, length: Double, n: SIMD2<Double>) {
            let d = b - a
            let len = (d.x * d.x + d.y * d.y).squareRoot()
            guard len > 1e-9 else {
                // Degenerate: treat as a horizontal edge, inward = toward centre.
                let mid = (a + b) * 0.5
                let n0 = SIMD2<Double>(0, (0.5 - mid.y) >= 0 ? 1 : -1)
                return (SIMD2<Double>(1, 0), 0, n0)
            }
            let t = SIMD2<Double>(d.x / len, d.y / len)
            // Two perpendiculars; pick the one pointing toward the centre.
            var n = SIMD2<Double>(-t.y, t.x)
            let mid = (a + b) * 0.5
            let toCentre = SIMD2<Double>(0.5 - mid.x, 0.5 - mid.y)
            if (n.x * toCentre.x + n.y * toCentre.y) < 0 { n = SIMD2<Double>(-n.x, -n.y) }
            return (t, len, n)
        }

        /// True iff `p` lies within the oriented rectangle. `endSlack` extends
        /// the band past its end-posts along the A→B axis (0 = exact segment).
        public func contains(_ p: SIMD2<Double>, endSlack: Double = 0) -> Bool {
            let (t, len, n) = basis
            let d = SIMD2<Double>(p.x - a.x, p.y - a.y)
            let along = d.x * t.x + d.y * t.y
            let perp = d.x * n.x + d.y * n.y
            return along >= -endSlack && along <= len + endSlack && perp >= 0 && perp <= depth
        }

        /// Perpendicular penetration of `p` past the A→B line toward the
        /// centre — the generalized "distance to this edge". Equals the old
        /// `nearestEdge` distance for the axis-aligned bands.
        public func penetration(_ p: SIMD2<Double>) -> Double {
            let (_, _, n) = basis
            return (p.x - a.x) * n.x + (p.y - a.y) * n.y
        }

        /// The band's 4 corners a → b → b+depth·n → a+depth·n (for ROI crop
        /// projection).
        public var corners: [SIMD2<Double>] {
            let (_, _, n) = basis
            let off = SIMD2<Double>(n.x * depth, n.y * depth)
            return [a, b, SIMD2<Double>(b.x + off.x, b.y + off.y), SIMD2<Double>(a.x + off.x, a.y + off.y)]
        }

        /// Band centre = midpoint(a, b) + (depth/2)·n (for ROI zone centres).
        public var center: SIMD2<Double> {
            let (_, _, n) = basis
            let mid = (a + b) * 0.5
            return SIMD2<Double>(mid.x + n.x * depth * 0.5, mid.y + n.y * depth * 0.5)
        }
    }

    /// The pond (the central discard area). Historically a disk around the
    /// table centre; calibration now marks it as an explicit **axis-aligned
    /// rectangle** (two pinch-dropped opposite corners), which real ponds —
    /// off-centre toward the discarder and rectangular, not round — need. Both
    /// shapes are kept so the legacy disk path stays byte-for-byte identical.
    public enum PondShape: Sendable, Equatable, Codable {
        /// Disk of `radius` (fraction of extent) around `center` — legacy model.
        case disk(center: SIMD2<Double>, radius: Double)
        /// Axis-aligned rectangle in table space; `min`/`max` opposite corners.
        case rect(min: SIMD2<Double>, max: SIMD2<Double>)
        /// An arbitrary (convex) quad — 4 corners in winding order — for a
        /// rotated/irregular pond the axis-aligned rect can't cover. Refined by
        /// dragging the 4 corners during calibration.
        case quad(corners: [SIMD2<Double>])

        /// The default central disk (radius 0.30 around the anchor (0.5, 0.5)).
        public static let defaultPond = PondShape.disk(center: SIMD2(0.5, 0.5), radius: 0.30)

        /// True iff `p` (normalized table space) is inside the pond.
        public func contains(_ p: SIMD2<Double>) -> Bool {
            switch self {
            case let .disk(center, radius):
                let dx = p.x - center.x, dy = p.y - center.y
                return (dx * dx + dy * dy).squareRoot() <= radius
            case let .rect(mn, mx):
                return p.x >= mn.x && p.x <= mx.x && p.y >= mn.y && p.y <= mx.y
            case let .quad(c):
                // Two-triangle test over the ordered corners — robust for any
                // ordered convex quad (and reasonable near-convex ones).
                guard c.count == 4 else { return false }
                return Self.pointInTriangle(p, c[0], c[1], c[2])
                    || Self.pointInTriangle(p, c[0], c[2], c[3])
            }
        }

        /// Pond centre in table space.
        public var center: SIMD2<Double> {
            switch self {
            case let .disk(center, _): return center
            case let .rect(mn, mx): return (mn + mx) * 0.5
            case let .quad(c):
                guard !c.isEmpty else { return SIMD2(0.5, 0.5) }
                return c.reduce(SIMD2(0, 0), +) / Double(c.count)
            }
        }

        /// The 4 corners of the pond's bounding box, for ROI crop projection —
        /// the circumscribing square for a disk, the rect/quad's own corners
        /// otherwise.
        public var corners: [SIMD2<Double>] {
            switch self {
            case let .disk(c, r):
                return [SIMD2(c.x - r, c.y - r), SIMD2(c.x + r, c.y - r),
                        SIMD2(c.x + r, c.y + r), SIMD2(c.x - r, c.y + r)]
            case let .rect(mn, mx):
                return [SIMD2(mn.x, mn.y), SIMD2(mx.x, mn.y),
                        SIMD2(mx.x, mx.y), SIMD2(mn.x, mx.y)]
            case let .quad(c):
                return c
            }
        }

        /// Back-compat scalar "radius": the disk radius, or half the shorter
        /// bounding side (used by the debug HUD + legacy assertions).
        public var effectiveRadius: Double {
            switch self {
            case let .disk(_, r): return r
            case let .rect(mn, mx): return Swift.min(mx.x - mn.x, mx.y - mn.y) * 0.5
            case let .quad(c):
                guard !c.isEmpty else { return 0 }
                let xs = c.map(\.x), ys = c.map(\.y)
                return Swift.min(xs.max()! - xs.min()!, ys.max()! - ys.min()!) * 0.5
            }
        }

        /// Point-in-triangle via consistent edge-cross signs (allows the
        /// boundary).
        private static func pointInTriangle(_ p: SIMD2<Double>,
                                            _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
            func cross(_ o: SIMD2<Double>, _ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double {
                (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x)
            }
            let d1 = cross(p, a, b), d2 = cross(p, b, c), d3 = cross(p, c, a)
            let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
            let hasPos = d1 > 0 || d2 > 0 || d3 > 0
            return !(hasNeg && hasPos)
        }
    }

    /// One seat placed on the locked table: which relative seat it is, its
    /// wind for the hand, and the normalized midpoint of the table edge it
    /// sits behind. Derived at calibration from the 4 plane-edge midpoints
    /// (user seat = the +Z / y=1 edge; others counter-clockwise).
    public struct SeatSlot: Sendable, Equatable, Codable {
        public var seat: RelativeSeat
        public var wind: Wind
        public var edgeMidpoint: SIMD2<Double>

        public init(seat: RelativeSeat, wind: Wind, edgeMidpoint: SIMD2<Double>) {
            self.seat = seat
            self.wind = wind
            self.edgeMidpoint = edgeMidpoint
        }
    }

    /// How the locked table space is carved into zones.
    public enum ZoneLayout: Sendable, Equatable, Codable {
        /// Legacy: an oriented hand band + thin per-opponent meld bands + a
        /// pond region; anything inside none of them is `.unresolved`. Leaves a
        /// gap ("moat") between the shallow edge bands and the pond, so table
        /// tiles between them fall to `.unresolved`.
        case bands
        /// Whole-table partition (the AR auto-layout): a central pond rect, and
        /// every non-pond tile is assigned to the NEAREST table edge → that
        /// seat's zone (you = my edge; the other three = opponents). Tiles the
        /// entire table with no gaps, so nothing falls to `.unresolved`.
        case partition
    }

    public struct TableGeometry: Sendable, Equatable, Codable {
        /// Schema version — lets a decoded geometry from an older archive be
        /// discarded (→ recalibrate) rather than trusted. Bumped to 4 when a
        /// `layout` (thin `.bands` vs whole-table `.partition`) was added; was
        /// 3 when the pond became a `PondShape` (disk **or** rect) instead of a
        /// scalar.
        public static let currentVersion = 4
        public var version: Int
        /// Physical metres spanned by table-space's normalized [0,1] range —
        /// the same value the app passes as `DetectionProjector.tableExtent`.
        /// Carried alongside the normalized fields so the one geometry the app
        /// fills at table-lock lives in one struct. Default 0.9 ≈ a standard
        /// ~0.9m playing area.
        public var extent: Double
        /// My concealed hand row, as an oriented band hugging my edge (y = 1).
        /// May tilt when my tiles aren't parallel to the table edge.
        public var handBand: OrientedBand
        /// The pond region (central discard area) — a disk (legacy) or an
        /// explicit axis-aligned rectangle (two-corner calibration).
        public var pond: PondShape
        /// The 4 seats placed on the table (user seat first).
        public var seats: [SeatSlot]
        /// Per-opponent meld band hugging that seat's inner edge. Tiles that
        /// land in `meldBands[seat]` are read as that opponent's exposed meld.
        public var meldBands: [RelativeSeat: OrientedBand]

        /// How the table is carved into zones — legacy thin `.bands` (default,
        /// behaviour unchanged) or a gapless whole-table `.partition` (the AR
        /// auto-layout: pond rect + nearest-edge fill, no `.unresolved` moat).
        public var layout: ZoneLayout

        /// Back-compat convenience: the hand band's depth (many call sites and
        /// the meld bands historically shared one scalar depth).
        public var handBandDepth: Double { handBand.depth }

        /// Back-compat convenience: a scalar pond "radius" (the disk radius, or
        /// half the rect's shorter side) for the debug HUD + legacy assertions.
        public var pondRadius: Double { pond.effectiveRadius }

        /// Canonical initializer — an oriented hand band + explicit seats and
        /// per-opponent meld bands.
        public init(extent: Double = 0.9,
                    handBand: OrientedBand,
                    pond: PondShape = .defaultPond,
                    seats: [SeatSlot],
                    meldBands: [RelativeSeat: OrientedBand],
                    layout: ZoneLayout = .bands,
                    version: Int = TableGeometry.currentVersion) {
            self.version = version
            self.extent = extent
            self.handBand = handBand
            self.pond = pond
            self.seats = seats
            self.meldBands = meldBands
            self.layout = layout
        }

        /// Legacy / back-compat initializer — synthesizes the axis-aligned
        /// hand band (along y = 1), the 3 axis-aligned opponent meld bands, and
        /// default seats/winds from a single `handBandDepth` scalar. Chosen so
        /// `OrientedBand.contains`/`penetration` reproduce the old
        /// `nearestEdge` zoning byte-for-byte — every pre-existing construction
        /// site keeps compiling and behaving identically.
        public init(extent: Double = 0.9,
                    handBandDepth: Double = 0.18,
                    pondRadius: Double = 0.30,
                    mySeatWind: Wind = .east) {
            let hand = OrientedBand(a: SIMD2(0, 1), b: SIMD2(1, 1), depth: handBandDepth)
            // Edge midpoints: me=+y(y=1), right=+x(x=1), across=-y(y=0), left=-x(x=0).
            let midpoints: [RelativeSeat: SIMD2<Double>] = [
                .me: SIMD2(0.5, 1), .right: SIMD2(1, 0.5),
                .across: SIMD2(0.5, 0), .left: SIMD2(0, 0.5),
            ]
            let seats = RelativeSeat.allCases.map { seat in
                SeatSlot(seat: seat, wind: seat.wind(mySeatWind: mySeatWind),
                         edgeMidpoint: midpoints[seat] ?? SIMD2(0.5, 0.5))
            }
            // Axis-aligned meld bands whose inward normals reproduce the old
            // per-edge distances: left → cx, right → 1-cx, across → cy.
            let melds: [RelativeSeat: OrientedBand] = [
                .left: OrientedBand(a: SIMD2(0, 0), b: SIMD2(0, 1), depth: handBandDepth),
                .right: OrientedBand(a: SIMD2(1, 0), b: SIMD2(1, 1), depth: handBandDepth),
                .across: OrientedBand(a: SIMD2(0, 0), b: SIMD2(1, 0), depth: handBandDepth),
            ]
            self.init(extent: extent, handBand: hand,
                      pond: .disk(center: SIMD2(0.5, 0.5), radius: pondRadius),
                      seats: seats, meldBands: melds)
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

    /// Master switch for the automatic table-clear hand-end heuristic
    /// (`HandBoundaryDetector`). Default `true` — the image-space harness,
    /// goldens, and tests are unchanged. Coach Live's AR `.tableSpace` config
    /// sets this **false**: camera motion / relocalization / TrackID churn make
    /// "tiles vanished" indistinguishable from "table swept clear", so hand-end
    /// there is user-driven (a manual "End hand" action) instead. When false
    /// `TableTracker` never calls `HandBoundaryDetector.evaluateSettled`, so
    /// `pendingHandEnd` stays nil (the real-win `.myHandComplete` path is
    /// separate and unaffected).
    public var autoHandEndEnabled: Bool = true

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

    /// EMA factor for smoothing a matched track's published box CENTER toward
    /// each new detection: `center = lerp(prevCenter, detCenter, 1 - factor)`
    /// (higher = steadier, more lag). `0` = OFF — the track box is the raw
    /// latest detection (legacy behavior; keeps every existing test byte-
    /// identical). Set > 0 only in the AR `.tableSpace` config, where each
    /// detection is already a pose-projected table point, so smoothing the
    /// center stops boundary flicker (pond/hand zoning) without moving the tile
    /// off its physical spot. Size (w/h) is always taken from the detection.
    public var positionSmoothing: Double = 0.0

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
