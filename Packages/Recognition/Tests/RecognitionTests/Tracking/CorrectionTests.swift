import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Chunk-6 coverage: `TableTracker`'s corrections API (pin/overrideZone/
/// insertMissedTile/removeTrack/amendEvent/deleteEvent/confirmHandEnd/
/// dismissHandEnd) and the facade's `ingest` wiring, proven by comparing a
/// `TableTracker`-driven run against the existing `TrackerHarness`-driven run
/// of the identical `ScriptedGame` stream (the tracker plan's §9
/// corrections/facade test items).
final class CorrectionTests: XCTestCase {

    private func dealHand() -> [Tile] {
        [.m(1), .m(2), .m(3), .m(4), .m(5), .p(2), .p(3), .p(4), .s(6), .s(7), .s(8), .east, .west]
    }

    /// Runs `frames` through a fresh, session-begun `TableTracker`.
    private func run(_ frames: [(t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])],
                     mySeatWind: Wind = .east, roundWind: Wind = .east) -> TableTracker {
        let tracker = TableTracker()
        tracker.beginSession(mySeatWind: mySeatWind, roundWind: roundWind, at: 0)
        for f in frames { tracker.ingest(f.tiles, at: f.t, motion: f.motion) }
        return tracker
    }

    /// Appends extra calm (zero-motion, empty-detection) frames after
    /// `frames`'s last timestamp — see `HandBoundaryTests.extendCalm`'s
    /// identical doc: `ScriptedGame.frames()`'s natural tail is far shorter
    /// than `handClearSustain`, so hand-boundary scenarios extend explicitly.
    private func extendCalm(_ frames: [(t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])],
                            by extra: TimeInterval, fps: Double = 10) -> [(t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])] {
        guard let last = frames.last?.t else { return frames }
        var result = frames
        let step = 1.0 / fps
        var t = last + step
        while t <= last + extra {
            result.append((t: t, motion: MotionSample(t: t, level: 0), tiles: []))
            t += step
        }
        return result
    }

    // MARK: - Facade integration on ScriptedGame (parity with TrackerHarness)

    /// A projection of `GameEvent` that drops `id` (the facade's leading
    /// `handStarted` event — which `TrackerHarness` never emits, since it
    /// has no session concept — offsets every subsequent id by one) but
    /// keeps everything semantically meaningful, so two independently-id'd
    /// but behaviorally-identical streams compare equal.
    private struct EventShape: Equatable {
        var at: TimeInterval
        var handIndex: Int
        var kind: GameEvent.Kind
        var confidence: Double
        var flags: Set<GameEvent.Flag>
        init(_ e: GameEvent) {
            at = e.at; handIndex = e.handIndex; kind = e.kind; confidence = e.confidence; flags = e.flags
        }
    }

    func testFacadeIngestProducesTheSameGameplayEventsAsTheHandComposedHarness() {
        var game = ScriptedGame(seed: 5_001)
        game.deal(myHand: dealHand())
        game.myDiscard(.m(1), at: 1.0)
        game.discard(.right, .s(1), at: 3.0)
        game.claim(.pung, by: .across, tiles: [.s(1), .s(1), .s(1)], at: 5.0)
        game.discard(.across, .p(9), at: 7.5)
        let frames = game.frames()

        let harness = TrackerHarness()
        let harnessEvents = harness.run(frames)
        XCTAssertFalse(harnessEvents.isEmpty, "sanity: the script must actually produce events")

        let tracker = run(frames)
        // Drop the facade-only `handStarted` the session-begin step emits —
        // TrackerHarness has no session concept, so it never produces one.
        let facadeGameplay = tracker.events.filter {
            if case .handStarted = $0.kind { return false }
            return true
        }

        XCTAssertEqual(facadeGameplay.map(EventShape.init), harnessEvents.map(EventShape.init),
                       "TableTracker.ingest must derive the identical event stream the hand-composed harness does")
        XCTAssertEqual(tracker.turnEngine.currentTurn, harness.turnEngine.currentTurn)
        XCTAssertEqual(tracker.store.tracks, harness.store.tracks, "identical inputs must yield identical tracks too")
    }

    // MARK: - pin sticks through the facade

    func testPinStickThroughFacade() {
        var game = ScriptedGame(seed: 5_002)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())

        guard let pondTrack = tracker.state.pond.first(where: { $0.face == .s(1) }) else {
            return XCTFail("expected an s1 in the pond")
        }
        tracker.pin(track: pondTrack.id, as: .greenDragon)
        XCTAssertEqual(tracker.state.pond.first { $0.id == pondTrack.id }?.face, .greenDragon)
        XCTAssertTrue(tracker.state.pond.first { $0.id == pondTrack.id }?.isPinned ?? false)

        // Bombard it with more contradicting detections at the same spot —
        // the pin must survive the facade's own ingest loop, not just the
        // underlying TrackStore call.
        for i in 0..<5 {
            tracker.ingest([DetectedTile(tile: .s(1), confidence: 0.9, box: pondTrack.box)],
                           at: 2.0 + Double(i) * 0.2, motion: MotionSample(t: 2.0 + Double(i) * 0.2, level: 0))
        }
        XCTAssertEqual(tracker.state.pond.first { $0.id == pondTrack.id }?.face, .greenDragon,
                       "pin outlasts contradicting frames ingested through the facade")

        // Revision bumped and a stateRevised(.pin) event is on the log.
        XCTAssertTrue(tracker.events.contains { if case .stateRevised(.pin) = $0.kind { return true }; return false })
    }

    // MARK: - overrideZone locks against ZoneModel re-votes

    func testOverrideZoneLocksAgainstZoneModelReVotes() {
        var game = ScriptedGame(seed: 5_003)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())

        guard let pondTrack = tracker.state.pond.first(where: { $0.face == .s(1) }) else {
            return XCTFail("expected an s1 in the pond")
        }
        tracker.overrideZone(track: pondTrack.id, to: .myMeld, seat: nil)
        XCTAssertTrue(tracker.state.myMelds.flatMap { $0 }.contains { $0.id == pondTrack.id })
        XCTAssertFalse(tracker.state.pond.contains { $0.id == pondTrack.id })

        // Keep feeding pond-shaped evidence at the same spot — a locked zone
        // must never re-vote back to pond.
        for i in 0..<8 {
            let t = 2.0 + Double(i) * 0.9
            tracker.ingest([DetectedTile(tile: .s(1), confidence: 0.9, box: pondTrack.box)],
                           at: t, motion: MotionSample(t: t, level: 0))
        }
        XCTAssertFalse(tracker.state.pond.contains { $0.id == pondTrack.id }, "locked zone survives contradicting votes")
        XCTAssertTrue(tracker.events.contains { if case .stateRevised(.zoneOverride) = $0.kind { return true }; return false })
    }

    // MARK: - bulk overrideZone(tracks:) coalesces into one revision event

    func testBulkOverrideZoneMovesAllTracksAndLocksWithOneRevisionEvent() {
        var game = ScriptedGame(seed: 5_009)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        game.discard(.across, .p(9), at: 2.0)
        game.discard(.left, .m(9), at: 3.0)
        let tracker = run(game.frames())

        let pondIDs = tracker.state.pond.map(\.id)
        XCTAssertGreaterThanOrEqual(pondIDs.count, 3, "sanity: expected a pond of discards to bulk-reassign")

        let revisionEventsBefore = tracker.events.count { if case .stateRevised(.zoneOverride) = $0.kind { return true }; return false }

        tracker.overrideZone(tracks: pondIDs, to: .myHand)

        // All moved: none remain in the pond, all now show up in myHand.
        XCTAssertTrue(tracker.state.pond.isEmpty, "every bulk-reassigned track left the pond")
        for id in pondIDs {
            XCTAssertTrue(tracker.state.myHand.contains { $0.id == id }, "track \(id) moved to myHand")
        }

        // Exactly one new stateRevised(.zoneOverride) event for the whole batch.
        let revisionEventsAfter = tracker.events.count { if case .stateRevised(.zoneOverride) = $0.kind { return true }; return false }
        XCTAssertEqual(revisionEventsAfter, revisionEventsBefore + 1,
                       "one bulk call appends exactly one revision event, not N")

        // Zone-locked: contradicting settled ingest at the same spots doesn't
        // move them back to the pond.
        for i in 0..<8 {
            let t = 10.0 + Double(i) * 0.9
            let detections = pondIDs.compactMap { id -> DetectedTile? in
                guard let track = tracker.store.tracks.first(where: { $0.id == id }) else { return nil }
                return DetectedTile(tile: track.face, confidence: 0.9, box: track.box)
            }
            tracker.ingest(detections, at: t, motion: MotionSample(t: t, level: 0))
        }
        for id in pondIDs {
            XCTAssertTrue(tracker.state.myHand.contains { $0.id == id }, "locked zone survives contradicting votes")
        }
        XCTAssertTrue(tracker.state.pond.allSatisfy { !pondIDs.contains($0.id) },
                      "none of the bulk-reassigned tracks drifted back to the pond")
    }

    func testBulkOverrideZoneIsNoOpForEmptyInput() {
        var game = ScriptedGame(seed: 5_010)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())

        let eventCountBefore = tracker.events.count
        let revisionBefore = tracker.state.revision

        tracker.overrideZone(tracks: [], to: .myHand)

        XCTAssertEqual(tracker.events.count, eventCountBefore, "empty input appends no event")
        XCTAssertEqual(tracker.state.revision, revisionBefore, "empty input triggers no state reassembly")
    }

    // MARK: - amendEvent recomputes the seen histogram (stays correct)

    private func expectedHistogram(_ state: TrackedTableState) -> [Int] {
        var h = [Int](repeating: 0, count: Tile.baseClassCount)
        for t in state.pond where !t.face.isBonus { h[t.face.classIndex] += 1 }
        for (_, groups) in state.opponentMelds {
            for g in groups { for t in g where !t.face.isBonus { h[t.face.classIndex] += 1 } }
        }
        return h
    }

    func testAmendEventReattributesSeatAndKeepsHistogramCorrect() {
        var game = ScriptedGame(seed: 5_004)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())

        guard let discardEvent = tracker.events.first(where: {
            if case .discard = $0.kind { return true }; return false
        }) else { return XCTFail("expected a discard event") }

        XCTAssertEqual(tracker.state.seenHistogram, expectedHistogram(tracker.state), "histogram correct before the amendment")

        tracker.amendEvent(discardEvent.id, seat: .left)

        // A NEW amended event was appended (append-only log — the original stays).
        let amended = tracker.events.last { $0.flags.contains(.amended) }
        XCTAssertNotNil(amended)
        guard case let .discard(seat, tile, track) = amended?.kind else { return XCTFail("expected an amended discard") }
        XCTAssertEqual(seat, .left)
        XCTAssertEqual(tile, .s(1))

        // The pond track's seat is restamped, and the rotation re-anchors.
        XCTAssertEqual(tracker.state.pond.first { $0.id == track }?.seat, .left)
        XCTAssertEqual(tracker.turnEngine.currentTurn, .left.next)

        // State was rebuilt from scratch — histogram is still exactly right.
        XCTAssertEqual(tracker.state.seenHistogram, expectedHistogram(tracker.state), "histogram recomputed correctly after the amendment")
        XCTAssertTrue(tracker.events.contains { if case .stateRevised(.reattribute) = $0.kind { return true }; return false })
    }

    // MARK: - insertMissedTile / removeTrack / deleteEvent

    func testInsertMissedTileEntersHistogramAndSurvivesManyMisses() {
        let tracker = TableTracker()
        tracker.beginSession(mySeatWind: .east, roundWind: .east, at: 0)
        let before = tracker.state.seenHistogram[Tile.redDragon.classIndex]

        let id = tracker.insertMissedTile(face: .redDragon, zone: .pond, seat: .across, near: nil)
        XCTAssertEqual(tracker.state.seenHistogram[Tile.redDragon.classIndex], before + 1)
        XCTAssertTrue(tracker.state.pond.contains { $0.id == id && $0.isManual })

        for i in 0..<50 { tracker.ingest([], at: 1.0 + Double(i) * 0.5) }
        XCTAssertTrue(tracker.state.pond.contains { $0.id == id }, "a manually inserted tile is never auto-retired")
    }

    func testRemoveTrackDropsItFromPublishedState() {
        var game = ScriptedGame(seed: 5_005)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())

        guard let pondTrack = tracker.state.pond.first(where: { $0.face == .s(1) }) else {
            return XCTFail("expected an s1 in the pond")
        }
        tracker.removeTrack(pondTrack.id)
        XCTAssertFalse(tracker.state.pond.contains { $0.id == pondTrack.id })
        XCTAssertTrue(tracker.events.contains { if case .stateRevised(.removeTrack) = $0.kind { return true }; return false })
    }

    func testDeleteEventRemovesItButLeavesAnAuditTrailMarker() {
        var game = ScriptedGame(seed: 5_006)
        game.deal(myHand: dealHand())
        game.discard(.right, .s(1), at: 1.0)
        let tracker = run(game.frames())

        guard let discardEvent = tracker.events.first(where: {
            if case .discard = $0.kind { return true }; return false
        }) else { return XCTFail("expected a discard event") }

        tracker.deleteEvent(discardEvent.id)
        XCTAssertFalse(tracker.events.contains { $0.id == discardEvent.id })
        XCTAssertTrue(tracker.events.contains { if case .stateRevised(.eventDeleted) = $0.kind { return true }; return false })
    }

    // MARK: - confirmHandEnd resets per-hand state but preserves calibration

    func testConfirmHandEndResetsPerHandStateButPreservesCalibration() {
        var game = ScriptedGame(seed: 5_007)
        game.deal(myHand: dealHand())
        // The first action is deliberately delayed to 2.0s: calibration
        // needs `calibrationFrames`(5) *settled* frames with a parsed rank
        // before it locks, and at fps 10 the gap from t=0 to the first
        // action must be wide enough to contain them (settleDelay(0.7) +
        // 5 frames of headroom).
        game.discard(.right, .m(9), at: 2.0)
        game.discard(.across, .p(1), at: 4.0)
        game.clearTable(at: 6.5)
        let frames = extendCalm(game.frames(fps: 10, noise: NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0)),
                               by: TrackerConfig().handClearSustain + 3.0)

        let tracker = TableTracker()
        tracker.beginSession(mySeatWind: .east, roundWind: .east, at: 0)
        for f in frames { tracker.ingest(f.tiles, at: f.t, motion: f.motion) }

        XCTAssertTrue(tracker.zoneModel.isBandCalibrated, "sanity: the deal should have locked calibration")
        guard let proposal = tracker.pendingHandEnd else {
            return XCTFail("expected the sustained clear to have proposed a hand end")
        }
        XCTAssertNotNil(proposal.predictedWinds, "the facade fills in WindRotation's prediction for the UI card")

        let handIndexBefore = tracker.state.handIndex
        tracker.confirmHandEnd(winner: .me)

        XCTAssertNil(tracker.pendingHandEnd)
        XCTAssertEqual(tracker.state.handIndex, handIndexBefore + 1)
        // `.calibrating` gates on geometry not being trustworthy yet (per
        // its own doc) — since the hand-band lock is a *session* constant
        // that survives (asserted below), a second-or-later hand has
        // trustworthy zones from its very first frame and goes straight to
        // `.playing`, skipping a redundant re-calibration phase. `.playing`
        // with an empty table simply means "geometry known, no tiles seen
        // yet this hand" — the next `ingest` populates it.
        XCTAssertEqual(tracker.state.phase, .playing, "calibration already locked — no need to re-calibrate a later hand")
        XCTAssertTrue(tracker.state.myHand.isEmpty)
        XCTAssertTrue(tracker.state.pond.isEmpty)
        XCTAssertEqual(tracker.state.seenHistogram, Array(repeating: 0, count: Tile.baseClassCount))

        // I (dealer) won — HK Old Style repeats the deal.
        XCTAssertEqual(tracker.state.mySeatWind, .east)
        XCTAssertEqual(tracker.state.roundWind, .east)

        // Calibration is a session constant (static camera) — it survives.
        XCTAssertTrue(tracker.zoneModel.isBandCalibrated, "hand-band calibration survives a confirmed hand end")

        XCTAssertTrue(tracker.events.contains { if case .handEnded = $0.kind { return true }; return false })
        XCTAssertTrue(tracker.events.contains { e in
            if case let .handStarted(seat, round) = e.kind, e.handIndex == handIndexBefore + 1 {
                return seat == .east && round == .east
            }
            return false
        })
    }

    func testDismissHandEndClearsProposalWithoutResettingTracks() {
        var game = ScriptedGame(seed: 5_008)
        game.deal(myHand: dealHand())
        game.clearTable(at: 1.0)
        let frames = extendCalm(game.frames(fps: 10, noise: NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0)),
                               by: TrackerConfig().handClearSustain + 3.0)

        let tracker = TableTracker()
        tracker.beginSession(mySeatWind: .south, roundWind: .east, at: 0)
        for f in frames { tracker.ingest(f.tiles, at: f.t, motion: f.motion) }
        guard tracker.pendingHandEnd != nil else { return XCTFail("expected a pending proposal") }

        let handIndexBefore = tracker.state.handIndex
        tracker.dismissHandEnd()
        XCTAssertNil(tracker.pendingHandEnd)
        XCTAssertEqual(tracker.state.handIndex, handIndexBefore, "dismissing doesn't advance the hand")
        XCTAssertEqual(tracker.state.mySeatWind, .south, "winds are untouched by a dismissal")
        XCTAssertTrue(tracker.events.contains { if case .handEndCancelled = $0.kind { return true }; return false })
    }

    func testAutoHandEndDisabledSuppressesProposalButManualRequestStillWorks() {
        // The AR `.tableSpace` config turns the automatic table-clear detector
        // OFF (motion / reloc / TrackID churn mimic a sweep); hand-end there is
        // the user's manual call instead.
        var config = TrackerConfig()
        config.autoHandEndEnabled = false

        var game = ScriptedGame(seed: 5_010)
        game.deal(myHand: dealHand())
        game.clearTable(at: 1.0)
        let frames = extendCalm(game.frames(fps: 10, noise: NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0)),
                               by: TrackerConfig().handClearSustain + 3.0)

        let tracker = TableTracker(config: config)
        tracker.beginSession(mySeatWind: .east, roundWind: .east, at: 0)
        for f in frames { tracker.ingest(f.tiles, at: f.t, motion: f.motion) }

        // The same sustained clear that fires a proposal by default is suppressed.
        XCTAssertNil(tracker.pendingHandEnd, "auto hand-end must not fire when the detector is disabled")

        // The manual entry point proposes one — with the UI's wind prediction —
        // and flows through the existing confirm/dismiss machinery.
        tracker.requestHandEnd()
        guard let proposal = tracker.pendingHandEnd else {
            return XCTFail("requestHandEnd should manually propose a hand end")
        }
        XCTAssertNotNil(proposal.predictedWinds)
        XCTAssertEqual(tracker.state.phase, .endProposed)

        tracker.requestHandEnd()   // idempotent while one is pending
        XCTAssertNotNil(tracker.pendingHandEnd)

        tracker.dismissHandEnd()
        XCTAssertNil(tracker.pendingHandEnd)
    }
}
