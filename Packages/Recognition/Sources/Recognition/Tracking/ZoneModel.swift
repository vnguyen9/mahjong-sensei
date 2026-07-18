import Foundation
import MahjongCore

/// Where each tracked tile *lives* — the zone half of Coach Live.
///
/// `TrackStore` gives every tile a stable identity but leaves `zone` at
/// `.unresolved`; `ZoneModel` is what turns that identity into "this is my
/// rank", "that's the pond", "those three at the left edge are an opponent's
/// pung". It does so exactly the way a person reads a static table:
///
/// - **Parser-on-settled-frames as the vote source.** On every *settled* frame
///   (motion below the settle gate — mid-action frames are never zoned, so a
///   half-moved tile or an arm over the table can't corrupt zoning) it runs the
///   existing `TableSceneParser` over the raw detections and maps each parser
///   bucket back onto the track that owns that detection (via the association
///   outcome's detection→track map). One frame = one zone vote per matched
///   track; the published zone is the majority over the last
///   `zoneVoteWindow` settled frames, switching only when a challenger leads by
///   `zoneSwitchMargin` — the same hysteresis idea as face voting, so a couple
///   of bad parser frames never flip an established pond tile.
///
/// - **Static-camera calibration — the deliberate Stage-B stand-in.** The plan
///   skips the Stage-B homography; because the camera and table are fixed we
///   can instead learn image-space geometry directly and cheaply: a **hand
///   band** (the rank's y-range ± slack — a track inside it biases to `myHand`
///   even on a parser off frame) and an online **pond centroid + covariance**
///   (a Gaussian seeded with a table-centre prior so it's usable from the first
///   discard and refined as real pond tiles fold in). This is the whole reason
///   the tracker works from one seat viewpoint without a rectifying transform;
///   the upgrade path stays clean — if a homography ever lands it's a
///   coordinate transform applied to boxes *before* ingest and nothing here
///   changes.
///
/// - **Table subdivision.** `TableSceneParser` lumps the pond and every
///   opponent's melds into one undifferentiated `table` bucket (it only cares
///   about *mine* vs *the rest*). `ZoneModel` splits it: cluster the table
///   tracks, and a 3–4-tile cluster whose faces form a meld shape *and* whose
///   centroid sits outside the pond core (Mahalanobis > `pondCoreSigma`) is an
///   `opponentMeld`, its owner read off the displacement direction from the
///   pond centroid; everything else is `pond`.
///
/// Composition, not ownership: `ZoneModel` is driven by the `TableTracker`
/// facade (a later chunk), which on each settled frame calls
/// `ingestSettled(...)` *before* `TurnEngine.commitSettled(...)` so the turn
/// engine sees current zones. Zones are written through the one seam
/// `TrackStore.setZone`; user overrides (`setZone(locked:)`, surfaced here via
/// `markLocked`) are never re-voted. Discarder seats on `.pond` tiles are
/// `TurnEngine`'s to assign, so `ZoneModel` preserves whatever seat a pond
/// track already carries and only writes a seat for `opponentMeld`.
///
/// Not `Sendable` — mutable single-owner state, like `TrackStore`. No `Date()`,
/// no `UUID()` in any logic path; every timestamp is an injected
/// `TimeInterval` and every dictionary is iterated in sorted order.
public final class ZoneModel {

    private let config: TrackerConfig

    /// Per-track zone-vote ledger, keyed by identity. Iterated in `TrackID`
    /// order wherever order could matter.
    private var ledgers: [TrackID: ZoneLedger] = [:]

    /// Tracks the user pinned to a zone (`overrideZone`) — never re-voted.
    private var locked: Set<TrackID> = []

    // Hand-band calibration (rank line ± slack). Accumulated from the first
    // `calibrationFrames` settled frames that actually contain a parsed rank,
    // then frozen — the table doesn't move, so the band is a session constant.
    private var bandFramesSeen = 0
    private var bandMinY = Double.greatestFiniteMagnitude
    private var bandMaxY = -Double.greatestFiniteMagnitude
    private var bandHeights: [Double] = []
    private var handBand: ClosedRange<Double>?

    // Online pond Gaussian as running weighted sums, seeded with a
    // `calibrationFrames`-strength prior at the table centre (see
    // `seedPondPrior`). Each physical pond tile folds in exactly once (the
    // first time its track resolves to `.pond`) so the estimate is bounded and
    // deterministic rather than re-counting every frame a tile is visible.
    private var pondN = 0.0
    private var pondSx = 0.0, pondSy = 0.0
    private var pondSxx = 0.0, pondSxy = 0.0, pondSyy = 0.0
    private var foldedPond: Set<TrackID> = []

    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
        seedPondPrior()
    }

    // MARK: - Calibration read-out (diagnostics / the facade's geometry seam)

    /// True once the hand band has locked (enough settled frames with a rank).
    public var isBandCalibrated: Bool { handBand != nil }

    /// The locked hand-band y-range, or nil before calibration.
    public var handBandY: ClosedRange<Double>? { handBand }

    /// The current pond centroid in normalized-image coordinates — nil until at
    /// least one real pond tile has folded in (before that the estimate is pure
    /// prior and geometry is uninformative). `TurnEngine` reads this for its
    /// pond-entry geometry evidence; the facade passes it through.
    public var pondCentroid: (x: Double, y: Double)? {
        guard !foldedPond.isEmpty, pondN > 0 else { return nil }
        return (pondSx / pondN, pondSy / pondN)
    }

    // MARK: - The one settled-frame step

    /// Ingest one settled frame: parse it, map buckets back to tracks, cast one
    /// zone vote per matched track, resolve zones under hysteresis, and write
    /// the changes through `TrackStore.setZone`. Also advances calibration
    /// (hand band + pond Gaussian). Must be called only on settled frames and
    /// only after `TrackStore.associate` produced `outcome` for the same
    /// detections.
    public func ingestSettled(detections: [DetectedTile],
                              outcome: AssociationOutcome,
                              store: TrackStore,
                              at t: TimeInterval) {
        guard !detections.isEmpty else { return }

        let scene = TableSceneParser.parse(detections, config: config.sceneConfig)
        accumulateBand(from: scene)

        // detection UUID → owning track (births/rebirths/matches all appear).
        var trackFor: [UUID: TrackID] = [:]
        for m in outcome.matches { trackFor[m.detectionID] = m.track }

        // Each detection's parser bucket, with the table bucket subdivided into
        // pond / opponentMeld using the current pond Gaussian.
        let votes = zoneVotes(for: scene, trackFor: trackFor, store: store)

        // Resolve detection votes to the tracks that own them (a scene detection
        // that never matched a track is simply skipped), then cast in TrackID
        // order for determinism.
        let ordered = votes.compactMap { detID, decision -> (id: TrackID, decision: ZoneDecision)? in
            guard let id = trackFor[detID], !locked.contains(id) else { return nil }
            return (id, decision)
        }.sorted { $0.id.raw < $1.id.raw }
        for entry in ordered { castVote(entry.id, entry.decision, store: store, at: t) }
    }

    // MARK: - Facade correction / lifecycle support

    /// Stop voting a track's zone — the user overrode it (`overrideZone`, which
    /// also calls `TrackStore.setZone(locked: true)`). Idempotent.
    public func markLocked(_ id: TrackID) { locked.insert(id) }

    /// Drop a track's vote ledger (e.g. after `removeTrack`) so a recycled slot
    /// never inherits stale votes. Pond calibration already folded it in once;
    /// that contribution intentionally stays (the tile was really there).
    public func forget(_ id: TrackID) {
        ledgers[id] = nil
        locked.remove(id)
    }

    /// Clear per-hand zone state on a confirmed hand end. Calibration is a
    /// session constant (static camera), so the hand band is *kept*; only the
    /// per-track ledgers and the pond fold-set reset, and the pond Gaussian is
    /// re-seeded to its prior for the fresh pond.
    public func reset() {
        ledgers.removeAll()
        locked.removeAll()
        foldedPond.removeAll()
        seedPondPrior()
    }

    // MARK: - Vote derivation

    /// The zone (and, for opponent melds, the owner seat) each detection votes
    /// for this frame. `mine`→myHand/myBonus, `myMelds`→myMeld,
    /// `unresolved`→unresolved are direct; `table` is subdivided.
    private func zoneVotes(for scene: TableScene, trackFor: [UUID: TrackID],
                           store: TrackStore) -> [UUID: ZoneDecision] {
        var out: [UUID: ZoneDecision] = [:]
        for d in scene.mine { out[d.id] = ZoneDecision(d.tile.isBonus ? .myBonus : .myHand, nil) }
        for group in scene.myMelds { for d in group { out[d.id] = ZoneDecision(.myMeld, nil) } }
        for d in scene.unresolved { out[d.id] = ZoneDecision(.unresolved, nil) }
        for (id, decision) in subdivideTable(scene.table, trackFor: trackFor, store: store) {
            out[id] = decision
        }
        return out
    }

    /// Split the parser's undifferentiated `table` bucket into pond vs opponent
    /// melds. Reuses the parser's own union-find clusterer so "physical group"
    /// means exactly what it means everywhere else; the meld test uses the
    /// tracks' *voted* faces (steadier than a single frame's detection).
    private func subdivideTable(_ table: [DetectedTile], trackFor: [UUID: TrackID],
                                store: TrackStore) -> [UUID: ZoneDecision] {
        guard !table.isEmpty else { return [:] }
        var out: [UUID: ZoneDecision] = [:]
        let centroid = pondCentroid ?? (pondSx / pondN, pondSy / pondN)   // prior centre if no data yet

        for cluster in TableSceneParser.cluster(table, config: config.sceneConfig) {
            let cx = cluster.map(\.box.centerX).reduce(0, +) / Double(cluster.count)
            let cy = cluster.map(\.box.centerY).reduce(0, +) / Double(cluster.count)
            let maha2 = pondMahalanobis2(dx: cx - centroid.0, dy: cy - centroid.1)

            let faces = cluster.map { store.track(trackFor[$0.id] ?? .init(raw: -1))?.face ?? $0.tile }
            let isMeldShape = (3...4).contains(cluster.count) && MeldClassifier.classify(faces) != nil

            if isMeldShape && maha2 > config.pondCoreSigma * config.pondCoreSigma {
                let seat = seatFromDisplacement(dx: cx - centroid.0, dy: cy - centroid.1)
                for d in cluster { out[d.id] = ZoneDecision(.opponentMeld, seat) }
            } else {
                for d in cluster { out[d.id] = ZoneDecision(.pond, nil) }
            }
        }
        return out
    }

    // MARK: - Vote accumulation + hysteresis

    private func castVote(_ id: TrackID, _ decision: ZoneDecision, store: TrackStore, at t: TimeInterval) {
        var ledger = ledgers[id] ?? ZoneLedger()
        ledger.push(zoneIndex(decision.zone), cap: config.zoneVoteWindow)
        if decision.zone == .opponentMeld { ledger.lastOpponentSeat = decision.seat }

        // Static-camera hand-band prior: a track inside the band that the parser
        // *didn't* call mine this frame gets a standing nudge back toward
        // myHand — the "off frame" insurance. Applied as an effective-tally
        // bonus at decision time, never stored in the ring (so it stays a fixed
        // bias, not something that accumulates).
        var effective = ledger.tallies
        if let band = handBand, decision.zone != .myHand, decision.zone != .myBonus,
           decision.zone != .myMeld, let box = store.track(id)?.box, band.contains(box.centerY) {
            effective[zoneIndex(.myHand)] += config.zonePriorWeight
        }

        let resolved = resolve(effective: effective, current: ledger.resolved)
        ledger.resolved = resolved
        ledgers[id] = ledger

        write(id, zone: resolved, opponentSeat: ledger.lastOpponentSeat, store: store)
        foldPondIfNeeded(id, zone: resolved, store: store)
    }

    /// Argmax of the effective tallies, but a track that already has a resolved
    /// zone only switches when a challenger leads the incumbent by
    /// `zoneSwitchMargin` — the anti-flap rule. A brand-new track (no resolved
    /// zone yet) adopts its first decision immediately.
    private func resolve(effective: [Double], current: TileZone?) -> TileZone {
        var bestIdx = 0, best = -Double.greatestFiniteMagnitude
        for i in orderedZones.indices where effective[i] > best { best = effective[i]; bestIdx = i }
        let challenger = orderedZones[bestIdx]
        guard let current else { return challenger }
        if challenger == current { return current }
        let lead = effective[bestIdx] - effective[zoneIndex(current)]
        return lead >= Double(config.zoneSwitchMargin) ? challenger : current
    }

    /// Write a resolved zone through the store, but only on a real change and
    /// never for a locked track. Seat handling honors the ownership split:
    /// `opponentMeld` carries the geometry-derived owner; every other zone
    /// preserves whatever seat the track already has (so `TurnEngine`'s pond
    /// discarder attribution isn't clobbered frame-to-frame).
    private func write(_ id: TrackID, zone: TileZone, opponentSeat: RelativeSeat?, store: TrackStore) {
        guard let current = store.track(id) else { return }
        let seat: RelativeSeat? = zone == .opponentMeld ? opponentSeat : current.seat
        if current.zone == zone && current.seat == seat { return }
        store.setZone(id, to: zone, seat: seat, locked: false)
    }

    // MARK: - Calibration maintenance

    private func accumulateBand(from scene: TableScene) {
        guard handBand == nil else { return }               // frozen once locked
        let rank = scene.mine.filter { !$0.tile.isBonus }
        guard rank.count >= config.sceneConfig.minHandCount else { return }
        for d in rank {
            bandMinY = min(bandMinY, d.box.centerY)
            bandMaxY = max(bandMaxY, d.box.centerY)
            bandHeights.append(d.box.height)
        }
        bandFramesSeen += 1
        if bandFramesSeen >= config.calibrationFrames {
            let slack = config.handBandSlackFactor * TableSceneParser.median(bandHeights)
            handBand = (bandMinY - slack)...(bandMaxY + slack)
        }
    }

    /// Fold a track into the pond Gaussian the first time it resolves to pond.
    private func foldPondIfNeeded(_ id: TrackID, zone: TileZone, store: TrackStore) {
        guard zone == .pond, !foldedPond.contains(id), let box = store.track(id)?.box else { return }
        foldedPond.insert(id)
        let x = box.centerX, y = box.centerY
        pondN += 1; pondSx += x; pondSy += y
        pondSxx += x * x; pondSxy += x * y; pondSyy += y * y
    }

    private func seedPondPrior() {
        let w0 = Double(config.calibrationFrames), s = config.pondInitialSigma
        pondN = w0
        pondSx = w0 * 0.5; pondSy = w0 * 0.5
        pondSxx = w0 * (0.25 + s * s); pondSxy = w0 * 0.25; pondSyy = w0 * (0.25 + s * s)
        foldedPond.removeAll()
    }

    /// Squared Mahalanobis distance of a displacement under the current pond
    /// covariance. The prior seed guarantees a positive-definite covariance, so
    /// the 2×2 inverse is always well-defined.
    private func pondMahalanobis2(dx: Double, dy: Double) -> Double {
        let mx = pondSx / pondN, my = pondSy / pondN
        let a = pondSxx / pondN - mx * mx        // var(x)
        let b = pondSxy / pondN - mx * my        // cov(x,y)
        let c = pondSyy / pondN - my * my        // var(y)
        let det = a * c - b * b
        guard det > 0 else { return (dx * dx + dy * dy) / max(a, c, 1e-9) }
        return (c * dx * dx - 2 * b * dx * dy + a * dy * dy) / det
    }

    // MARK: - Zone index helpers (fixed order → deterministic argmax/tie-breaks)

    private let orderedZones: [TileZone] = [.myHand, .myBonus, .myMeld, .pond, .opponentMeld, .unresolved]
    private func zoneIndex(_ z: TileZone) -> Int {
        switch z {
        case .myHand: return 0
        case .myBonus: return 1
        case .myMeld: return 2
        case .pond: return 3
        case .opponentMeld: return 4
        case .unresolved: return 5
        }
    }

    private struct ZoneDecision {
        var zone: TileZone
        var seat: RelativeSeat?
        init(_ zone: TileZone, _ seat: RelativeSeat?) { self.zone = zone; self.seat = seat }
    }

    private struct ZoneLedger {
        var tallies = [Double](repeating: 0, count: 6)
        var ring: [Int] = []
        var resolved: TileZone?
        var lastOpponentSeat: RelativeSeat?

        mutating func push(_ idx: Int, cap: Int) {
            ring.append(idx)
            tallies[idx] += 1
            if ring.count > cap { tallies[ring.removeFirst()] -= 1 }
        }
    }
}

// MARK: - Shared geometry (module-internal; used by ZoneModel + TurnEngine)

/// Read an opponent's seat off the displacement of a table cluster (or a pond
/// tile) from the pond centroid, in the frame convention the whole tracker
/// uses (top-left origin, so y grows downward toward me): the dominant axis
/// decides side, its sign the seat. `left`/`right` for a mostly-horizontal
/// displacement, `across`/`me` for a mostly-vertical one.
func seatFromDisplacement(dx: Double, dy: Double) -> RelativeSeat {
    if abs(dx) > abs(dy) { return dx < 0 ? .left : .right }
    return dy < 0 ? .across : .me
}
