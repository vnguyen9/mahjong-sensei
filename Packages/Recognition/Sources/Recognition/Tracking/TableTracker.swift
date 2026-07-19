import Foundation
import MahjongCore

/// The single-owner facade (tracker plan §2.5): composes `TrackStore` +
/// `ZoneModel` + `TurnEngine` + `HandBoundaryDetector` behind one `ingest`
/// call, publishes `TrackedTableState` snapshots, and is the one surface the
/// app/CLI corrections talk to. Everything downstream (`ScriptedGame`-driven
/// tests, `TrackerHarness`, the eventual app controller and `track-replay`
/// CLI) either composes the same four pieces by hand or calls this — see
/// `TableTrackerTests`'s facade-parity test for a byte-for-byte comparison of
/// the two.
///
/// **Call order per `ingest`** (mirrors `TrackerHarness`'s hand-composed
/// sequence, the plan's own documented contract):
/// 1. `store.associate(detections, at:, motion:, visibleRegion:)` — every
///    frame, motion or not; tracks survive and vote mid-motion but nothing
///    commits. `visibleRegion` (Lane B chunk E) is forwarded straight from
///    `ingest`'s own parameter — see that method's doc.
/// 2. Update the settle gate (motion below `TrackerConfig.motionSettle` for
///    `settleDelay`; `motion == nil` — a still-photo stream — settles
///    immediately, no sustain wait).
/// 3. Only on a **settled** frame, in order:
///    a. `zoneModel.ingestSettled(...)` — zones first, so
///    b. `turnEngine.commitSettled(...)` sees current zones + the pond
///       centroid `zoneModel` just updated + the burst region that preceded
///       this settle, then
///    c. `boundaryDetector.evaluateSettled(...)` — the occlusion guard is
///       structural (§3.6): calling this only on settled frames *is* "nothing
///       fires during high motion".
/// 4. Rebuild `state` fresh from current tracks (`assembleState`), then
///    annotate `newEvents` with the injected `waitImpactAnnotator` using that
///    fresh state as context.
///
/// **What survives a confirmed hand boundary vs what resets** (`confirmHandEnd`):
/// survives — `ZoneModel`'s hand-band/pond-centroid calibration (the plan's
/// explicit "calibration is a session constant, static camera" — see
/// `ZoneModel.reset()`'s own doc), the session's monotonic track/event id
/// counters (`TrackStore`/`TurnEngine` never reset those), the full event
/// log (append-only, `handIndex` partitions it), `dealsSinceRoundStart`
/// (rolled forward by `WindRotation`, not reset — a round can span several
/// `confirmHandEnd` calls). Resets — every tracked tile (`TrackStore.reset`),
/// per-hand zone ledgers (`ZoneModel.reset`, calibration excepted),
/// `TurnEngine`'s turn/snapshot state, `HandBoundaryDetector`'s
/// confirmed-this-hand bookkeeping, `pendingHandEnd`, the settle-gate/burst
/// bookkeeping, and the win-fired latch.
///
/// Not `Sendable` — single-owner mutable state (the MainActor app loop or the
/// CLI replay), exactly like the four pieces it composes. No `Date()`/
/// `UUID()` in any logic path.
public final class TableTracker {
    private let config: TrackerConfig

    // Composed pieces. `internal` (not `private`) on purpose: `TrackerHarness`
    // (`@testable import Recognition`) reads these directly for its own
    // hand-composed tests, and `TableTrackerTests`'s facade-parity test needs
    // to reach `turnEngine.currentTurn` etc. the same way the harness does.
    let store: TrackStore
    let zoneModel: ZoneModel
    let turnEngine: TurnEngine
    private let boundaryDetector: HandBoundaryDetector

    public private(set) var state: TrackedTableState = .empty
    public private(set) var events: [GameEvent] = []
    public private(set) var pendingHandEnd: HandEndProposal?
    public private(set) var diagnostics = TrackerDiagnostics()

    /// Wait-impact annotator seam (plan §4.4/§4.6): the app/CLI injects
    /// `EfficiencyEngine`-backed logic that flags `.reducesMyWaits` on events
    /// whose tile(s) intersect the tracked hand's live outs; `nil` (default)
    /// sets no flags. Recognition never imports EfficiencyEngine — this
    /// closure is the entire dependency-rule seam, exactly like
    /// `TrackerConfig.winPredicate`.
    public var waitImpactAnnotator: (@Sendable (GameEvent, TrackedTableState) -> Set<GameEvent.Flag>)?

    // Settle-gate + burst-region bookkeeping — same shape as
    // `TrackerHarness`'s private `isSettled`/`burstRegion`, now the
    // production implementation.
    private var belowSince: TimeInterval?
    private var burstRegion: MotionRegion?
    private var now: TimeInterval = 0
    private var handIndex = 0
    /// Threaded into `WindRotation.afterHand` — see that type's doc for why
    /// round-completion needs this and can't be derived from winds alone.
    /// Survives `confirmHandEnd` (only `WindRotation` itself resets it, on
    /// the pass that completes a round); reset to 0 by `beginSession`.
    private var dealsSinceRoundStart = 0
    /// Mirrors `TurnEngine`'s own win-fired latch (re-armed on a hand
    /// change) so `state.isMyHandComplete` reflects the latest commit
    /// without `TurnEngine` needing to publish its private flag.
    private var handComplete = false

    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
        store = TrackStore(config: config)
        zoneModel = ZoneModel(config: config)
        turnEngine = TurnEngine(config: config)
        boundaryDetector = HandBoundaryDetector(config: config)
    }

    // MARK: - Session

    public func beginSession(mySeatWind: Wind, roundWind: Wind, at t: TimeInterval) {
        now = t
        handIndex = 0
        dealsSinceRoundStart = 0
        handComplete = false
        pendingHandEnd = nil
        belowSince = nil
        burstRegion = nil
        store.reset()
        zoneModel.reset()
        turnEngine.reset()
        boundaryDetector.reset()

        state = TrackedTableState(mySeatWind: mySeatWind, roundWind: roundWind)
        events = []
        appendEvent(.handStarted(mySeatWind: mySeatWind, roundWind: roundWind), confidence: 1.0, at: t)
        assembleState()
    }

    // MARK: - Persistence (plan A6: survive relaunch)

    /// Exports the tracker's CONFIRMED state for on-disk persistence across a
    /// relaunch — a state-EXPORT snapshot, not an internal-state dump (see
    /// `TrackerSnapshot`'s own doc for the full rationale). Captured tiles
    /// are exactly `state.myHand + .myBonus + .myMelds + .pond +
    /// .opponentMelds` — i.e. everything `assembleState` already considers
    /// confirmed. `.unresolved` is deliberately excluded: it's a transient,
    /// not-yet-zoned detector guess whose face-confidence/vote state isn't
    /// faithfully round-trippable through a single published `face` (voting
    /// is bypassed entirely for a restored, pinned track), so resurrecting
    /// it on restore would just recreate the exact ambiguity a few fresh
    /// frames resolve for free. Injected `t` only — never `Date()`.
    public func snapshot(at t: TimeInterval) -> TrackerSnapshot {
        let confirmed = state.myHand + state.myBonus + state.myMelds.flatMap { $0 }
            + state.pond + state.opponentMelds.values.flatMap { $0.flatMap { $0 } }
        let tiles = confirmed.map { tile in
            TrackerSnapshot.SnapshotTile(id: tile.id, face: tile.face, box: tile.box, zone: tile.zone,
                                         seat: tile.seat, firstSeen: tile.firstSeen, lastSeen: tile.lastSeen,
                                         observationCount: tile.observationCount)
        }
        return TrackerSnapshot(mySeatWind: state.mySeatWind, roundWind: state.roundWind, handIndex: handIndex,
                               dealsSinceRoundStart: dealsSinceRoundStart, events: events, tiles: tiles,
                               savedAtMono: t)
    }

    /// Restores a `snapshot` onto a FRESH tracker — one that has never had
    /// `beginSession`/`ingest` called. This is an alternate session start,
    /// not a merge: it doesn't route through `beginSession`'s reset at all,
    /// so anything already on this tracker would leak into the "restored"
    /// state — which is exactly why a fresh instance is a hard precondition
    /// rather than a doc suggestion.
    ///
    /// Seeds winds/handIndex/the deal counter straight from the snapshot,
    /// restores the event log verbatim (these events already happened — no
    /// re-derivation), fast-forwards `TurnEngine`'s event-id counter past
    /// the restored log's max id, then `TrackStore.restoreTrack`s every
    /// snapshotted tile under its ORIGINAL id (which itself fast-forwards
    /// the track-id counter past that id) and locks each one's zone in
    /// `ZoneModel` the same way `overrideZone` does, so a contradicting
    /// settled frame right after resume can't immediately vote a restored
    /// tile back out of its zone. Finally reassembles `state` from the
    /// freshly-populated tracks.
    ///
    /// Deliberately NOT restored: `pendingHandEnd` (a stale hand-end
    /// proposal — the plan's call is that it re-detects in seconds once
    /// frames resume, and shipping a possibly-stale confirm/dismiss card is
    /// worse than that short gap) and `ZoneModel`'s hand-band/pond-centroid
    /// calibration (left to relearn from fresh frames — the plan's whole
    /// rationale for a state-EXPORT design over an internal-state snapshot;
    /// see `TrackerSnapshot`'s doc). `currentTurn` also comes back nil, same
    /// as a brand-new session — the very next settle re-derives it from
    /// live evidence. Injected `t` only — never `Date()`.
    public func restore(_ snapshot: TrackerSnapshot, at t: TimeInterval) {
        precondition(events.isEmpty && store.tracks.isEmpty,
                    "TableTracker.restore requires a fresh tracker (never begun/ingested)")
        now = t
        handIndex = snapshot.handIndex
        dealsSinceRoundStart = snapshot.dealsSinceRoundStart
        handComplete = false
        pendingHandEnd = nil
        belowSince = nil
        burstRegion = nil

        events = snapshot.events
        turnEngine.fastForward(pastEventID: snapshot.events.map(\.id).max() ?? -1)

        for tile in snapshot.tiles {
            store.restoreTrack(id: tile.id, face: tile.face, box: tile.box, zone: tile.zone, seat: tile.seat,
                               firstSeen: tile.firstSeen, lastSeen: tile.lastSeen,
                               observationCount: tile.observationCount, at: t)
            zoneModel.markLocked(tile.id)
        }

        state = TrackedTableState(handIndex: snapshot.handIndex,
                                  mySeatWind: snapshot.mySeatWind, roundWind: snapshot.roundWind)
        assembleState()
    }

    // MARK: - Ingest

    /// The one ingestion API. `motion` nil ⇒ treated as settled (still-photo
    /// streams — see the type doc's call-order note). `visibleRegion` nil
    /// (default) ⇒ this frame's detections cover the full view, exactly the
    /// original contract — `usingFallbackCapture`/the image-space harness
    /// path never passes it. Non-nil (Lane B chunk E — a cropped AR
    /// recognize pass) ⇒ forwarded straight to `TrackStore.associate`, whose
    /// doc explains the miss-accrual gate it drives; nothing else in this
    /// method needs it (zoning/turn/boundary detection all just consume
    /// whatever `detections`/`store` produced this call).
    @discardableResult
    public func ingest(_ detections: [DetectedTile], at t: TimeInterval, motion: MotionSample? = nil,
                       visibleRegion: TileBoundingBox? = nil) -> IngestOutcome {
        now = t
        let outcome = store.associate(detections, at: t, motion: motion, visibleRegion: visibleRegion)
        if let level = motion?.level, level >= config.motionActive { burstRegion = motion?.dominantRegion }

        guard isSettled(motion: motion, at: t) else {
            diagnostics = currentDiagnostics(lastSettleAt: diagnostics.lastSettleAt)
            return IngestOutcome(newEvents: [], stateChanged: false, settled: false)
        }

        zoneModel.ingestSettled(detections: detections, outcome: outcome, store: store, at: t)
        var newEvents = turnEngine.commitSettled(store: store, handIndex: handIndex,
                                                  motionRegion: burstRegion, pondCentroid: zoneModel.pondCentroid, at: t)
        updateHandCompleteLatch(from: newEvents)

        let boundary = boundaryDetector.evaluateSettled(store: store, at: t)
        if let proposed = boundary.proposed {
            var proposal = proposed
            proposal.predictedWinds = predictedWinds().winds
            pendingHandEnd = proposal
            newEvents.append(GameEvent(id: turnEngine.mintEventID(), at: t, handIndex: handIndex,
                                       kind: .handEndProposed(missingFraction: proposal.missingFraction),
                                       confidence: 1.0))
        }
        if boundary.cancelled {
            pendingHandEnd = nil
            newEvents.append(GameEvent(id: turnEngine.mintEventID(), at: t, handIndex: handIndex,
                                       kind: .handEndCancelled, confidence: 1.0))
        }

        diagnostics = currentDiagnostics(lastSettleAt: t)
        assembleState()
        let annotated = newEvents.map(annotate)
        events += annotated
        return IngestOutcome(newEvents: annotated, stateChanged: true, settled: true)
    }

    private func isSettled(motion: MotionSample?, at t: TimeInterval) -> Bool {
        guard let level = motion?.level else { belowSince = nil; return true }
        if level <= config.motionSettle {
            if belowSince == nil { belowSince = t }
        } else {
            belowSince = nil
        }
        guard let since = belowSince else { return false }
        return t - since >= config.settleDelay
    }

    private func updateHandCompleteLatch(from newEvents: [GameEvent]) {
        if newEvents.contains(where: { if case .myHandComplete = $0.kind { return true }; return false }) {
            handComplete = true
        }
        if newEvents.contains(where: { if case .myDiscard = $0.kind { return true }; return false }) {
            handComplete = false
        }
    }

    private func currentDiagnostics(lastSettleAt: TimeInterval?) -> TrackerDiagnostics {
        let c = store.counts
        return TrackerDiagnostics(tentative: c.tentative, live: c.live, missing: c.missing,
                                  retired: c.retired, lastSettleAt: lastSettleAt)
    }

    // MARK: - Corrections (plan §5)

    /// Face override wins forever; recomputes the published state (and so
    /// the histogram) from the corrected track. Survives missing/rebirth —
    /// see `TrackStore.pin`.
    public func pin(track: TrackID, as face: Tile) {
        store.pin(track, as: face)
        appendRevisionEvent(.pin)
        assembleState()
    }

    /// Locks the track's zone (and, for `.opponentMeld`, its owner seat)
    /// against future `ZoneModel` re-votes.
    public func overrideZone(track: TrackID, to zone: TileZone, seat: RelativeSeat? = nil) {
        applyZoneOverride(track, to: zone, seat: seat)
        appendRevisionEvent(.zoneOverride)
        assembleState()
    }

    /// Bulk counterpart (plan A3): reassigns every listed track to `zone`
    /// with the identical per-track lock/vote mechanics `overrideZone(track:)`
    /// uses, but coalesced into ONE revision event + ONE state reassembly for
    /// the whole batch — the bracket-reassign correction moves a whole
    /// cluster (a pond's worth of tracks, say) in a single user gesture, and
    /// N revision events / N `assembleState()` passes for one gesture would
    /// be both wasteful and a misleading event log. Empty input is a no-op
    /// (no event, no assembly) — nothing was actually corrected.
    public func overrideZone(tracks: [TrackID], to zone: TileZone, seat: RelativeSeat? = nil) {
        guard !tracks.isEmpty else { return }
        for track in tracks {
            applyZoneOverride(track, to: zone, seat: seat)
        }
        appendRevisionEvent(.zoneOverride)
        assembleState()
    }

    /// Shared lock/vote mechanics behind both `overrideZone` overloads —
    /// everything except the revision event + state reassembly, which the
    /// bulk overload coalesces across its whole batch.
    private func applyZoneOverride(_ track: TrackID, to zone: TileZone, seat: RelativeSeat?) {
        store.setZone(track, to: zone, seat: seat, locked: true)
        zoneModel.markLocked(track)
    }

    /// Creates a `live`, pinned, zone-locked manual track for a tile the
    /// detector never caught. `near box` nil ⇒ a best-effort zone-centroid
    /// default (pond centroid for `.pond`, the calibrated hand band for
    /// `.myHand`/`.myBonus`/`.myMeld`, an offset from the pond centroid
    /// toward the given seat for `.opponentMeld`).
    @discardableResult
    public func insertMissedTile(face: Tile, zone: TileZone, seat: RelativeSeat?,
                                 near box: TileBoundingBox?) -> TrackID {
        let placedBox = box ?? defaultBox(for: zone, seat: seat)
        let id = store.insertManualTrack(face: face, zone: zone, seat: seat, box: placedBox, at: now)
        zoneModel.markLocked(id)
        appendRevisionEvent(.insertMissedTile)
        assembleState()
        return id
    }

    /// Hard-deletes a ghost/double detection; `TrackStore` suppresses its
    /// box for `suppressionWindow` so it can't immediately rebirth.
    public func removeTrack(_ track: TrackID) {
        store.removeTrack(track)
        zoneModel.forget(track)
        appendRevisionEvent(.removeTrack)
        assembleState()
    }

    /// Rewrites a discard/meld event's seat (the plan's `reattribute`):
    /// appends a *new* revision of the event (append-only log — see
    /// `GameEvent`'s own doc) flagged `.amended`, restamps the linked pond
    /// track's seat for a discard, and re-anchors the turn rotation from the
    /// correction. A no-op for any other event kind (only discard/meld carry
    /// a seat to correct).
    public func amendEvent(_ eventID: Int, seat: RelativeSeat) {
        guard let old = events.first(where: { $0.id == eventID }) else { return }
        let newKind: GameEvent.Kind
        switch old.kind {
        case let .discard(_, tile, track):
            newKind = .discard(seat: seat, tile: tile, track: track)
            store.setZone(track, to: .pond, seat: seat, locked: false)
        case let .meld(_, kind, tiles, claimedTile, claimedFrom):
            newKind = .meld(seat: seat, kind: kind, tiles: tiles, claimedTile: claimedTile, claimedFrom: claimedFrom)
        default:
            return
        }
        turnEngine.reanchorTurn(to: seat)
        appendEvent(newKind, confidence: 1.0, flags: old.flags.union([.amended]), at: old.at, handIndexOverride: old.handIndex)
        appendRevisionEvent(.reattribute)
        assembleState()
    }

    /// Removes an event from the published log — a spurious/hallucinated
    /// event (e.g. a meld claim that never happened) the user flags as
    /// wrong. Unlike `amendEvent`, this doesn't preserve the original entry
    /// (showing clearly-wrong information, merely flagged, is worse than
    /// removing it) — but it still appends a `.stateRevised(reason:
    /// .eventDeleted)` marker, so the *fact that a deletion happened* stays
    /// in the append-only trail even though the deleted content doesn't.
    /// Does not touch the underlying track (that's `removeTrack`'s job).
    public func deleteEvent(_ eventID: Int) {
        guard events.contains(where: { $0.id == eventID }) else { return }
        events.removeAll { $0.id == eventID }
        appendRevisionEvent(.eventDeleted)
        assembleState()
    }

    // MARK: - Hand boundary

    /// Confirms the pending proposal: emits `handEnded`, resets everything
    /// but calibration (see the type doc's "what survives" note), advances
    /// `handIndex`, predicts + applies next winds via `WindRotation`, and
    /// emits a fresh `handStarted`.
    public func confirmHandEnd(winner: RelativeSeat?) {
        guard pendingHandEnd != nil else { return }
        let prediction = predictedWinds(winner: winner)
        dealsSinceRoundStart = prediction.dealsSinceRoundStart

        appendEvent(.handEnded(winner: winner), confidence: 1.0, at: now)

        store.reset()
        zoneModel.reset()
        turnEngine.reset()
        boundaryDetector.reset()
        belowSince = nil
        burstRegion = nil
        handComplete = false
        pendingHandEnd = nil
        handIndex += 1

        let newSeatWind = prediction.winds.mySeatWind, newRoundWind = prediction.winds.roundWind
        state = TrackedTableState(revision: state.revision, phase: .calibrating, handIndex: handIndex,
                                  mySeatWind: newSeatWind, roundWind: newRoundWind)
        appendEvent(.handStarted(mySeatWind: newSeatWind, roundWind: newRoundWind), confidence: 1.0, at: now)
        appendRevisionEvent(.handEndConfirmed)
        assembleState()
    }

    /// Dismisses a pending proposal without ending the hand — the manual
    /// counterpart to `HandBoundaryDetector`'s automatic reappearance
    /// auto-cancel; both converge on the same `handEndCancelled` event.
    public func dismissHandEnd() {
        guard pendingHandEnd != nil else { return }
        pendingHandEnd = nil
        boundaryDetector.dismiss(at: now)
        appendEvent(.handEndCancelled, confidence: 1.0, at: now)
        appendRevisionEvent(.handEndDismissed)
        assembleState()
    }

    /// Best-effort `WindRotation` prediction for the pending-hand-end UI card
    /// (fired *before* the real winner is known): assumes I've won if
    /// `state.isMyHandComplete` latched true this hand, else assumes a draw
    /// (dealer repeats) — the safe default. `confirmHandEnd`'s actual commit
    /// always recomputes from the caller-supplied `winner`, so this guess
    /// never needs to be authoritative.
    private func predictedWinds(winner: RelativeSeat? = nil) -> WindRotation.Prediction {
        let assumed = winner ?? (handComplete ? .me : nil)
        return WindRotation.afterHand(mySeatWind: state.mySeatWind, roundWind: state.roundWind,
                                      winner: assumed, dealsSinceRoundStart: dealsSinceRoundStart)
    }

    // MARK: - State assembly

    /// Rebuilds `state` from scratch from the current track set — the
    /// contract that makes corrections/event revisions "just work" without
    /// event replay (`TrackingModels.swift`'s own doc: "`TableState` is
    /// always recomputed from the corrected tracks, so `seenHistogram` never
    /// needs event replay to be right"). Bumps `revision`.
    private func assembleState() {
        let tracks = store.tracks
        let live = tracks.filter { $0.state == .live }

        let myHand = live.filter { $0.zone == .myHand }.sorted { $0.box.centerX < $1.box.centerX }
        let myBonus = live.filter { $0.zone == .myBonus }.sorted { $0.box.centerX < $1.box.centerX }
        let myMelds = stampGroups(MeldClassifier.physicalGroups(of: live.filter { $0.zone == .myMeld },
                                                                 sceneConfig: config.sceneConfig))

        let pondSource = tracks.filter { $0.zone == .pond && ($0.state == .live || $0.state == .missing) }
        let pond = pondSource.sorted { lhs, rhs in
            let lu = lhs.faceConfidence < config.faceConfidenceFloor
            let ru = rhs.faceConfidence < config.faceConfidenceFloor
            if lu != ru { return !lu }               // settled faces sort before unsettled ones
            return lhs.firstSeen < rhs.firstSeen
        }

        var opponentMelds: [RelativeSeat: [[TrackedTile]]] = [:]
        for seat in RelativeSeat.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let seatTracks = tracks.filter {
                $0.zone == .opponentMeld && $0.seat == seat && ($0.state == .live || $0.state == .missing)
            }
            guard !seatTracks.isEmpty else { continue }
            opponentMelds[seat] = stampGroups(MeldClassifier.physicalGroups(of: seatTracks, sceneConfig: config.sceneConfig))
        }

        let unresolved = live.filter { $0.zone == .unresolved }.sorted { $0.id < $1.id }

        // seenHistogram/unseenCount mirror ScanSession's convention exactly
        // (`App/Sources/Features/Scan/ScanFlow.swift`): pond + opponentMelds
        // only, non-bonus — my own hand/melds are deliberately excluded,
        // since that's what `EfficiencyEngine.ukeire(seen:)` expects.
        var histogram = [Int](repeating: 0, count: Tile.baseClassCount)
        for tile in pond where !tile.face.isBonus { histogram[tile.face.classIndex] += 1 }
        for (_, groups) in opponentMelds {
            for group in groups { for tile in group where !tile.face.isBonus { histogram[tile.face.classIndex] += 1 } }
        }
        let myMeldTileCount = myMelds.reduce(0) { $0 + $1.count }
        let unseen = max(1, 136 - myHand.count - myMeldTileCount - histogram.reduce(0, +))

        let phase: TrackedHandPhase = pendingHandEnd != nil ? .endProposed
            : (boundaryDetector.isClearing ? .clearing : (zoneModel.isBandCalibrated ? .playing : .calibrating))

        state = TrackedTableState(revision: state.revision + 1, phase: phase, handIndex: handIndex,
                                  mySeatWind: state.mySeatWind, roundWind: state.roundWind,
                                  currentTurn: turnEngine.currentTurn,
                                  myHand: myHand, myBonus: myBonus, myMelds: myMelds,
                                  pond: pond, opponentMelds: opponentMelds, unresolved: unresolved,
                                  seenHistogram: histogram, unseenCount: unseen,
                                  handTileCount: myHand.count, isMyHandComplete: handComplete)
    }

    /// Stamps each group's tracks with their index into the containing
    /// `myMelds`/`opponentMelds[seat]` array — `TrackedTile.meldGroup`.
    private func stampGroups(_ groups: [[TrackedTile]]) -> [[TrackedTile]] {
        groups.enumerated().map { index, group in
            group.map { tile in
                var t = tile
                t.meldGroup = index
                return t
            }
        }
    }

    /// Best-effort default placement for `insertMissedTile(near: nil)`.
    private func defaultBox(for zone: TileZone, seat: RelativeSeat?) -> TileBoundingBox {
        let pond = zoneModel.pondCentroid ?? (x: 0.5, y: 0.5)
        let band = zoneModel.handBandY
        let center: (x: Double, y: Double)
        switch zone {
        case .myHand, .myBonus, .myMeld:
            center = (0.5, band?.upperBound ?? 0.84)
        case .pond, .unresolved:
            center = pond
        case .opponentMeld:
            let offset = 0.3
            switch seat ?? .across {
            case .left:   center = (pond.x - offset, pond.y)
            case .right:  center = (pond.x + offset, pond.y)
            case .across: center = (pond.x, pond.y - offset)
            case .me:     center = (pond.x, pond.y + offset)
            }
        }
        return TileBoundingBox(x: center.x - 0.025, y: center.y - 0.04, width: 0.05, height: 0.08)
    }

    // MARK: - Event log helpers

    @discardableResult
    private func appendEvent(_ kind: GameEvent.Kind, confidence: Double, flags: Set<GameEvent.Flag> = [],
                             at t: TimeInterval, handIndexOverride: Int? = nil) -> GameEvent {
        let event = GameEvent(id: turnEngine.mintEventID(), at: t, handIndex: handIndexOverride ?? handIndex,
                              kind: kind, confidence: confidence, flags: flags)
        let annotated = annotate(event)
        events.append(annotated)
        return annotated
    }

    private func appendRevisionEvent(_ reason: RevisionReason) {
        appendEvent(.stateRevised(reason: reason), confidence: 1.0, at: now)
    }

    private func annotate(_ event: GameEvent) -> GameEvent {
        guard let waitImpactAnnotator else { return event }
        let extra = waitImpactAnnotator(event, state)
        guard !extra.isEmpty else { return event }
        var e = event
        e.flags.formUnion(extra)
        return e
    }
}

/// Live/tentative/missing/retired counts plus the last settle timestamp —
/// the app's `LiveHealth`/debug surface reads this; not part of the plan's
/// frozen `TrackingModels.swift` contract (that file predates the facade),
/// so it's defined here where it's actually produced.
public struct TrackerDiagnostics: Sendable, Hashable {
    public var tentative: Int
    public var live: Int
    public var missing: Int
    public var retired: Int
    public var lastSettleAt: TimeInterval?

    public init(tentative: Int = 0, live: Int = 0, missing: Int = 0, retired: Int = 0,
               lastSettleAt: TimeInterval? = nil) {
        self.tentative = tentative
        self.live = live
        self.missing = missing
        self.retired = retired
        self.lastSettleAt = lastSettleAt
    }
}
