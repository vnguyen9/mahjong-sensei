import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Chunk-5 coverage: `TurnEngine` — settle-diff event derivation, seat
/// attribution, meld-claim linking, evidence-over-prior turn resync, and the
/// my-draw/my-discard hand-count machinery (the tracker plan's §3.4 and the
/// TurnEngine subset of its §9 test list). Everything runs through
/// `TrackerHarness` on `ScriptedGame` streams with a simulated clock, so the
/// "nothing commits mid-motion" contract is exercised end-to-end rather than
/// asserted in the abstract.
final class TurnEngineTests: XCTestCase {

    private func dealHand() -> [Tile] {
        [.m(1), .m(2), .m(3), .m(4), .m(5), .p(2), .p(3), .p(4), .s(6), .s(7), .s(8), .east, .west]
    }

    private func discards(_ events: [GameEvent]) -> [(seat: RelativeSeat, tile: Tile, conf: Double, amber: Bool)] {
        events.compactMap {
            if case let .discard(seat, tile, _) = $0.kind {
                return (seat, tile, $0.confidence, $0.flags.contains(.uncertainAttribution))
            }
            return nil
        }
    }

    // MARK: - Single discard, and nothing during the action window (§9.12)

    func testSingleOpponentDiscardEmitsOnceAfterSettle() {
        var game = ScriptedGame(seed: 100)
        game.deal(myHand: dealHand())
        game.discard(.right, .m(9), at: 1.0)
        let harness = TrackerHarness()
        let events = harness.run(game.frames())

        XCTAssertEqual(events.count, 1, "exactly one event for one discard, got \(events.map(\.kind))")
        let d = discards(events)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.seat, .right)
        XCTAssertEqual(d.first?.tile, .m(9))
        XCTAssertGreaterThanOrEqual(d.first!.conf, 0.55, "confident attribution")
        XCTAssertFalse(d.first!.amber)
        // Every event lands on a settled frame — never mid-motion.
        for e in events { XCTAssertTrue(harness.settledTimes.contains(e.at), "event at \(e.at) not a settled frame") }
        XCTAssertGreaterThan(events.first!.at, 1.0 + TrackerConfig().settleDelay, "fired after the action settled")
    }

    // MARK: - Full go-around attributed by seat (§9.13)

    func testFullRotationAttributedToEachSeat() {
        var game = ScriptedGame(seed: 101)
        game.deal(myHand: dealHand())
        game.myDiscard(.m(1), at: 1.0)          // anchors currentTurn = .right
        game.discard(.right, .s(1), at: 3.0)
        game.discard(.across, .s(2), at: 5.0)
        game.discard(.left, .s(3), at: 7.0)
        let harness = TrackerHarness()
        let events = harness.run(game.frames())

        // One myDiscard then three opponent discards, each to the expected seat.
        XCTAssertEqual(events.count, 4, "1 myDiscard + 3 discards, got \(events.map(\.kind))")
        guard case .myDiscard(let t0, _) = events.first?.kind else { return XCTFail("first is myDiscard") }
        XCTAssertEqual(t0, .m(1))

        let d = discards(events)
        XCTAssertEqual(d.map(\.seat), [.right, .across, .left])
        XCTAssertEqual(d.map(\.tile), [.s(1), .s(2), .s(3)])
        for one in d {
            XCTAssertGreaterThanOrEqual(one.conf, 0.55, "prior + agreeing motion → confident")
            XCTAssertFalse(one.amber)
        }
        XCTAssertEqual(harness.turnEngine.currentTurn, .me, "after .left it's back to me")
    }

    // MARK: - Evidence over prior: resync (§9.14)

    func testOutOfPriorDiscardTriggersEvidenceOverPriorResync() {
        var game = ScriptedGame(seed: 102)
        game.deal(myHand: dealHand())
        game.myDiscard(.m(1), at: 1.0)          // anchors prior to .right …
        game.discard(.left, .s(1), at: 3.0)     // … but .left actually discards
        let harness = TrackerHarness()
        let events = harness.run(game.frames())

        let d = discards(events)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.seat, .left, "motion+geometry override the stale .right prior")
        XCTAssertEqual(harness.turnEngine.currentTurn, .me, "rotation re-anchors from .left → .me")
    }

    // MARK: - Meld claim steals the turn (§9.15)

    func testPungClaimStealsTurnAndKeepsSubsequentAttributionCorrect() {
        var game = ScriptedGame(seed: 103)
        game.deal(myHand: dealHand())
        game.discard(.right, .p(1), at: 1.0)    // .right discards → prior would be .across next
        game.claim(.pung, by: .left, tiles: [.p(1), .p(1), .p(1)], at: 4.0)   // .left steals it
        game.discard(.left, .s(9), at: 6.5)     // the claimer discards next
        let harness = TrackerHarness()
        let events = harness.run(game.frames())

        // discard(.right) → meld(.left, pung, claimedFrom .right) → discard(.left)
        guard let meld = events.first(where: { if case .meld = $0.kind { return true }; return false }) else {
            return XCTFail("expected a meld event, got \(events.map(\.kind))")
        }
        guard case let .meld(seat, kind, tiles, claimedTile, claimedFrom) = meld.kind else { return XCTFail() }
        XCTAssertEqual(seat, .left)
        XCTAssertEqual(kind, .pung)
        XCTAssertEqual(tiles, [.p(1), .p(1), .p(1)])
        XCTAssertEqual(claimedTile, .p(1))
        XCTAssertEqual(claimedFrom, .right, "the pung was claimed off .right's discard")

        // The claimed tile is still on the table (now in the meld) — not lost.
        XCTAssertEqual(harness.store.tracks.filter { $0.zone == .opponentMeld && $0.face == .p(1) }.count, 3)

        // Turn was stolen to .left; its follow-up discard is attributed to .left.
        let last = discards(events).last
        XCTAssertEqual(last?.seat, .left, "claimer discards next, attributed correctly")
    }

    // MARK: - My draw / my discard fire exactly once each (§9.17/§9.18)

    func testMyDrawAndMyDiscardEachFireExactlyOnce() {
        var game = ScriptedGame(seed: 104)
        game.deal(myHand: dealHand())
        game.myDraw(.whiteDragon, at: 1.0)      // 13 → 14, sustained
        game.myDiscard(.m(1), at: 5.0)          // 14 → 13, links hand-loss to pond-birth
        let harness = TrackerHarness()
        let events = harness.run(game.frames())

        let draws = events.filter { if case .myDraw = $0.kind { return true }; return false }
        XCTAssertEqual(draws.count, 1, "exactly one myDraw, got \(events.map(\.kind))")
        if case let .myDraw(tile) = draws.first?.kind {
            XCTAssertEqual(tile, .whiteDragon, "drawn face settles and is reported")
        }

        let myDiscards = events.compactMap { if case let .myDiscard(t, _) = $0.kind { return t }; return nil }
        XCTAssertEqual(myDiscards, [.m(1)], "exactly one myDiscard of the tile that left the hand")
    }

    // MARK: - Nothing emitted during motion (occlude / nudge) (§9.17)

    func testOcclusionAndNudgeEmitNoEvents() {
        var occ = ScriptedGame(seed: 105)
        occ.deal(myHand: dealHand())
        occ.occlude(fraction: 0.5, from: 1.0, duration: 1.5)   // arm sweeps across; tiles return
        XCTAssertTrue(TrackerHarness().run(occ.frames()).isEmpty, "occlusion alone is never an event")

        var nud = ScriptedGame(seed: 106)
        nud.deal(myHand: dealHand())
        nud.nudge(.myHand, index: 0, by: 0.04, at: 1.0)        // a tile gets bumped in place
        XCTAssertTrue(TrackerHarness().run(nud.frames()).isEmpty, "an intra-zone nudge is never an event")
    }

    func testOcclusionWobbleDoesNotFireASpuriousDraw() {
        // A hand momentarily half-hidden (count dips mid-motion) then whole
        // again must not read as a draw — the dip never becomes a settled diff.
        var game = ScriptedGame(seed: 107)
        game.deal(myHand: dealHand())
        game.occlude(fraction: 0.4, from: 1.0, duration: 1.0)
        game.discard(.right, .m(9), at: 4.0)   // extends the timeline past the wobble
        let events = TrackerHarness().run(game.frames())
        XCTAssertFalse(events.contains { if case .myDraw = $0.kind { return true }; return false },
                       "no draw from an occlusion wobble")
        XCTAssertEqual(events.filter { if case .discard = $0.kind { return true }; return false }.count, 1)
    }

    // MARK: - Win predicate (injected) fires once (§9.31)

    func testMyHandCompleteFiresOnceWhenPredicateReturnsTrue() {
        var config = TrackerConfig()
        config.winPredicate = { faces, _ in faces.count == 14 }   // stub; real ScoringEngine injected by the facade
        var game = ScriptedGame(seed: 108)
        game.deal(myHand: dealHand())
        game.myDraw(.whiteDragon, at: 1.0)
        game.discard(.right, .m(9), at: 5.0)     // extends the timeline
        let events = TrackerHarness(config: config).run(game.frames())

        XCTAssertEqual(events.filter { if case .myHandComplete = $0.kind { return true }; return false }.count, 1,
                       "myHandComplete fires once on the 14-tile rising edge")
    }

    // MARK: - Determinism (hard rule)

    func testDeterministicEventStreamForSameScriptAndSeed() {
        func stream(seed: UInt64) -> [GameEvent] {
            var game = ScriptedGame(seed: seed)
            game.deal(myHand: dealHand())
            game.myDiscard(.m(1), at: 1.0)
            game.discard(.right, .s(1), at: 3.0)
            game.claim(.pung, by: .across, tiles: [.s(1), .s(1), .s(1)], at: 5.0)
            game.discard(.across, .p(9), at: 7.0)
            return TrackerHarness().run(game.frames())
        }
        XCTAssertEqual(stream(seed: 2024), stream(seed: 2024), "same script+seed → byte-identical events")
    }

    // MARK: - Kong upgrade (hand-built; ScriptedGame can't do in-place upgrades)

    func testAddedFourthTileUpgradesPungToKong() {
        let harness = TrackerHarness()
        func frame(_ dets: [DetectedTile], _ t: TimeInterval) -> (t: TimeInterval, motion: MotionSample, tiles: [DetectedTile]) {
            (t, MotionSample(t: t, level: 0.0), dets)   // calm → settles
        }
        func box(_ cx: Double, _ cy: Double) -> TileBoundingBox {
            TileBoundingBox(x: cx - 0.0235, y: cy - 0.0375, width: 0.047, height: 0.075)
        }
        // Tiles spaced ~0.09 apart: wider than the association center-gate (so
        // each births its own track) but within the cluster reach (so they form
        // one meld group).
        let pung = [DetectedTile(tile: .east, confidence: 0.9, box: box(0.94, 0.41)),
                    DetectedTile(tile: .east, confidence: 0.9, box: box(0.94, 0.50)),
                    DetectedTile(tile: .east, confidence: 0.9, box: box(0.94, 0.59))]
        // My 13-tile rank along the bottom. Without it the scene is degenerate:
        // the moment the kong reaches 4 tiles it becomes the frame's only
        // hand-eligible cluster (`minHandCount`) and the parser calls the KONG
        // "mine" — in any real frame the rank anchors that pick instead.
        let rank: [DetectedTile] = [Tile.m(1), .m(2), .m(3), .m(4), .m(5), .p(2), .p(3),
                                    .p(4), .s(6), .s(7), .s(8), .east, .west]
            .enumerated().map { i, face in
                DetectedTile(tile: face, confidence: 0.9, box: box(0.17 + Double(i) * 0.055, 0.90))
            }
        // Phase A: an opponent pung settles and baselines (no claim event — no prior discard).
        var t = 0.0
        for _ in 0..<10 { harness.step(frame(rank + pung, t)); t += 0.15 }
        XCTAssertEqual(harness.store.tracks.filter { $0.zone == .opponentMeld }.count, 3)

        // Phase B: a 4th matching tile joins the group → kong upgrade.
        let kong = pung + [DetectedTile(tile: .east, confidence: 0.9, box: box(0.94, 0.68))]
        for _ in 0..<10 { harness.step(frame(rank + kong, t)); t += 0.15 }

        let upgrade = harness.events.first { if case let .meld(_, kind, _, _, _) = $0.kind { return kind == .kong }; return false }
        XCTAssertNotNil(upgrade, "the 4th tile promotes the pung to a kong")
        XCTAssertTrue(upgrade?.flags.contains(.upgradedFromPung) ?? false)
    }
}
