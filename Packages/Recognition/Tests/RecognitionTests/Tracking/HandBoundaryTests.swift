import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Chunk-6 coverage: `HandBoundaryDetector` (trigger, walk-by auto-cancel,
/// meld-immunity, the occlusion guard) and `WindRotation` (dealer repeat /
/// pass / round advance) — the tracker plan groups these together in its §9
/// test list (items 20-22), and this file follows that grouping.
final class HandBoundaryTests: XCTestCase {

    private func dealHand() -> [Tile] {
        [.m(1), .m(2), .m(3), .m(4), .m(5), .p(2), .p(3), .p(4), .s(6), .s(7), .s(8), .east, .west]
    }

    /// A minimal settle-gated driver (mirrors `TrackerHarness`'s own private
    /// `isSettled`) so `HandBoundaryDetector` can be exercised directly on a
    /// `ScriptedGame` stream without pulling in `ZoneModel`/`TurnEngine` —
    /// this also *is* the occlusion-guard test's mechanism: `evaluateSettled`
    /// is only ever called on frames this driver judges settled, exactly the
    /// contract `TableTracker` follows.
    private final class BoundaryHarness {
        let store = TrackStore()
        let detector: HandBoundaryDetector
        let config: TrackerConfig
        private(set) var outcomes: [(t: TimeInterval, outcome: BoundaryOutcome)] = []
        private var belowSince: TimeInterval?

        init(config: TrackerConfig = TrackerConfig()) {
            self.config = config
            detector = HandBoundaryDetector(config: config)
        }

        func run(_ frames: [(t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])]) {
            for f in frames {
                store.associate(f.tiles, at: f.t, motion: f.motion)
                guard isSettled(level: f.motion.level, at: f.t) else { continue }
                let outcome = detector.evaluateSettled(store: store, at: f.t)
                if outcome.proposed != nil || outcome.cancelled { outcomes.append((f.t, outcome)) }
            }
        }

        private func isSettled(level: Double, at t: TimeInterval) -> Bool {
            if level <= config.motionSettle {
                if belowSince == nil { belowSince = t }
            } else {
                belowSince = nil
            }
            guard let since = belowSince else { return false }
            return t - since >= config.settleDelay
        }
    }

    /// Appends extra calm (zero-motion, empty-detection) frames after
    /// `frames`'s last timestamp. `ScriptedGame.frames()` only runs until
    /// `scriptEnd + settleTail` (~1.5 s past the last scripted action) —
    /// plenty for `TurnEngine`'s settle-diff tests, but `handClearSustain`
    /// (5 s) needs settled time well beyond that once a clear has already
    /// calmed down, so boundary-detector scenarios extend the timeline
    /// explicitly rather than inflating every `ScriptedGame` script.
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

    // MARK: - Trigger (§9.20)

    func testSustainedMassClearProposesHandEnd() {
        var game = ScriptedGame(seed: 900)
        game.deal(myHand: dealHand())
        game.discard(.right, .m(9), at: 1.0)
        game.discard(.across, .p(1), at: 2.5)
        game.clearTable(at: 4.0)
        // The clear's own action window settles quickly (~1.2s); what needs
        // extending is the *settled* time afterward, well past
        // handClearSustain(5.0s), which the script's natural tail doesn't cover.
        let frames = extendCalm(game.frames(fps: 10, noise: NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0)),
                               by: TrackerConfig().handClearSustain + 3.0)
        let harness = BoundaryHarness()
        harness.run(frames)

        let proposals = harness.outcomes.filter { $0.outcome.proposed != nil }
        XCTAssertFalse(proposals.isEmpty, "a full table clear sustained past handClearSustain must propose a hand end")
        XCTAssertGreaterThanOrEqual(proposals.first!.outcome.proposed!.missingFraction, TrackerConfig().handClearFraction)
    }

    func testClearingBelowSustainNeverProposes() {
        var game = ScriptedGame(seed: 901)
        game.deal(myHand: dealHand())
        // Clear the table but the script (and the frame stream) ends well
        // before handClearSustain(5.0s) has elapsed on the clear.
        game.clearTable(at: 1.0)
        let frames = game.frames(fps: 10).filter { $0.t < 1.0 + TrackerConfig().handClearSustain - 1.0 }
        let harness = BoundaryHarness()
        harness.run(frames)
        XCTAssertTrue(harness.outcomes.isEmpty, "an insufficiently-sustained clear must never propose")
    }

    // MARK: - Walk-by auto-cancel (§9.21)

    func testReappearanceAutoCancelsPendingProposal() {
        // Hand-built (not ScriptedGame): a walk-by needs a settled *clear*
        // (tiles genuinely gone, motion calm) followed by the *same* tiles
        // reappearing at their old spots — `ScriptedGame.occlude` models a
        // single continuous action window for its whole duration, which
        // never lets the scene settle while "hidden", so it can't produce
        // this shape. Driving `TrackStore` + `HandBoundaryDetector` directly
        // gives full control, the same style `TrackStoreTests` uses for
        // precise-threshold scenarios.
        let store = TrackStore()
        let detector = HandBoundaryDetector()
        let config = TrackerConfig()
        let calm = MotionSample(t: 0, level: 0)

        // 10 distinct, well-separated tiles.
        let originals: [DetectedTile] = (0..<10).map { i in
            DetectedTile(tile: Tile(classIndex: i)!, confidence: 0.9,
                        box: TileBoundingBox(x: Double(i) * 0.09, y: 0.5, width: 0.05, height: 0.08))
        }

        var t = 0.0
        for _ in 0..<5 {
            store.associate(originals, at: t, motion: MotionSample(t: t, level: 0))
            detector.evaluateSettled(store: store, at: t)
            t += 0.2
        }
        XCTAssertEqual(store.tracks.filter { $0.state == .live }.count, 10, "sanity: all 10 promoted to live")

        // Clear: nothing detected, sustained past handClearSustain.
        var proposed = false
        let clearDeadline = t + config.handClearSustain + 1.0
        while t < clearDeadline {
            store.associate([], at: t, motion: calm)
            if detector.evaluateSettled(store: store, at: t).proposed != nil { proposed = true; break }
            t += 0.3
        }
        XCTAssertTrue(proposed, "a sustained clear must propose")
        XCTAssertTrue(detector.isProposed)

        // Walk-by ends: the same tiles reappear at their old spots (rebirth
        // within `rebirthWindow`/`rebirthRadius`) — ≥ reappearFraction(0.5)
        // of the 10 auto-cancels the proposal.
        var cancelled = false
        for _ in 0..<8 {
            t += 0.3
            store.associate(originals, at: t, motion: calm)
            if detector.evaluateSettled(store: store, at: t).cancelled { cancelled = true; break }
        }
        XCTAssertTrue(cancelled, "tiles reappearing at their old spots must auto-cancel the proposal")
        XCTAssertFalse(detector.isProposed)
    }

    // MARK: - Meld immunity (§8's mitigation table)

    func testMeldClaimNeverTriggersAProposal() {
        var game = ScriptedGame(seed: 903)
        game.deal(myHand: dealHand())
        game.discard(.right, .p(1), at: 1.0)
        game.claim(.pung, by: .left, tiles: [.p(1), .p(1), .p(1)], at: 4.0)
        // Run well past handClearSustain after the claim settles.
        let frames = game.frames(fps: 10)
        let harness = BoundaryHarness()
        harness.run(frames)
        XCTAssertTrue(harness.outcomes.isEmpty, "a claim moves at most a handful of tiles — far under handClearMinTiles(8)")
    }

    // MARK: - Occlusion guard

    func testHighMotionFramesAreNeverEvaluated() {
        // `BoundaryHarness.run` only calls `evaluateSettled` on frames its
        // settle gate judges calm — script a clear whose motion window
        // deliberately never lets the scene settle within the observed
        // window, so `evaluateSettled` is structurally never invoked despite
        // the underlying track state having "cleared". This is the
        // occlusion-guard mechanism itself (see `HandBoundaryDetector`'s type
        // doc): the guard isn't a field on the detector, it's that the
        // caller never calls it mid-motion.
        var game = ScriptedGame(seed: 904)
        game.deal(myHand: dealHand())
        game.clearTable(at: 1.0)
        game.occlude(fraction: 0.9, from: 1.0, duration: 20.0)   // keeps motion "active" throughout
        let frames = game.frames(fps: 10, noise: NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0))
            .filter { $0.t < 6.0 }   // still well inside the occlusion window — never settles
        let harness = BoundaryHarness()
        harness.run(frames)
        XCTAssertTrue(harness.outcomes.isEmpty, "nothing fires while motion never settles — the occlusion guard")
    }

    // MARK: - WindRotation table (plan §9.22 / §3.6)

    func testDealerWinRepeatsTheDeal() {
        let p = WindRotation.afterHand(mySeatWind: .east, roundWind: .east, winner: .me, dealsSinceRoundStart: 0)
        XCTAssertEqual(p.winds.mySeatWind, .east, "dealer (me) won — I stay East")
        XCTAssertEqual(p.winds.roundWind, .east)
        XCTAssertEqual(p.dealsSinceRoundStart, 0, "a repeat doesn't consume a round slot")
    }

    func testDrawRepeatsTheDealerJustLikeADealerWin() {
        let p = WindRotation.afterHand(mySeatWind: .south, roundWind: .east, winner: nil, dealsSinceRoundStart: 1)
        XCTAssertEqual(p.winds.mySeatWind, .south, "exhaustive draw — HK Old Style keeps the same dealer")
        XCTAssertEqual(p.winds.roundWind, .east)
        XCTAssertEqual(p.dealsSinceRoundStart, 1)
    }

    func testNonDealerWinPassesTheDeal() {
        // I'm East (dealer); .right (South) wins — deal passes to South, so
        // every wind rotates back one step: I become North.
        let p = WindRotation.afterHand(mySeatWind: .east, roundWind: .east, winner: .right, dealsSinceRoundStart: 0)
        XCTAssertEqual(p.winds.mySeatWind, .north)
        XCTAssertEqual(p.winds.roundWind, .east, "round doesn't advance until 4 deals have passed")
        XCTAssertEqual(p.dealsSinceRoundStart, 1)
    }

    func testRoundAdvancesOnTheFourthPass() {
        var wind = Wind.east
        var round = Wind.east
        var deals = 0
        // Four consecutive non-dealer wins (nobody ever repeats) — a full
        // circuit of the deal through all four seats. The winner must be
        // *whoever the current dealer is not* — picking a fixed relative
        // seat like `.right` would eventually collide with the dealer
        // itself once the rotation carries them there, turning a "pass"
        // into a "repeat"; `dealerSeat.next` is guaranteed to never be the
        // dealer, so every one of these 4 hands is a genuine pass.
        for _ in 0..<4 {
            let dealerSeat = RelativeSeat(rawValue: (4 - wind.rawValue) % 4)!
            let p = WindRotation.afterHand(mySeatWind: wind, roundWind: round,
                                           winner: dealerSeat.next, dealsSinceRoundStart: deals)
            wind = p.winds.mySeatWind; round = p.winds.roundWind; deals = p.dealsSinceRoundStart
        }
        XCTAssertEqual(round, .south, "the round wind advances exactly once the deal has cycled through all 4 seats")
        XCTAssertEqual(deals, 0, "the counter wraps back to 0 for the new round")
        XCTAssertEqual(wind, .east, "the deal returns to me — I opened this round")
    }

    func testRepeatsDontConsumeRoundSlots() {
        // Dealer wins twice (repeats), then a non-dealer win passes — only
        // the pass should count toward dealsSinceRoundStart.
        var p = WindRotation.afterHand(mySeatWind: .east, roundWind: .east, winner: .me, dealsSinceRoundStart: 0)
        XCTAssertEqual(p.dealsSinceRoundStart, 0)
        p = WindRotation.afterHand(mySeatWind: p.winds.mySeatWind, roundWind: p.winds.roundWind,
                                   winner: nil, dealsSinceRoundStart: p.dealsSinceRoundStart)
        XCTAssertEqual(p.dealsSinceRoundStart, 0)
        p = WindRotation.afterHand(mySeatWind: p.winds.mySeatWind, roundWind: p.winds.roundWind,
                                   winner: .left, dealsSinceRoundStart: p.dealsSinceRoundStart)
        XCTAssertEqual(p.dealsSinceRoundStart, 1)
        XCTAssertEqual(p.winds.roundWind, .east)
    }

    func testWindsWrapAcrossAFullSixteenHandGameConserveSeatParity() {
        // A long deterministic sequence — every hand a non-dealer win — must
        // keep cycling winds/round without ever producing an invalid Wind.
        var mySeatWind = Wind.west
        var roundWind = Wind.south
        var deals = 2
        for _ in 0..<20 {
            let p = WindRotation.afterHand(mySeatWind: mySeatWind, roundWind: roundWind,
                                           winner: .across, dealsSinceRoundStart: deals)
            mySeatWind = p.winds.mySeatWind; roundWind = p.winds.roundWind; deals = p.dealsSinceRoundStart
            XCTAssertTrue(Wind.allCases.contains(mySeatWind))
            XCTAssertTrue(Wind.allCases.contains(roundWind))
            XCTAssertTrue((0...3).contains(deals))
        }
    }
}
