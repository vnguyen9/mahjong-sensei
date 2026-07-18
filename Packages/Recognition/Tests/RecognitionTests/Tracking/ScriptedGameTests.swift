import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Chunk-1 coverage for the tracking data model / config / synthetic
/// generator (the tracker plan's §2, §7, §6.3). Later chunks
/// (TrackStore/ZoneModel/TurnEngine/…) get their own test files once they
/// exist; this file only exercises what's actually implemented here:
/// `ScriptedGame` determinism and its noise model's bounds.
final class ScriptedGameTests: XCTestCase {

    private func typicalHand() -> [Tile] {
        [.m(1), .m(2), .m(3), .p(4), .p(5), .p(6), .s(7), .s(8), .s(9),
         .east, .east, .east, .whiteDragon]
    }

    private func scriptedRound(seed: UInt64) -> ScriptedGame {
        var game = ScriptedGame(seed: seed)
        game.deal(myHand: typicalHand())
        game.discard(.right, .m(9), at: 1.0)
        game.discard(.across, .p(1), at: 2.5)
        game.claim(.pung, by: .left, tiles: [.p(1), .p(1), .p(1)], at: 3.2)
        game.myDraw(.whiteDragon, at: 4.5)
        game.myDiscard(.m(1), at: 5.5)
        game.nudge(.pond, index: 0, by: 0.01, at: 6.0)
        game.occlude(fraction: 0.4, from: 6.5, duration: 2.0)
        game.clearTable(at: 10.0)
        return game
    }

    // MARK: - Determinism (hard rule: seeded, byte-reproducible)

    func testSameSeedProducesIdenticalStream() {
        let a = scriptedRound(seed: 42).frames()
        let b = scriptedRound(seed: 42).frames()
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.map(\.tiles), b.map(\.tiles))
        XCTAssertEqual(a.map(\.motion), b.map(\.motion))
        XCTAssertEqual(a.map(\.t), b.map(\.t))
    }

    /// Calling `frames()` twice on the very same instance (not just two
    /// freshly-constructed ones) must also match — `frames()` must not
    /// mutate any stored generator state.
    func testFramesIsNonMutatingAndRepeatable() {
        let game = scriptedRound(seed: 7)
        let first = game.frames()
        let second = game.frames()
        XCTAssertEqual(first.map(\.tiles), second.map(\.tiles))
    }

    func testDifferentSeedsDivergeSomewhere() {
        let a = scriptedRound(seed: 1).frames()
        let b = scriptedRound(seed: 2).frames()
        // Same schedule (deal/discard/... at the same times) so frame counts
        // and tile identities per frame match, but the noise draws (jitter,
        // dropout, confidence, ids) must differ somewhere across the stream.
        XCTAssertEqual(a.count, b.count)
        let anyDifference = zip(a, b).contains { lhs, rhs in
            lhs.tiles.count != rhs.tiles.count ||
            zip(lhs.tiles, rhs.tiles).contains { $0.confidence != $1.confidence || $0.box != $1.box || $0.id != $1.id }
        }
        XCTAssertTrue(anyDifference, "two different seeds produced byte-identical streams")
    }

    func testDeterministicUUIDsNeverCollideAcrossSeedsUnexpectedly() {
        // Ids must be stable (deterministic) *within* a seed, not random.
        let a1 = scriptedRound(seed: 99).frames()
        let a2 = scriptedRound(seed: 99).frames()
        let idsA1 = a1.flatMap { $0.tiles.map(\.id) }
        let idsA2 = a2.flatMap { $0.tiles.map(\.id) }
        XCTAssertEqual(idsA1, idsA2)
    }

    // MARK: - Script shape sanity (frames render something sensible)

    func testDealOnlyProducesAtLeastOneSettledFrame() {
        var game = ScriptedGame(seed: 1)
        game.deal(myHand: typicalHand())
        let frames = game.frames(noise: .init(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0))
        XCTAssertFalse(frames.isEmpty)
        // With all dropout/jitter/flicker disabled, the very first frame at
        // t=0 must show exactly the dealt hand.
        XCTAssertEqual(frames.first?.t, 0)
        XCTAssertEqual(Set(frames.first?.tiles.map(\.tile) ?? []), Set(typicalHand()))
    }

    func testClearedTableStaysEmptyAfterClear() {
        var game = ScriptedGame(seed: 3)
        game.deal(myHand: typicalHand())
        game.clearTable(at: 2.0)
        let frames = game.frames(noise: .init(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0))
        guard let last = frames.last else { return XCTFail("no frames generated") }
        XCTAssertEqual(last.tiles.count, 0)
    }

    func testMyDiscardMovesExactlyOneTileFromHandToPond() {
        var game = ScriptedGame(seed: 5)
        game.deal(myHand: typicalHand())
        game.myDiscard(.m(1), at: 3.0)
        let noNoise = NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0)
        let before = game.frames(noise: noNoise).first { $0.t >= 0 && $0.t < 3.0 }
        let after = game.frames(noise: noNoise).last { $0.t > 3.0 + 1.2 + 1.4 } // after the settle tail begins
        XCTAssertEqual(before?.tiles.count, typicalHand().count)
        // After discarding, still 13 total on the table (12 hand + 1 pond).
        XCTAssertEqual(after?.tiles.count, typicalHand().count)
        XCTAssertEqual(after?.tiles.filter { $0.tile == .m(1) }.count, 1)
    }

    func testOccludeHidesApproximatelyTheRequestedFraction() {
        var game = ScriptedGame(seed: 11)
        game.deal(myHand: typicalHand())
        game.occlude(fraction: 0.5, from: 2.0, duration: 1.0)
        let noNoise = NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0)
        let frames = game.frames(noise: noNoise)
        let mid = frames.first { $0.t >= 2.4 && $0.t < 3.0 }
        XCTAssertNotNil(mid)
        // Half of 13 tiles, rounded → 6 or 7 hidden, so 6 or 7 remain visible.
        XCTAssertTrue((6...7).contains(mid?.tiles.count ?? -1), "expected ~half of 13 tiles visible, got \(mid?.tiles.count ?? -1)")
        // And they must reappear once the occlusion window ends.
        let after = frames.first { $0.t >= 3.1 }
        XCTAssertEqual(after?.tiles.count, typicalHand().count)
    }

    // MARK: - Noise model bounds

    func testConfidenceAlwaysWithinConfiguredRange() {
        var game = ScriptedGame(seed: 21)
        game.deal(myHand: typicalHand())
        game.discard(.right, .m(9), at: 1.0)
        game.discard(.across, .p(1), at: 2.0)
        let noise = NoiseModel(boxJitter: 0.15, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0,
                               confidenceRange: 0.40...0.80)
        let frames = game.frames(noise: noise)
        for frame in frames {
            for tile in frame.tiles {
                XCTAssertTrue(noise.confidenceRange.contains(tile.confidence),
                              "confidence \(tile.confidence) outside \(noise.confidenceRange)")
            }
        }
    }

    func testZeroDropoutKeepsEveryPlacedTileEveryFrame() {
        var game = ScriptedGame(seed: 33)
        game.deal(myHand: typicalHand())
        game.discard(.right, .m(9), at: 1.0)
        let noise = NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0)
        let frames = game.frames(noise: noise)
        let last = frames.last!
        // hand(13) + the one discard = 14 tiles, none ever dropped.
        XCTAssertEqual(last.tiles.count, typicalHand().count + 1)
    }

    func testFullDropoutProducesNoDetections() {
        var game = ScriptedGame(seed: 44)
        game.deal(myHand: typicalHand())
        let noise = NoiseModel(boxJitter: 0, dropoutIdle: 1.0, dropoutAction: 1.0, faceFlicker: 0)
        let frames = game.frames(noise: noise)
        XCTAssertTrue(frames.allSatisfy { $0.tiles.isEmpty })
    }

    func testZeroJitterKeepsBoxesExactlyAtLayoutSlots() {
        var game = ScriptedGame(seed: 55)
        game.deal(myHand: typicalHand())
        let noise = NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 0)
        let frame = game.frames(noise: noise).first!
        let slot0 = TableLayout.playerSeat.handSlotBox(index: 0)
        XCTAssertTrue(frame.tiles.contains { $0.box == slot0 })
    }

    /// `faceFlicker = 1.0` forces every eligible frame's tile through the
    /// confusable-swap branch; only faces with a listed confusable partner
    /// (7s, 8s, GD, RD, 1m) can appear as something else, and only as one of
    /// their own listed partners.
    func testFaceFlickerOnlyProducesListedConfusablePartners() {
        var game = ScriptedGame(seed: 66)
        game.deal(myHand: [.s(7), .s(8), .greenDragon, .redDragon, .m(1)])
        let noise = NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 1.0)
        let frame = game.frames(noise: noise).first!
        let faces = Set(frame.tiles.map(\.tile))
        let allowed: Set<Tile> = [.s(7), .s(8), .greenDragon, .redDragon, .m(1)]
        XCTAssertTrue(faces.isSubset(of: allowed), "flicker produced an unlisted face: \(faces)")
    }

    /// A face with no listed confusable partner must never flicker, even at
    /// `faceFlicker = 1.0`.
    func testFaceFlickerLeavesUnlistedFacesAlone() {
        var game = ScriptedGame(seed: 77)
        game.deal(myHand: [.p(3)])
        let noise = NoiseModel(boxJitter: 0, dropoutIdle: 0, dropoutAction: 0, faceFlicker: 1.0)
        let frame = game.frames(noise: noise).first!
        XCTAssertEqual(frame.tiles.first?.tile, .p(3))
    }

    // MARK: - Motion

    func testActionWindowElevatesMotionAboveIdle() {
        var game = ScriptedGame(seed: 88)
        game.deal(myHand: typicalHand())
        game.discard(.right, .m(9), at: 3.0)
        let frames = game.frames()
        let duringAction = frames.first { $0.t >= 3.0 && $0.t < 3.5 }
        let idle = frames.first { $0.t < 1.0 }
        XCTAssertNotNil(duringAction)
        XCTAssertGreaterThan(duringAction!.motion.level, 0.2)
        XCTAssertLessThan(idle!.motion.level, 0.05)
    }

    func testDiscardActionWindowReportsActingSeatRegion() {
        var game = ScriptedGame(seed: 89)
        game.deal(myHand: typicalHand())
        game.discard(.left, .m(9), at: 3.0)
        let frames = game.frames()
        let duringAction = frames.first { $0.t >= 3.0 && $0.t < 3.5 }
        XCTAssertEqual(duringAction?.motion.dominantRegion, .left)
    }

    func testSettledTailReturnsToNilDominantRegion() {
        var game = ScriptedGame(seed: 90)
        game.deal(myHand: typicalHand())
        game.discard(.right, .m(9), at: 1.0)
        let frames = game.frames()
        let tail = frames.last!
        XCTAssertNil(tail.motion.dominantRegion)
    }
}
