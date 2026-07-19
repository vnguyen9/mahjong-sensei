import Foundation
import MahjongCore

/// The event half of Coach Live: it turns the stream of tracked tiles into the
/// game's story — who discarded what, who claimed a meld, when I drew and
/// discarded — and keeps the turn pointer.
///
/// The one binding rule is **settle-diff**: during motion the tracker keeps
/// ingesting (tracks survive, votes accumulate) but *commits nothing*. Events
/// are derived by diffing the last committed *settled* snapshot against the
/// current one, once motion has stayed calm for `settleDelay`. This single
/// mechanism is what makes occlusion chaos, half-moved tiles, and hands waving
/// over the table harmless — a mid-action frame is never a snapshot, so the
/// 13→11→14 wobble of a draw-under-an-arm simply never happens in the diff.
/// `TurnEngine` therefore only ever runs on settled frames, and only after
/// `ZoneModel` has written this frame's zones (it reads zones to find the
/// pond/meld/hand tiles).
///
/// **Attribution** is weighted evidence, softmax-normalized into a confidence:
/// a turn-order prior (weight `attributionPriorWeight`), the motion burst's
/// dominant region (`attributionMotionWeight`), and pond-entry geometry
/// relative to the pond centroid (`attributionGeometryWeight`). Below
/// `attributionConfidenceFloor` the event is flagged `.uncertainAttribution`
/// (amber, tappable to fix). Because opponents' *draws* are invisible, the
/// turn pointer will drift; the machine is self-correcting rather than brittle:
/// when motion+geometry evidence disagrees with the prior by at least
/// `resyncMargin`, it trusts the evidence, re-anchors the rotation from it, and
/// carries on (evidence-over-prior). Every accepted event is a fresh anchor.
///
/// Event ids are monotonic `Int`s minted here — `TurnEngine` owns the single
/// session counter, and the facade mints its own boundary events
/// (`handStarted`/`handEnded`/…) through `mintEventID()` so the whole log stays
/// monotonic without a second counter to drift.
///
/// Scope note (chunk 5, updated by chunk 6): the events this engine emits
/// carry attribution and face-uncertainty flags but *not* wait-impact
/// (`.reducesMyWaits`) — that is the facade's injected annotator's job (a
/// different package). Meld *kind* is read via `MeldClassifier.classify`
/// (the one shared shape-test implementation — this engine used to carry its
/// own private near-duplicate; see `MeldClassifier.swift`'s doc for why that
/// was consolidated). Not `Sendable`; no `Date()`/`UUID()` in any logic path.
public final class TurnEngine {

    private let config: TrackerConfig

    /// Monotonic event-id source. Never reset across hands (ids are unique for
    /// the whole session so cross-hand event links can't collide), so it lives
    /// outside `reset()`.
    private var nextID = 0

    /// Whose turn the machine believes it is; nil until the first anchoring
    /// event (first settled discard/draw).
    public private(set) var currentTurn: RelativeSeat?

    /// The last committed settled snapshot; nil before the first commit (which
    /// only establishes the baseline and emits nothing).
    private var baseline: Snapshot?

    /// The most recent discard, kept so a following meld claim can link its
    /// `claimedTile`/`claimedFrom`. Cleared when consumed by a claim.
    private var lastDiscard: (track: TrackID, face: Tile, seat: RelativeSeat)?

    // My-hand membership tracked by *identity*, not by count: `committedHand`
    // is the set of hand-tile tracks currently accepted as mine. Identity
    // (rather than a raw 13/14 count) is what survives settled-frame detector
    // dropout — a momentarily-missing hand tile stays committed (nothing new
    // links a pond tile to it), so it neither drops the "count" nor re-appears
    // as a phantom draw. A draw is a *new* committed tile that persists for
    // `handCountSustain`; a discard is a committed tile whose face re-appears in
    // the pond.
    private var committedHand: Set<TrackID> = []
    private var handRoseAt: TimeInterval?
    private var drawCandidate: TrackID?
    /// The first settle's timestamp — tiles born at/before it are the initial
    /// hand (so a deal tile that merely dropped out at baseline and recovers
    /// later is folded in silently, never mistaken for a draw); only a tile
    /// born *after* it can be a genuine draw.
    private var handSeenBy: TimeInterval?

    /// Win-predicate edge latch — `myHandComplete` fires once per completed
    /// shape, re-armed when the hand changes.
    private var winFired = false

    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
    }

    /// Mint the next monotonic event id. Public so the facade's own boundary
    /// events share this one counter.
    public func mintEventID() -> Int { defer { nextID += 1 }; return nextID }

    /// Bumps the event-id counter so the next `mintEventID()` returns a value
    /// strictly greater than `pastEventID` — `TableTracker.restore`'s way of
    /// seeding the counter past a restored event log's maximum id, so newly
    /// minted events (corrections, the next settle) can never collide with a
    /// restored one. A no-op if the counter is already past `pastEventID`
    /// (never moves it backward).
    public func fastForward(pastEventID: Int) {
        nextID = max(nextID, pastEventID + 1)
    }

    /// Reset per-hand turn/snapshot state on a confirmed hand end. The event-id
    /// counter is intentionally *not* reset.
    public func reset() {
        currentTurn = nil
        baseline = nil
        lastDiscard = nil
        committedHand.removeAll()
        handSeenBy = nil
        handRoseAt = nil
        drawCandidate = nil
        winFired = false
    }

    /// Facade correction support (`reattribute`): re-anchor the rotation from a
    /// corrected event's seat.
    public func reanchorTurn(to seat: RelativeSeat) { currentTurn = seat.next }

    // MARK: - The one settle commit

    /// Commit one settled frame. Diffs the current tracked state against the
    /// last committed snapshot, emits the derived events (in the plan's order:
    /// my-discard, opponent discard, meld claim, my-draw, win), advances the
    /// turn machine, and stores the new baseline. Returns the new events with
    /// monotonic ids; the first-ever call just baselines and returns `[]`.
    ///
    /// - Parameters:
    ///   - motionRegion: the dominant region of the motion burst that preceded
    ///     this settle (the facade reduces the burst's `MotionSample`s to it),
    ///     used as attribution's motion evidence.
    ///   - pondCentroid: `ZoneModel.pondCentroid` — used as attribution's
    ///     pond-entry geometry reference; nil disables the geometry term.
    @discardableResult
    public func commitSettled(store: TrackStore, handIndex: Int,
                              motionRegion: MotionRegion?,
                              pondCentroid: (x: Double, y: Double)?,
                              at t: TimeInterval) -> [GameEvent] {
        let snap = Snapshot(store: store)
        guard let base = baseline else {
            baseline = snap
            committedHand = snap.handIDs
            handSeenBy = t
            return []
        }

        var events: [GameEvent] = []
        let addedPond = snap.pondLive.subtracting(base.pond).sorted(by: byFirstSeen(store))
        // Committed hand tiles that are no longer live — candidates for having
        // left the hand (a discard; a plain dropout has no matching pond birth).
        let leftHand = committedHand.subtracting(snap.handIDs)

        // 1 — My discard: a committed hand tile's face re-appears as a new pond
        // tile. The moved tile is one *new* pond track; its hand slot retires.
        var consumed: Set<TrackID> = []
        for pid in addedPond {
            guard let face = store.track(pid)?.face,
                  let hid = leftHand.sorted().first(where: { faceOf($0, base, store) == face }) else { continue }
            committedHand.remove(hid)
            consumed.insert(pid)
            events.append(event(.myDiscard(tile: face, track: pid), confidence: 1, at: t, handIndex))
            currentTurn = .right
            winFired = false        // the hand changed — re-arm the win check
            break
        }

        // 2 — Opponent discards: every other newly-confirmed pond tile.
        for pid in addedPond where !consumed.contains(pid) {
            guard let tile = store.track(pid) else { continue }
            let a = attribute(pondBox: tile.box, motionRegion: motionRegion, pondCentroid: pondCentroid)
            var flags: Set<GameEvent.Flag> = []
            if tile.faceConfidence < config.faceConfidenceFloor { flags.insert(.uncertainFace) }
            if a.confidence < config.attributionConfidenceFloor { flags.insert(.uncertainAttribution) }
            events.append(event(.discard(seat: a.seat, tile: tile.face, track: pid),
                                confidence: a.confidence, flags: flags, at: t, handIndex))
            store.setZone(pid, to: .pond, seat: a.seat, locked: false)   // stamp the discarder
            lastDiscard = (pid, tile.face, a.seat)
            currentTurn = a.seat.next
        }

        // 3 — Meld claims: a new opponent cluster (grouped by seat) that carries
        // the last discard's face is a claim of it; an existing pung that grew a
        // 4th matching tile is a kong upgrade.
        events.append(contentsOf: meldEvents(snap: snap, base: base, store: store, at: t, handIndex))

        // 4 — My draw: count rose 13→14 and held (guards a settled-frame miss).
        handleMyDraw(snap: snap, base: base, discarded: !consumed.isEmpty,
                     store: store, at: t, handIndex, into: &events)

        // 5 — Win: injected predicate on the current 14-tile shape, rising edge.
        handleWin(snap: snap, store: store, at: t, handIndex, into: &events)

        baseline = snap
        return events
    }

    // MARK: - Meld detection

    private func meldEvents(snap: Snapshot, base: Snapshot, store: TrackStore,
                            at t: TimeInterval, _ handIndex: Int) -> [GameEvent] {
        var events: [GameEvent] = []
        for seat in RelativeSeat.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let cur = snap.oppBySeat[seat] ?? []
            let old = base.oppBySeat[seat] ?? []
            let added = cur.subtracting(old)

            if added.count >= 3 {
                // A freshly-appeared opponent group at this seat = a claim.
                let faces = added.sorted().compactMap { store.track($0)?.face }
                guard let kind = MeldClassifier.classify(faces) else { continue }
                var claimedTile: Tile?, claimedFrom: RelativeSeat?
                if let ld = lastDiscard, faces.contains(ld.face) {
                    claimedTile = ld.face; claimedFrom = ld.seat; lastDiscard = nil
                }
                events.append(event(.meld(seat: seat, kind: kind, tiles: faces,
                                          claimedTile: claimedTile, claimedFrom: claimedFrom),
                                    confidence: 1, at: t, handIndex))
                currentTurn = seat
            } else if cur.count == 4, old.count == 3 {
                // An existing pung gained a matching 4th tile → kong upgrade.
                let faces = cur.sorted().compactMap { store.track($0)?.face }
                guard faces.count == 4, let first = faces.first,
                      faces.allSatisfy({ $0 == first }) else { continue }
                events.append(event(.meld(seat: seat, kind: .kong, tiles: faces,
                                          claimedTile: nil, claimedFrom: nil),
                                    confidence: 1, flags: [.upgradedFromPung], at: t, handIndex))
            }
        }
        return events
    }

    // MARK: - My draw / win

    private func handleMyDraw(snap: Snapshot, base: Snapshot, discarded: Bool,
                              store: TrackStore, at t: TimeInterval, _ handIndex: Int,
                              into events: inout [GameEvent]) {
        // A new *live* hand track not yet committed is either a deal tile that
        // dropped out at baseline and recovered (born at/before `handSeenBy` —
        // fold in silently) or a genuine draw (born after it).
        let appeared = snap.handIDs.subtracting(committedHand)
        let seenBy = handSeenBy ?? t
        let recovered = appeared.filter { (store.track($0)?.firstSeen ?? 0) <= seenBy }
        committedHand.formUnion(recovered)

        let fresh = appeared.subtracting(recovered)
        guard !discarded, let candidate = fresh.max(by: byFirstSeen(store)) else {
            if fresh.isEmpty { handRoseAt = nil; drawCandidate = nil }
            return
        }
        if drawCandidate != candidate { drawCandidate = candidate; handRoseAt = t }
        guard let rose = handRoseAt, t - rose >= config.handCountSustain,
              let track = store.track(candidate) else { return }

        let tile: Tile? = track.faceConfidence >= config.faceConfidenceFloor ? track.face : nil
        var flags: Set<GameEvent.Flag> = []
        if tile == nil { flags.insert(.uncertainFace) }
        events.append(event(.myDraw(tile: tile), confidence: 1, flags: flags, at: t, handIndex))
        currentTurn = .me
        committedHand.insert(candidate)
        handRoseAt = nil; drawCandidate = nil
    }

    private func handleWin(snap: Snapshot, store: TrackStore, at t: TimeInterval,
                           _ handIndex: Int, into events: inout [GameEvent]) {
        // The latch is *not* reset on a transient count dip (dropout can read 13
        // for a frame) — only a real hand change (my discard) re-arms it, above.
        guard snap.handCount == 14, let predicate = config.winPredicate, !winFired else { return }
        let faces = snap.handFaces.keys.sorted().compactMap { snap.handFaces[$0] }
        if predicate(faces, buildMyMelds(store: store)) {
            events.append(event(.myHandComplete, confidence: 1, at: t, handIndex))
            winFired = true
        }
    }

    /// `[Meld]` for the injected win predicate from my melded groups —
    /// delegates the physical grouping (box-proximity clustering) and shape
    /// classification to `MeldClassifier`, the one shared implementation.
    private func buildMyMelds(store: TrackStore) -> [Meld] {
        let mine = store.tracks.filter { $0.zone == .myMeld && $0.state != .retired }
        return MeldClassifier.melds(groupingTracks: mine, sceneConfig: config.sceneConfig, isConcealed: false)
    }

    // MARK: - Attribution

    /// Weighted-evidence seat attribution for one pond tile, softmax-normalized
    /// into a confidence. Prior = the expected next discarder (`currentTurn`);
    /// motion = the burst region's seat; geometry = the pond-entry seat from
    /// displacement off the pond centroid. Evidence-over-prior resync fires
    /// when motion+geometry decisively (≥ `resyncMargin`) name a seat other
    /// than the prior — the rotation then re-anchors, and confidence is scored
    /// with the prior on the *attributed* seat so a clean resync doesn't read
    /// as spuriously amber.
    private func attribute(pondBox: TileBoundingBox, motionRegion: MotionRegion?,
                           pondCentroid: (x: Double, y: Double)?) -> (seat: RelativeSeat, confidence: Double) {
        let seats = RelativeSeat.allCases.sorted { $0.rawValue < $1.rawValue }
        let motionSeat = motionRegion.map(seat(forRegion:))
        let geomSeat = geometrySeat(pondBox, pondCentroid: pondCentroid)

        var evidence: [Double] = seats.map { s in
            (motionSeat == s ? config.attributionMotionWeight : 0)
                + (geomSeat == s ? config.attributionGeometryWeight : 0)
        }
        let priorSeat = currentTurn

        let evidenceBest = argmax(evidence, seats)
        let attributed: RelativeSeat
        if let priorSeat, evidenceBest != priorSeat,
           evidence[idx(evidenceBest)] - evidence[idx(priorSeat)] >= config.resyncMargin {
            attributed = evidenceBest                                   // resync
        } else if let priorSeat {
            var total = evidence
            total[idx(priorSeat)] += config.attributionPriorWeight
            attributed = argmax(total, seats)
        } else {
            attributed = evidenceBest                                   // no anchor yet
        }

        evidence[idx(attributed)] += config.attributionPriorWeight      // re-anchored posterior
        return (attributed, softmax(evidence, at: idx(attributed)))
    }

    private func geometrySeat(_ box: TileBoundingBox, pondCentroid: (x: Double, y: Double)?) -> RelativeSeat? {
        guard let c = pondCentroid else { return nil }
        let dx = box.centerX - c.x, dy = box.centerY - c.y
        guard (dx * dx + dy * dy).squareRoot() >= config.pondInitialSigma else { return nil }   // too central to tell
        return seatFromDisplacement(dx: dx, dy: dy)
    }

    /// The seat a motion region points at — the inverse of a seat's side of the
    /// oriented frame. `center` (my own actions) maps to `.me`.
    private func seat(forRegion region: MotionRegion) -> RelativeSeat {
        switch region {
        case .left: return .left
        case .right: return .right
        case .top: return .across
        case .center: return .me
        }
    }

    // MARK: - Small helpers

    private func idx(_ s: RelativeSeat) -> Int { s.rawValue }

    private func argmax(_ scores: [Double], _ seats: [RelativeSeat]) -> RelativeSeat {
        var best = seats[0], bestV = scores[0]
        for i in seats.indices where scores[i] > bestV { bestV = scores[i]; best = seats[i] }
        return best
    }

    private func softmax(_ scores: [Double], at i: Int) -> Double {
        let m = scores.max() ?? 0
        let exps = scores.map { Foundation.exp($0 - m) }
        let sum = exps.reduce(0, +)
        return sum > 0 ? exps[i] / sum : 0
    }

    /// Ascending order by `firstSeen` (TrackID breaks ties) — the stable order
    /// in which multiple pond tiles from missed intermediate settles are
    /// attributed, and how the newest hand tile (a draw) is picked via `.max`.
    private func byFirstSeen(_ store: TrackStore) -> (TrackID, TrackID) -> Bool {
        { a, b in
            let fa = store.track(a)?.firstSeen ?? .greatestFiniteMagnitude
            let fb = store.track(b)?.firstSeen ?? .greatestFiniteMagnitude
            return fa != fb ? fa < fb : a.raw < b.raw
        }
    }

    private func faceOf(_ id: TrackID, _ base: Snapshot, _ store: TrackStore) -> Tile? {
        base.handFaces[id] ?? store.track(id)?.face
    }

    private func event(_ kind: GameEvent.Kind, confidence: Double,
                       flags: Set<GameEvent.Flag> = [], at t: TimeInterval, _ handIndex: Int) -> GameEvent {
        GameEvent(id: mintEventID(), at: t, handIndex: handIndex, kind: kind,
                  confidence: confidence, flags: flags)
    }

    // MARK: - Settled snapshot

    /// The diffable projection of one settled frame. Hand/pond/opponent-meld
    /// membership plus the hand faces needed to link a discard back to the tile
    /// that left the hand. Tentative (unconfirmed) tracks are excluded — only
    /// confirmed tiles produce events.
    ///
    /// My hand is counted **live-only**: on a settled (calm) frame a hand tile
    /// that is `missing` genuinely left its spot — a discarded tile whose old
    /// hand track lingers within motion-grace while a *new* pond track is born.
    /// Counting it as still-in-hand is exactly what would misread a discard as
    /// an opponent's. Detector dropout can't cause a false event from this: a
    /// draw needs the raised count to *sustain*, and a discard needs a matching
    /// new pond tile — a momentary miss has neither. Pond keeps a live+missing
    /// set for baseline continuity (so an occluded pond tile isn't re-emitted
    /// as a new discard) plus a live set for spotting a genuine new one.
    private struct Snapshot {
        var handIDs: Set<TrackID> = []
        var handFaces: [TrackID: Tile] = [:]
        var pond: Set<TrackID> = []          // live + missing (baseline continuity)
        var pondLive: Set<TrackID> = []      // live only (a real new discard)
        var oppBySeat: [RelativeSeat: Set<TrackID>] = [:]
        var handCount = 0

        init(store: TrackStore) {
            for tr in store.tracks {           // already TrackID-ordered
                switch tr.zone {
                case .myHand where !tr.face.isBonus:
                    guard tr.state == .live else { continue }
                    handIDs.insert(tr.id); handFaces[tr.id] = tr.face
                case .pond:
                    guard tr.state == .live || tr.state == .missing else { continue }
                    pond.insert(tr.id)
                    if tr.state == .live { pondLive.insert(tr.id) }
                case .opponentMeld:
                    guard tr.state == .live || tr.state == .missing, let seat = tr.seat else { continue }
                    oppBySeat[seat, default: []].insert(tr.id)
                default:
                    break
                }
            }
            handCount = handIDs.count
        }
    }
}
