import Foundation
import MahjongCore

/// The identity core of Coach Live: raw detections in, a stable set of tracked
/// tiles out. `TrackStore` is ByteTrack adapted to a near-static table — the
/// camera and the tiles don't move except during a discrete action, and we
/// suspend *committing* during those (that's `TurnEngine`, a later chunk), so
/// association here is mostly IoU bookkeeping with low-confidence detections
/// doing the flicker-absorbing work.
///
/// What this chunk owns and nothing else touches:
/// - **TrackID minting** — monotonic `Int`s, never reused within a session
///   (survives `reset()` across hands), so a replayed stream produces
///   byte-identical ids.
/// - **Two-band greedy association** (§3.1): a tight high band births and
///   sustains, a loose low band only *sustains* — the single trick that keeps
///   a pond tile the detector only catches every third frame as one continuous
///   identity.
/// - **Lifecycle** (§3.1): tentative→live admission, motion-extended missing
///   grace, retirement into a rebirth ring.
/// - **Confidence-weighted face voting with hysteresis** (§3.2): a 7s/8s
///   flicker never churns the published face; a **pin wins forever**.
/// - **Rebirth** (§3.5): a nudged / re-detected tile resurrects its old track
///   instead of birthing a new one — the mechanism that kills double-counting.
///
/// What it deliberately does *not* do: zones (that's `ZoneModel`) and events
/// (that's `TurnEngine`). It leaves `zone` at whatever it was last set to
/// (`.unresolved` for auto-born tracks) and never emits a `GameEvent`. The
/// `TableTracker` facade composes those chunks around this one, reading
/// `AssociationOutcome` to drive zone votes and settle-diff.
///
/// Not `Sendable` — it's mutable, single-owner state (the MainActor app loop
/// or the CLI replay), exactly like `TableTracker`. Every timestamp is an
/// injected `TimeInterval`; no `Date()`, no `UUID()` in any logic path.
public final class TrackStore {

    private let config: TrackerConfig

    /// Live association set, keyed for O(1) lookup. Iterated in `TrackID`
    /// order everywhere it matters (see `orderedLiveTracks`) so output is
    /// deterministic regardless of dictionary hashing.
    private var tracksByID: [TrackID: Track] = [:]

    /// Retired tracks kept for `retiredRetention` so a later rebirth can
    /// resurrect their identity (votes, pin, zone). Dropped once they age out.
    private var retiredRing: [Track] = []

    /// Ghost-suppression list written by `removeTrack`: a box the user deleted
    /// is barred from immediately birthing a replacement track (`§5`).
    private var suppressions: [Suppression] = []

    /// Monotonic id source — bumped on every birth, never decremented, never
    /// reset (ids are unique for the whole session, across hands).
    private var nextRawID = 0

    /// Last time motion crossed `motionActive`. `missing` grace stretches from
    /// `missingGraceSettled` to `missingGraceMotion` while this is recent
    /// (`motionCooldown`) — an arm occluding a tile for several seconds during
    /// an action must not retire it.
    private var lastMotionActiveAt: TimeInterval = -.greatestFiniteMagnitude

    /// The clock as of the most recent `associate`. `removeTrack`/
    /// `insertManualTrack` carry no timestamp in the facade's API (§2.5), so
    /// they anchor their suppression window / creation time to this.
    private var now: TimeInterval = 0

    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
    }

    // MARK: - Published projection

    /// Every non-retired track (tentative + live + missing) as read-only
    /// `TrackedTile`s, ordered by `TrackID` for deterministic consumption.
    /// Retired tracks are intentionally absent — they exist only to be
    /// resurrected by rebirth, never published.
    public var tracks: [TrackedTile] {
        orderedLiveTracks.map { $0.project() }
    }

    /// One track by id, if it's currently live/tentative/missing (not retired).
    public func track(_ id: TrackID) -> TrackedTile? {
        tracksByID[id]?.project()
    }

    /// Live counts for diagnostics (`TableTracker` folds these into its
    /// `TrackerDiagnostics`). `retired` counts the rebirth ring.
    public var counts: Counts {
        var c = Counts()
        for t in tracksByID.values {
            switch t.state {
            case .tentative: c.tentative += 1
            case .live:      c.live += 1
            case .missing:   c.missing += 1
            case .retired:   break   // never stored in tracksByID
            }
        }
        c.retired = retiredRing.count
        return c
    }

    public struct Counts: Sendable, Hashable {
        public var tentative = 0, live = 0, missing = 0, retired = 0
        public init() {}
    }

    // MARK: - The one association step

    /// Ingest one frame of detections. Runs every tick — including *during*
    /// motion, where tracks survive and votes accumulate but nothing commits
    /// (commit is `TurnEngine`'s settle-diff, a later chunk). Returns an
    /// `AssociationOutcome` mapping detections→tracks plus the births / rebirths
    /// / promotions / retirements this frame, which the facade needs to drive
    /// zone votes and event derivation.
    ///
    /// `visibleRegion` (Lane B chunk E — ROI-cropped AR inference): `nil`
    /// (default) is the original full-view contract, byte-identical to
    /// before this parameter existed. Non-nil ⇒ this frame's detections only
    /// covered PART of the table (a cropped recognize pass) — a track whose
    /// box doesn't intersect `visibleRegion` wasn't actually looked at this
    /// frame, so it must not accrue a "missed" frame for it (see the miss
    /// step below); a track that DOES intersect `visibleRegion` but still
    /// wasn't matched genuinely went unseen within the region we checked, so
    /// it misses/retires exactly as it would under a full-view ingest.
    @discardableResult
    public func associate(_ detections: [DetectedTile], at t: TimeInterval,
                          motion: MotionSample? = nil, visibleRegion: TileBoundingBox? = nil) -> AssociationOutcome {
        now = t
        if let level = motion?.level, level >= config.motionActive { lastMotionActiveAt = t }
        expireRetired(at: t)
        expireSuppressions(at: t)

        // Candidate tracks for both matching passes = everything not retired.
        // The plan phrases pass 1 as "live+missing", but tentative tracks must
        // be matchable too or they could never accrue the `confirmFrames` hits
        // that promote them (a fresh detection next to a tentative track would
        // otherwise birth a *second* track). Retired tracks re-enter only via
        // rebirth (step 4), never these passes.
        let preExisting = orderedLiveTracks.map(\.id)

        var matched: Set<TrackID> = []
        var unmatchedDet = Set(detections.indices)
        var outcome = AssociationOutcome()

        // Pass 1 (high band): the confident detections claim their tracks first.
        let highBand = detections.indices.filter { detections[$0].confidence >= config.highConfidence }
        greedyMatch(highBand, in: detections, candidates: preExisting, band: .high,
                    matched: &matched, unmatchedDet: &unmatchedDet, outcome: &outcome, at: t)

        // Pass 2 (low band): the leftover weak detections (below `highConfidence`)
        // sustain whatever tracks pass 1 didn't claim. This is the ByteTrack
        // trick — a 0.35 pond tile keeps its identity instead of dropping out.
        // Inputs are already floored by the detector's own threshold (~0.30),
        // so no extra low-band floor is needed here.
        let lowBand = unmatchedDet.filter { detections[$0].confidence < config.highConfidence }.sorted()
        greedyMatch(lowBand, in: detections, candidates: preExisting, band: .low,
                    matched: &matched, unmatchedDet: &unmatchedDet, outcome: &outcome, at: t)

        // Step 3 — misses, run *before* births. A track that failed to match
        // this frame ages to `missing` here, which is precisely what makes it
        // eligible for rebirth in the very same frame: a nudged tile jumps
        // beyond the tight association gate (its old track misses → missing),
        // then the unmatched detection at the new spot resurrects that track
        // instead of birthing a second one. Ordering miss-before-birth is what
        // closes the one-frame double-count window.
        //
        // `visibleRegion` gate (chunk E): a track outside the region this
        // frame's (cropped) detections actually covered simply never had a
        // chance to match — skip it entirely rather than call `missTrack`,
        // so it accrues no miss/no retirement progress from a frame that
        // wasn't looking at it in the first place.
        for id in preExisting where !matched.contains(id) {
            guard let track = tracksByID[id] else { continue }
            if let visibleRegion, !boxesIntersect(track.box, visibleRegion) { continue }
            missTrack(track, at: t, outcome: &outcome)
        }

        // Step 4 — births. Only detections that stayed unmatched and clear
        // `birthConfidence` may create identity, and each tries **rebirth
        // first**: resurrecting a nearby same-face missing/retired track (the
        // nudged / re-detected tile) rather than double-counting it.
        for i in unmatchedDet.sorted() {
            let det = detections[i]
            guard det.confidence >= config.birthConfidence else { continue }
            if let reborn = rebirth(for: det, matchedThisFrame: matched, at: t) {
                applyMatch(reborn, det, band: bandFor(det), outcome: &outcome, at: t)
                matched.insert(reborn.id)
                outcome.reborn.append(reborn.id)
                outcome.matches.append(.init(detectionID: det.id, track: reborn.id, band: bandFor(det)))
                continue
            }
            if isSuppressed(det.box) { continue }   // a just-removed ghost — don't let it pop back
            let track = birth(det, at: t)
            matched.insert(track.id)
            outcome.born.append(track.id)
            outcome.matches.append(.init(detectionID: det.id, track: track.id, band: bandFor(det)))
        }

        // Tentative admission window: a track that hasn't reached `confirmFrames`
        // within `confirmWindow` ingests never confirms (the M-frames gate).
        for id in preExisting {
            guard let track = tracksByID[id], track.state == .tentative else { continue }
            track.ingestsSinceBirth += 1
            if track.ingestsSinceBirth >= config.confirmWindow && track.hits < config.confirmFrames {
                tracksByID[track.id] = nil   // silent death — never emitted an event
            }
        }

        return outcome
    }

    // MARK: - Corrections (facade passthroughs, §5)

    /// Pin a face: it wins forever, voting is bypassed (votes still accumulate
    /// internally for diagnostics), and because pins live on the track object
    /// they survive `missing`→rebirth untouched.
    public func pin(_ id: TrackID, as face: Tile) {
        guard let track = tracksByID[id] ?? retiredRing.first(where: { $0.id == id }) else { return }
        track.isPinned = true
        track.pinnedFace = face
        track.recomputeFace(margin: config.voteHysteresisMargin)
    }

    /// Set a track's zone/seat, optionally locking it against future zone
    /// votes. `ZoneModel` calls this unlocked with each majority decision; the
    /// `overrideZone` correction calls it locked. Zone lives on the track so
    /// it, too, rides through rebirth.
    public func setZone(_ id: TrackID, to zone: TileZone, seat: RelativeSeat?, locked: Bool) {
        guard let track = tracksByID[id] else { return }
        track.zone = zone
        track.seat = seat
        if locked { track.zoneLocked = true }
    }

    /// Create a `live`, pinned, zone-locked manual track for a tile the
    /// detector never caught (`insertMissedTile`, §5). Never auto-retired by
    /// misses; detections may still associate to it to keep its box honest.
    @discardableResult
    public func insertManualTrack(face: Tile, zone: TileZone, seat: RelativeSeat?,
                                  box: TileBoundingBox, at t: TimeInterval) -> TrackID {
        now = max(now, t)
        let track = Track(id: mintID(), face: face, box: box, zone: zone, seat: seat,
                          state: .live, at: t)
        track.isPinned = true
        track.pinnedFace = face
        track.zoneLocked = true
        track.isManual = true
        track.confirmedOnce = true
        tracksByID[track.id] = track
        return track.id
    }

    /// Recreates a track for persistence restore (plan A6,
    /// `TableTracker.restore`) — mirrors `insertManualTrack`'s pinned/
    /// zone-locked/manual/confirmed `.live` track, but PRESERVES the given
    /// `id` (a restored `GameEvent`'s `track` reference must still resolve —
    /// `insertManualTrack`'s always-fresh id would break that) instead of
    /// minting one, and carries over the original `firstSeen`/`lastSeen`/
    /// `observationCount` rather than stamping them at `t`. Fast-forwards
    /// `nextRawID` past `id.raw` so a track born after restore can never
    /// collide with a restored id, regardless of what order the caller
    /// restores tiles in. Meant to be called only on a fresh store (see
    /// `TableTracker.restore`'s precondition) — calling it with an id that
    /// collides with an already-live track silently overwrites that track.
    @discardableResult
    public func restoreTrack(id: TrackID, face: Tile, box: TileBoundingBox, zone: TileZone,
                             seat: RelativeSeat?, firstSeen: TimeInterval, lastSeen: TimeInterval,
                             observationCount: Int, at t: TimeInterval) -> TrackID {
        now = max(now, t)
        let track = Track(id: id, face: face, box: box, zone: zone, seat: seat, state: .live, at: firstSeen)
        track.lastSeen = lastSeen
        track.observationCount = observationCount
        track.isPinned = true
        track.pinnedFace = face
        track.zoneLocked = true
        track.isManual = true
        track.confirmedOnce = true
        tracksByID[id] = track
        if id.raw >= nextRawID { nextRawID = id.raw + 1 }
        return id
    }

    /// Hard-delete a ghost/double detection and suppress its box for
    /// `suppressionWindow` so the same spurious detection can't immediately
    /// re-birth a replacement (§5).
    public func removeTrack(_ id: TrackID) {
        let box = tracksByID[id]?.box ?? retiredRing.first(where: { $0.id == id })?.box
        tracksByID[id] = nil
        retiredRing.removeAll { $0.id == id }
        if let box { suppressions.append(Suppression(box: box, until: now + config.suppressionWindow)) }
    }

    /// Drop every track (a confirmed hand end / table clear). The id counter is
    /// intentionally *not* reset — ids stay unique for the whole session so a
    /// new hand's tiles can never collide with the previous hand's event links.
    public func reset() {
        tracksByID.removeAll()
        retiredRing.removeAll()
        suppressions.removeAll()
    }

    // MARK: - Matching

    /// Greedily assign a set of detections to candidate tracks. Pairs are
    /// gated by IoU **or** center distance (pond tiles are ~0.03 wide — jitter
    /// kills IoU while centers barely move), then consumed strongest-first.
    ///
    /// Ordering is a strict total order — `(IoU desc, centerDist asc, TrackID
    /// asc, detIndex asc)` — so it's fully deterministic (the plan's "descending
    /// IoU, deterministic tie-break by TrackID"). Center distance breaks ties
    /// *before* TrackID so that among the zero-IoU center-gate matches the
    /// nearer tile wins rather than merely the lower id — correctness for dense
    /// ponds, with TrackID as the final deterministic backstop. Hungarian is
    /// unnecessary at this density and would hurt reproducibility.
    private func greedyMatch(_ detIndices: [Int], in detections: [DetectedTile],
                             candidates: [TrackID], band: AssociationOutcome.Band,
                             matched: inout Set<TrackID>, unmatchedDet: inout Set<Int>,
                             outcome: inout AssociationOutcome, at t: TimeInterval) {
        guard !detIndices.isEmpty else { return }

        struct Pair { var det: Int; var track: TrackID; var iou: Double; var dist: Double }
        var pairs: [Pair] = []
        for di in detIndices {
            let dbox = detections[di].box
            let gate = config.centerGateFactor * diagonal(dbox)
            for id in candidates where !matched.contains(id) {
                guard let track = tracksByID[id] else { continue }
                let iou = iou(dbox, track.box)
                let dist = centerDistance(dbox, track.box)
                guard iou >= config.iouGate || dist <= gate else { continue }
                pairs.append(Pair(det: di, track: id, iou: iou, dist: dist))
            }
        }
        pairs.sort {
            if $0.iou != $1.iou { return $0.iou > $1.iou }
            if $0.dist != $1.dist { return $0.dist < $1.dist }
            if $0.track != $1.track { return $0.track < $1.track }
            return $0.det < $1.det
        }
        for pair in pairs {
            guard unmatchedDet.contains(pair.det), !matched.contains(pair.track),
                  let track = tracksByID[pair.track] else { continue }
            let det = detections[pair.det]
            applyMatch(track, det, band: band, outcome: &outcome, at: t)
            matched.insert(pair.track)
            unmatchedDet.remove(pair.det)
            outcome.matches.append(.init(detectionID: det.id, track: pair.track, band: band))
        }
    }

    /// Fold one matched detection into a track: vote, re-decide the face,
    /// refresh the box, recover from `missing`, and advance a tentative track
    /// toward promotion. Applies to both bands — only the vote *weight*
    /// differs (low-band votes count half, `lowBandVoteWeight`).
    private func applyMatch(_ track: Track, _ det: DetectedTile, band: AssociationOutcome.Band,
                            outcome: inout AssociationOutcome, at t: TimeInterval) {
        let weight = det.confidence * (band == .high ? 1.0 : config.lowBandVoteWeight)
        track.addVote(det.tile.classIndex, weight, cap: config.voteWindow)
        track.recomputeFace(margin: config.voteHysteresisMargin)
        // Published box: raw detection (legacy), or an EMA of the CENTER toward
        // the detection when position smoothing is on (AR table-space). Size is
        // always the detection's; the raw box still feeds `boxHistory`.
        let f = config.positionSmoothing
        if f > 0 {
            let cx = track.box.centerX * f + det.box.centerX * (1 - f)
            let cy = track.box.centerY * f + det.box.centerY * (1 - f)
            track.box = TileBoundingBox(x: cx - det.box.width / 2, y: cy - det.box.height / 2,
                                        width: det.box.width, height: det.box.height)
        } else {
            track.box = det.box
        }
        track.pushBox(det.box, cap: config.boxHistoryCap)
        track.lastSeen = t
        track.observationCount += 1
        track.consecutiveMisses = 0

        if track.state == .missing {          // re-associated within the gate → alive again
            track.state = .live
            track.missingSince = nil
        }
        if track.state == .tentative {
            track.hits += 1
            if track.hits >= config.confirmFrames {
                track.state = .live
                track.confirmedOnce = true
                outcome.promoted.append(track.id)
            }
        }
    }

    private func missTrack(_ track: Track, at t: TimeInterval, outcome: inout AssociationOutcome) {
        if track.isManual { return }   // manual inserts persist until an explicit removeTrack
        switch track.state {
        case .tentative:
            // Never confirmed → die silently after 2 misses, no retirement,
            // no rebirth eligibility (it was noise, not a tile we ever trusted).
            track.consecutiveMisses += 1
            if track.consecutiveMisses >= 2 { tracksByID[track.id] = nil }
        case .live:
            track.state = .missing
            track.missingSince = t
        case .missing:
            let grace = recentMotion(at: t) ? config.missingGraceMotion : config.missingGraceSettled
            if let since = track.missingSince, t - since > grace {
                track.state = .retired
                track.retiredAt = t
                retiredRing.append(track)
                tracksByID[track.id] = nil
                outcome.retired.append(track.id)
            }
        case .retired:
            break
        }
    }

    // MARK: - Birth & rebirth (§3.5)

    private func birth(_ det: DetectedTile, at t: TimeInterval) -> Track {
        let track = Track(id: mintID(), face: det.tile, box: det.box,
                          zone: .unresolved, seat: nil, state: .tentative, at: t)
        track.addVote(det.tile.classIndex,
                      det.confidence * (det.confidence >= config.highConfidence ? 1.0 : config.lowBandVoteWeight),
                      cap: config.voteWindow)
        track.pushBox(det.box, cap: config.boxHistoryCap)
        track.hits = 1                      // the birth frame is its first hit
        tracksByID[track.id] = track
        return track
    }

    /// Search missing + retired tracks for the same voted face within
    /// `rebirthRadius` tile-diagonals and `rebirthWindow` seconds. A hit
    /// resurrects that exact track (same id, votes, pin, zone) with no event —
    /// this is what stops a nudged pond tile, a tile shoved by a landing
    /// discard, or a tile re-found after occlusion from double-counting.
    ///
    /// The rebirth radius (2.5 diagonals) is deliberately far looser than the
    /// per-frame association gate (0.75) — association stays tight to avoid
    /// swapping neighbors frame-to-frame, while rebirth reaches out to recover
    /// a tile that jumped.
    private func rebirth(for det: DetectedTile, matchedThisFrame: Set<TrackID>,
                         at t: TimeInterval) -> Track? {
        let radius = config.rebirthRadius * diagonal(det.box)
        var pool: [Track] = []
        for track in tracksByID.values where track.state == .missing && !matchedThisFrame.contains(track.id) {
            pool.append(track)
        }
        pool.append(contentsOf: retiredRing)

        let candidates = pool.filter { track in
            track.publishedFace == det.tile
                && t - track.lastSeen <= config.rebirthWindow
                && centerDistance(det.box, track.box) <= radius
        }
        // Nearest center wins; TrackID breaks any exact tie deterministically.
        return candidates.min {
            let da = centerDistance(det.box, $0.box), db = centerDistance(det.box, $1.box)
            if da != db { return da < db }
            return $0.id < $1.id
        }.map { resurrect($0, at: t) }
    }

    private func resurrect(_ track: Track, at t: TimeInterval) -> Track {
        retiredRing.removeAll { $0.id == track.id }
        track.state = .live               // rebirth-pool tracks were all once live
        track.missingSince = nil
        track.retiredAt = nil
        track.consecutiveMisses = 0
        tracksByID[track.id] = track
        return track
    }

    // MARK: - Housekeeping

    private func expireRetired(at t: TimeInterval) {
        retiredRing.removeAll { track in
            (track.retiredAt.map { t - $0 > config.retiredRetention } ?? true)
        }
    }

    private func expireSuppressions(at t: TimeInterval) {
        suppressions.removeAll { $0.until <= t }
    }

    private func isSuppressed(_ box: TileBoundingBox) -> Bool {
        let radius = config.rebirthRadius * diagonal(box)
        return suppressions.contains { centerDistance(box, $0.box) <= radius }
    }

    private func recentMotion(at t: TimeInterval) -> Bool {
        t - lastMotionActiveAt <= config.motionCooldown
    }

    private func bandFor(_ det: DetectedTile) -> AssociationOutcome.Band {
        det.confidence >= config.highConfidence ? .high : .low
    }

    private func mintID() -> TrackID {
        defer { nextRawID += 1 }
        return TrackID(raw: nextRawID)
    }

    private var orderedLiveTracks: [Track] {
        tracksByID.values.sorted { $0.id < $1.id }
    }

    private struct Suppression { var box: TileBoundingBox; var until: TimeInterval }
}

// MARK: - Association outcome

/// What one `associate` call did, beyond mutating the track set — the seam the
/// `TableTracker` facade reads to feed zone votes (which detection landed on
/// which track) and to know the identity churn (births/rebirths/promotions/
/// retirements) that `TurnEngine` and `HandBoundaryDetector` react to.
public struct AssociationOutcome: Sendable, Hashable {
    public enum Band: Sendable, Hashable { case high, low }

    /// One detection→track assignment this frame.
    public struct Match: Sendable, Hashable {
        public var detectionID: UUID
        public var track: TrackID
        public var band: Band
        public init(detectionID: UUID, track: TrackID, band: Band) {
            self.detectionID = detectionID; self.track = track; self.band = band
        }
    }

    /// Every assignment, high and low band (order not significant).
    public var matches: [Match] = []
    /// Brand-new tentative tracks created this frame.
    public var born: [TrackID] = []
    /// Tracks resurrected from missing/retired by rebirth this frame.
    public var reborn: [TrackID] = []
    /// Tracks that crossed tentative→live this frame.
    public var promoted: [TrackID] = []
    /// Tracks that aged into `retired` this frame.
    public var retired: [TrackID] = []

    public init() {}
}

// MARK: - Internal track object

/// The mutable per-track bookkeeping the public `TrackedTile` projection hides:
/// the weighted vote ring and totals, the box-history ring, the missing/retired
/// timestamps, and the tentative-admission counters. One reference type per
/// physical tile — reused (never rebuilt) across missing→rebirth so pins,
/// votes, and zone all ride through unchanged.
private final class Track {
    let id: TrackID

    // Face voting — a ring of (classIndex, weight) plus the running per-class
    // totals it maintains, so argmax and the hysteresis check are O(42) not O(ring).
    private(set) var voteRing: [(idx: Int, weight: Double)] = []
    private(set) var totals = [Double](repeating: 0, count: Tile.classCount)
    var publishedFace: Tile
    var isPinned = false
    var pinnedFace: Tile?

    var box: TileBoundingBox
    private(set) var boxHistory: [TileBoundingBox] = []

    var zone: TileZone
    var seat: RelativeSeat?
    var zoneLocked = false

    var state: TrackedTile.Life
    var firstSeen: TimeInterval
    var lastSeen: TimeInterval
    var missingSince: TimeInterval?
    var retiredAt: TimeInterval?
    var observationCount = 1
    var isManual = false

    // Lifecycle counters.
    var confirmedOnce = false
    var hits = 0
    var consecutiveMisses = 0
    var ingestsSinceBirth = 0

    init(id: TrackID, face: Tile, box: TileBoundingBox, zone: TileZone,
         seat: RelativeSeat?, state: TrackedTile.Life, at t: TimeInterval) {
        self.id = id
        self.publishedFace = face
        self.box = box
        self.zone = zone
        self.seat = seat
        self.state = state
        self.firstSeen = t
        self.lastSeen = t
    }

    func addVote(_ idx: Int, _ weight: Double, cap: Int) {
        voteRing.append((idx, weight))
        totals[idx] += weight
        if voteRing.count > cap {
            let old = voteRing.removeFirst()
            totals[old.idx] -= old.weight
        }
    }

    /// Re-decide the published face. A pin short-circuits (wins forever). Else
    /// argmax of the totals *challenges* the incumbent and only unseats it by
    /// `margin` weighted votes — a 50/50 flicker never churns the published
    /// state or the histogram.
    func recomputeFace(margin: Double) {
        if isPinned, let pinnedFace {
            publishedFace = pinnedFace
            return
        }
        var bestIdx = 0
        var best = -Double.greatestFiniteMagnitude
        for i in 0..<Tile.classCount where totals[i] > best {
            best = totals[i]; bestIdx = i
        }
        let challenger = Tile(classIndex: bestIdx)!
        if challenger == publishedFace { return }
        if totals[bestIdx] - totals[publishedFace.classIndex] >= margin {
            publishedFace = challenger
        }
    }

    /// Winning face's share of all weighted votes, 0…1 — the tracker's
    /// `faceConfidence`. Always 1 while pinned (voting is bypassed).
    var faceConfidence: Double {
        if isPinned { return 1.0 }
        let sum = totals.reduce(0, +)
        guard sum > 0 else { return 1.0 }
        return totals[publishedFace.classIndex] / sum
    }

    func pushBox(_ b: TileBoundingBox, cap: Int) {
        boxHistory.append(b)
        if boxHistory.count > cap { boxHistory.removeFirst() }
    }

    func project() -> TrackedTile {
        TrackedTile(id: id, face: publishedFace, faceConfidence: faceConfidence,
                    isPinned: isPinned, box: box, zone: zone, seat: seat, meldGroup: nil,
                    state: state, firstSeen: firstSeen, lastSeen: lastSeen,
                    observationCount: observationCount, isManual: isManual)
    }
}

// MARK: - Geometry (no IoU/diagonal helpers exist on TileBoundingBox)

/// Intersection-over-union of two normalized boxes; 0 when they don't overlap.
private func iou(_ a: TileBoundingBox, _ b: TileBoundingBox) -> Double {
    let ix = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
    let iy = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
    let inter = ix * iy
    let union = a.width * a.height + b.width * b.height - inter
    return union > 0 ? inter / union : 0
}

/// Whether two normalized boxes overlap at all — unlike `iou`, the
/// `visibleRegion` gate (`associate`'s miss step) only needs a yes/no test,
/// not the overlap fraction.
private func boxesIntersect(_ a: TileBoundingBox, _ b: TileBoundingBox) -> Bool {
    a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
}

private func centerDistance(_ a: TileBoundingBox, _ b: TileBoundingBox) -> Double {
    let dx = a.centerX - b.centerX, dy = a.centerY - b.centerY
    return (dx * dx + dy * dy).squareRoot()
}

/// The box's diagonal — the natural length scale for the center gate and the
/// rebirth radius (a tile ~0.03 wide has a diagonal ~0.05, so the gates track
/// tile size rather than a fixed normalized distance).
private func diagonal(_ b: TileBoundingBox) -> Double {
    (b.width * b.width + b.height * b.height).squareRoot()
}
