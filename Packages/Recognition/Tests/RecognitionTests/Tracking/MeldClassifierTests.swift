import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Chunk-6 coverage: `MeldClassifier` — the shape test (pung/kong/chow/
/// reject), the physical-proximity grouper, and the `TrackedTableState`
/// conveniences (`meldsAsMelds`, `hand(isSelfDraw:)`) the plan's §2.3 deferred
/// from chunk 1 (tracker plan's §9.27 test list item).
final class MeldClassifierTests: XCTestCase {

    // MARK: - classify (§9.27)

    func testTripletClassifiesAsPung() {
        XCTAssertEqual(MeldClassifier.classify([.dragon(.red), .dragon(.red), .dragon(.red)]), .pung)
    }

    func testQuadClassifiesAsKong() {
        XCTAssertEqual(MeldClassifier.classify(Array(repeating: Tile.wind(.west), count: 4)), .kong)
    }

    func testConsecutiveSameSuitClassifiesAsChow() {
        XCTAssertEqual(MeldClassifier.classify([.s(4), .s(5), .s(6)]), .chow)
        // Order-independent: sorts internally.
        XCTAssertEqual(MeldClassifier.classify([.s(6), .s(4), .s(5)]), .chow)
    }

    func testMixedSuitRejectsAsNonMeld() {
        XCTAssertNil(MeldClassifier.classify([.m(4), .p(5), .s(6)]))
    }

    func testGappedRunRejects() {
        XCTAssertNil(MeldClassifier.classify([.s(4), .s(5), .s(7)]))
    }

    func testHonorsCantFormAChow() {
        XCTAssertNil(MeldClassifier.classify([.east, .south, .west]))
    }

    func testWrongCountRejects() {
        XCTAssertNil(MeldClassifier.classify([.m(1), .m(1)]))
        XCTAssertNil(MeldClassifier.classify(Array(repeating: Tile.m(1), count: 5)))
        XCTAssertNil(MeldClassifier.classify([]))
    }

    func testBonusTilesNeverFormAMeld() {
        XCTAssertNil(MeldClassifier.classify([.flower(.plum), .flower(.orchid), .flower(.chrysanthemum)]))
    }

    func testThreeUnequalHonorsReject() {
        XCTAssertNil(MeldClassifier.classify([.dragon(.red), .dragon(.green), .dragon(.white)]))
    }

    // MARK: - physicalGroups / melds(groupingTracks:)

    private func tile(_ face: Tile, _ cx: Double, _ cy: Double, zone: TileZone = .myMeld) -> TrackedTile {
        TrackedTile(id: TrackID(raw: Int(cx * 1000) + Int(cy * 1_000_000)), face: face,
                   box: TileBoundingBox(x: cx - 0.023, y: cy - 0.037, width: 0.047, height: 0.075),
                   zone: zone, firstSeen: 0, lastSeen: 0)
    }

    func testPhysicalGroupsSplitsTwoDistantClusters() {
        let near = [tile(.east, 0.80, 0.84), tile(.east, 0.847, 0.84), tile(.east, 0.894, 0.84)]
        let far = [tile(.p(1), 0.10, 0.10), tile(.p(2), 0.147, 0.10), tile(.p(3), 0.194, 0.10)]
        let groups = MeldClassifier.physicalGroups(of: near + far)
        XCTAssertEqual(groups.count, 2, "two spatially distant clusters stay separate")
        XCTAssertEqual(Set(groups.map(\.count)), [3])
    }

    func testMeldsGroupingTracksClassifiesEachClusterAndDropsInvalidOnes() {
        let pung = [tile(.east, 0.80, 0.84), tile(.east, 0.847, 0.84), tile(.east, 0.894, 0.84)]
        // A stray pair far away — 2 tiles, never a valid meld shape, must be dropped.
        let strayPair = [tile(.m(1), 0.10, 0.10), tile(.m(2), 0.147, 0.10)]
        let melds = MeldClassifier.melds(groupingTracks: pung + strayPair, isConcealed: false)
        XCTAssertEqual(melds.count, 1, "the stray pair never classifies, so only the pung survives")
        XCTAssertEqual(melds.first?.kind, .pung)
        XCTAssertEqual(melds.first?.tiles, [.east, .east, .east])
        XCTAssertFalse(melds.first!.isConcealed)
    }

    func testMeldsGroupingTracksHandlesEmptyInput() {
        XCTAssertEqual(MeldClassifier.melds(groupingTracks: []), [])
    }

    // MARK: - TrackedTableState.meldsAsMelds / hand(isSelfDraw:)

    func testMeldsAsMeldsBuildsFromGroupedTracks() {
        var state = TrackedTableState.empty
        state.myMelds = [[tile(.east, 0.80, 0.84), tile(.east, 0.847, 0.84), tile(.east, 0.894, 0.84)],
                         [tile(.s(4), 0.5, 0.5), tile(.s(5), 0.547, 0.5), tile(.s(6), 0.594, 0.5)]]
        let melds = state.meldsAsMelds
        XCTAssertEqual(melds.count, 2)
        XCTAssertTrue(melds.contains { $0.kind == .pung && $0.tiles == [.east, .east, .east] })
        XCTAssertTrue(melds.contains { $0.kind == .chow && $0.tiles == [.s(4), .s(5), .s(6)] })
    }

    func testMeldsAsMeldsDropsAMalformedGroup() {
        var state = TrackedTableState.empty
        // Only 2 tiles in this "group" — never a valid meld shape.
        state.myMelds = [[tile(.m(1), 0.1, 0.1), tile(.m(2), 0.15, 0.1)]]
        XCTAssertTrue(state.meldsAsMelds.isEmpty)
    }

    func testHandIsSelfDrawBuildsConcealedMeldsAndBonusFromState() {
        var state = TrackedTableState.empty
        state.myHand = [tile(.m(1), 0.1, 0.9, zone: .myHand), tile(.m(2), 0.15, 0.9, zone: .myHand)]
        state.myBonus = [tile(.flower(.plum), 0.05, 0.7, zone: .myBonus)]
        state.myMelds = [[tile(.east, 0.80, 0.84), tile(.east, 0.847, 0.84), tile(.east, 0.894, 0.84)]]

        let hand = state.hand(isSelfDraw: true)
        XCTAssertEqual(hand.concealedTiles, [.m(1), .m(2)])
        XCTAssertEqual(hand.bonusTiles, [.flower(.plum)])
        XCTAssertEqual(hand.melds, [Meld(kind: .pung, tiles: [.east, .east, .east], isConcealed: false)])
        XCTAssertNil(hand.winningTile)
        XCTAssertTrue(hand.isSelfDraw)

        let claimed = state.hand(isSelfDraw: false)
        XCTAssertFalse(claimed.isSelfDraw)
    }
}
