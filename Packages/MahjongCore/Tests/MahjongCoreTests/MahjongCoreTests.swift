import XCTest
@testable import MahjongCore

final class TileTests: XCTestCase {
    func testClassIndexRoundTrips() {
        for i in 0..<Tile.classCount {
            XCTAssertEqual(Tile(classIndex: i)?.classIndex, i, "index \(i)")
        }
        XCTAssertNil(Tile(classIndex: -1))
        XCTAssertNil(Tile(classIndex: 42))
    }

    func testCanonicalCounts() {
        XCTAssertEqual(Tile.allCanonical.count, 42)
        XCTAssertEqual(Tile.allBase.count, 34)
        XCTAssertEqual(Set(Tile.allCanonical).count, 42, "no duplicate faces")
    }

    func testCanonicalOrderBoundaries() {
        XCTAssertEqual(Tile.m(1).classIndex, 0)
        XCTAssertEqual(Tile.p(1).classIndex, 9)
        XCTAssertEqual(Tile.s(1).classIndex, 18)
        XCTAssertEqual(Tile.east.classIndex, 27)
        XCTAssertEqual(Tile.redDragon.classIndex, 31)
        XCTAssertEqual(Tile.flower(.plum).classIndex, 34)
        XCTAssertEqual(Tile.season(.spring).classIndex, 38)
    }

    func testCodeRoundTrips() {
        for t in Tile.allCanonical {
            XCTAssertEqual(Tile(code: t.code), t, "code \(t.code)")
        }
        XCTAssertEqual(Tile(code: "1m"), .m(1))
        XCTAssertEqual(Tile(code: "9S"), .s(9))
        XCTAssertEqual(Tile(code: "rd"), .redDragon)
        XCTAssertEqual(Tile(code: "S"), .wind(.south))
        XCTAssertEqual(Tile(code: "S1"), .season(.spring))
        XCTAssertEqual(Tile(code: "F4"), .flower(.bamboo))
        XCTAssertNil(Tile(code: "0m"))
        XCTAssertNil(Tile(code: "F9"))
        XCTAssertNil(Tile(code: "zz"))
    }

    func testClassification() {
        XCTAssertTrue(Tile.m(1).isTerminal)
        XCTAssertTrue(Tile.m(9).isTerminal)
        XCTAssertFalse(Tile.m(5).isTerminal)
        XCTAssertTrue(Tile.m(5).isSimple)
        XCTAssertTrue(Tile.east.isHonor)
        XCTAssertTrue(Tile.redDragon.isTerminalOrHonor)
        XCTAssertTrue(Tile.flower(.plum).isBonus)
        XCTAssertFalse(Tile.flower(.plum).isSuited)
    }
}

final class HandParserTests: XCTestCase {
    private func tiles(_ codes: String...) -> [Tile] { codes.map { Tile(code: $0)! } }

    func testFourChowsPlusPairWins() {
        // 123m 456m 789m 123p 99s
        let hand = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","1p","2p","3p","9s","9s")
        XCTAssertTrue(HandParser.isWinningHand(concealed: hand))
        let d = HandParser.standardDecompositions(concealed: hand)
        XCTAssertFalse(d.isEmpty)
        XCTAssertTrue(d.allSatisfy { $0.melds.count == 4 && $0.pair != nil })
    }

    func testMixedPungsAndChowWins() {
        // 111m 234p 555s EEE + 7p7p pair, off a claimed pung
        let concealed = tiles("1m","1m","1m","2p","3p","4p","5s","5s","5s","7p","7p")
        let fixed = [Meld.pung(.east, isConcealed: false)]
        XCTAssertTrue(HandParser.isWinningHand(concealed: concealed, fixedMelds: fixed))
    }

    func testNonWinningHand() {
        let junk = tiles("1m","3m","5m","7m","9m","1p","3p","5p","7p","9p","1s","3s","5s","7s")
        XCTAssertFalse(HandParser.isWinningHand(concealed: junk))
    }

    func testSevenPairs() {
        let sp = tiles("1m","1m","3m","3m","2p","2p","5p","5p","4s","4s","7s","7s","RD","RD")
        XCTAssertNotNil(HandParser.sevenPairs(sp))
        XCTAssertTrue(HandParser.isWinningHand(concealed: sp))
        // A four-of-a-kind is not seven distinct pairs.
        let bad = tiles("1m","1m","1m","1m","2p","2p","5p","5p","4s","4s","7s","7s","RD","RD")
        XCTAssertNil(HandParser.sevenPairs(bad))
    }

    func testThirteenOrphans() {
        let to = tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD","1m")
        XCTAssertNotNil(HandParser.thirteenOrphans(to))
        XCTAssertTrue(HandParser.isWinningHand(concealed: to))
        let notAll = tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","5s","1m")
        XCTAssertNil(HandParser.thirteenOrphans(notAll))
    }

    func testBonusTilesIgnoredInShape() {
        let hand = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","1p","2p","3p","9s","9s","F1","S2")
        XCTAssertTrue(HandParser.isWinningHand(concealed: hand))
    }
}
