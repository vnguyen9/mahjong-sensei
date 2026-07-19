import XCTest
@testable import Recognition
import MahjongCore

/// Chunk B conservation tests (§10.3): physical constraints applied after
/// association and face fusion, downgrading the *lowest*-confidence
/// conflicting track rather than silently clamping totals.
final class ConservationTests: XCTestCase {

    private struct Fixture {
        var id: CensusTrackID
        var tile: Tile
        var confidence: Float
    }

    func testFifthCopyOfASuitedTileDowngradesTheWeakestTrack() {
        let fixtures = [
            Fixture(id: CensusTrackID(0), tile: .m(1), confidence: 5.0),
            Fixture(id: CensusTrackID(1), tile: .m(1), confidence: 3.0),
            Fixture(id: CensusTrackID(2), tile: .m(1), confidence: 4.0),
            Fixture(id: CensusTrackID(3), tile: .m(1), confidence: 2.0), // weakest
            Fixture(id: CensusTrackID(4), tile: .m(1), confidence: 6.0),
        ]

        let downgraded = Conservation.violatingTrackIDs(among: fixtures, tile: { $0.tile },
                                                         id: { $0.id }, confidence: { $0.confidence })

        XCTAssertEqual(downgraded, [CensusTrackID(3)])
    }

    func testASecondFlowerDowngradesTheWeakerOfTheTwo() {
        let fixtures = [
            Fixture(id: CensusTrackID(0), tile: .flower(.plum), confidence: 1.0), // weaker
            Fixture(id: CensusTrackID(1), tile: .flower(.plum), confidence: 9.0),
        ]

        let downgraded = Conservation.violatingTrackIDs(among: fixtures, tile: { $0.tile },
                                                         id: { $0.id }, confidence: { $0.confidence })

        XCTAssertEqual(downgraded, [CensusTrackID(0)])
    }

    func testAtOrUnderTheCapDowngradesNothing() {
        let fixtures = (0..<4).map { Fixture(id: CensusTrackID($0), tile: .dragon(.red), confidence: Float($0)) }

        let downgraded = Conservation.violatingTrackIDs(among: fixtures, tile: { $0.tile },
                                                         id: { $0.id }, confidence: { $0.confidence })

        XCTAssertTrue(downgraded.isEmpty)
    }

    func testEqualConfidenceTiesBreakOnAscendingTrackID() {
        let fixtures = [
            CensusTrackID(9), CensusTrackID(2), CensusTrackID(7), CensusTrackID(0), CensusTrackID(5),
        ].map { Fixture(id: $0, tile: .wind(.east), confidence: 1.0) } // all tied

        let downgraded = Conservation.violatingTrackIDs(among: fixtures, tile: { $0.tile },
                                                         id: { $0.id }, confidence: { $0.confidence })

        XCTAssertEqual(downgraded, [CensusTrackID(0)], "the lowest track ID must be the deterministic tie-break loser")
    }

    func testUnrelatedTilesDoNotInteract() {
        let fixtures =
            (0..<4).map { Fixture(id: CensusTrackID($0), tile: .m(1), confidence: 1.0) } +
            (0..<4).map { Fixture(id: CensusTrackID(10 + $0), tile: .p(2), confidence: 1.0) }

        let downgraded = Conservation.violatingTrackIDs(among: fixtures, tile: { $0.tile },
                                                         id: { $0.id }, confidence: { $0.confidence })

        XCTAssertTrue(downgraded.isEmpty, "4 copies of two different tiles is within cap for each")
    }
}
