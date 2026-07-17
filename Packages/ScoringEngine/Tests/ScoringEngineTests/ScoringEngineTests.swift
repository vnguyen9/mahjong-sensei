import XCTest
import MahjongCore
@testable import ScoringEngine

final class ScoringEngineTests: XCTestCase {

    // MARK: Helpers

    /// Builds tiles from 42-class codes ("1m", "E", "RD", "F1", …).
    private func tiles(_ codes: String...) -> [Tile] { codes.map { Tile(code: $0)! } }
    private func tiles(_ codes: [String]) -> [Tile] { codes.map { Tile(code: $0)! } }

    /// East seat & round, no flowers scored — isolates structural faan.
    private func plainContext(minimumFaan: Int = 3,
                              faanLimit: Int = 10,
                              scoreFlowers: Bool = false,
                              seat: Wind = .east,
                              prevailing: Wind = .east) -> GameContext {
        GameContext(seatWind: seat,
                    prevailingWind: prevailing,
                    houseRules: HouseRules(minimumFaan: minimumFaan,
                                           faanLimit: faanLimit,
                                           scoreFlowers: scoreFlowers))
    }

    // MARK: Winning-shape detection

    func testIsWinningShape() {
        let win = Hand(concealedTiles: tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","1p","2p","3p","9s","9s"))
        XCTAssertTrue(ScoringEngine.isWinningShape(win))
        let junk = Hand(concealedTiles: tiles("1m","3m","5m","7m","9m","1p","3p","5p","7p","9p","1s","3s","5s","7s"))
        XCTAssertFalse(ScoringEngine.isWinningShape(junk))
    }

    func testNonWinningHandScoresNothing() {
        let junk = Hand(concealedTiles: tiles("1m","3m","5m","7m","9m","1p","3p","5p","7p","9p","1s","3s","5s","7s"))
        let r = ScoringEngine.score(hand: junk, context: plainContext())
        XCTAssertFalse(r.isWin)
        XCTAssertTrue(r.components.isEmpty)
        XCTAssertEqual(r.totalFaan, 0)
        XCTAssertNil(r.winningDecomposition)
    }

    // MARK: Chicken hand

    func testChickenHandScoresZero() {
        // Mixed-suit all-chow hand won on a discard with an exposed meld: no yaku.
        let hand = Hand(concealedTiles: tiles("4m","5m","6m","7m","8m","9m","1p","2p","3p","5s","5s"),
                        melds: [Meld.chow(.m(1), isConcealed: false)!],
                        winningTile: .s(5),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.isWin)
        XCTAssertEqual(r.totalFaan, 0)
        XCTAssertEqual(r.components.map(\.category), [.chickenHand])
        XCTAssertFalse(r.meetsMinimum, "0 faan is below the 3-faan minimum")
    }

    // MARK: Self-draw / concealment

    func testConcealedSelfDraw() {
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","5m","6m","7m","2p","3p","4p","5p","6p","7p","9s","9s"),
                        winningTile: .m(4),
                        isSelfDraw: true)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.isWin)
        XCTAssertTrue(r.contains(.selfDraw))
        XCTAssertFalse(r.contains(.fullyConcealed), "self-draw takes precedence over 門前清")
        XCTAssertEqual(r.faan(for: .selfDraw), 1)
        XCTAssertEqual(r.rawFaan, 1)
        XCTAssertFalse(r.meetsMinimum, "1 faan is below the 3-faan minimum")
    }

    func testFullyConcealedByDiscard() {
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","5m","6m","7m","2p","3p","4p","5p","6p","7p","9s","9s"),
                        winningTile: .m(4),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.contains(.fullyConcealed))
        XCTAssertFalse(r.contains(.selfDraw))
        XCTAssertEqual(r.faan(for: .fullyConcealed), 1)
    }

    // MARK: Structural

    func testAllTriplets() {
        // Four pungs (one exposed) + a pair, across three suits so it is not a flush.
        let hand = Hand(concealedTiles: tiles("3p","3p","3p","5s","5s","5s","7m","7m","7m","9p","9p"),
                        melds: [Meld.pung(.m(1), isConcealed: false)],
                        winningTile: .p(9),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertEqual(r.faan(for: .allTriplets), 3)
        XCTAssertEqual(r.totalFaan, 3)
        XCTAssertTrue(r.meetsMinimum)
    }

    func testHalfFlush() {
        // Bamboo + an East (honor) pung, round/seat = South so East scores no wind faan.
        let hand = Hand(concealedTiles: tiles("1s","2s","3s","4s","5s","6s","7s","8s","9s","9s","9s"),
                        melds: [Meld.pung(.east, isConcealed: false)],
                        winningTile: .s(9),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext(seat: .south, prevailing: .south))
        XCTAssertEqual(r.faan(for: .halfFlush), 3)
        XCTAssertFalse(r.contains(.fullFlush))
        XCTAssertEqual(r.totalFaan, 3)
    }

    func testFullFlush() {
        let hand = Hand(concealedTiles: tiles("1s","2s","3s","4s","5s","6s","7s","8s","9s","5s","5s"),
                        melds: [Meld.chow(.s(1), isConcealed: false)!],
                        winningTile: .s(9),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertEqual(r.faan(for: .fullFlush), 6)
        XCTAssertFalse(r.contains(.halfFlush))
        XCTAssertEqual(r.totalFaan, 6)
    }

    // MARK: Dragon & wind pungs

    func testDragonPungWithSeatAndRoundWind() {
        // Round = seat = East; an East pung scores both 圈風 and 門風, plus a dragon pung.
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","5p","6p","7p","9s","9s"),
                        melds: [Meld.pung(.east, isConcealed: false),
                                Meld.pung(.redDragon, isConcealed: false)],
                        winningTile: .s(9),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext(seat: .east, prevailing: .east))
        XCTAssertEqual(r.faan(for: .dragonPung), 1)
        XCTAssertEqual(r.faan(for: .prevailingWindPung), 1)
        XCTAssertEqual(r.faan(for: .seatWindPung), 1)
        XCTAssertEqual(r.totalFaan, 3)
    }

    func testSmallThreeDragons() {
        // Two dragon pungs + a dragon pair: 小三元 (3) on top of the two dragon pungs (2).
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","5p","6p","7p","WD","WD"),
                        melds: [Meld.pung(.redDragon, isConcealed: false),
                                Meld.pung(.greenDragon, isConcealed: false)],
                        winningTile: .m(4),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext(seat: .south, prevailing: .south))
        XCTAssertEqual(r.faan(for: .smallThreeDragons), 3)
        XCTAssertEqual(r.faan(for: .dragonPung), 2)
        XCTAssertFalse(r.contains(.bigThreeDragons))
        XCTAssertEqual(r.totalFaan, 5)
    }

    func testBigThreeDragonsIsLimit() {
        // Three dragon pungs → 大三元, a limit hand; the dragon pungs are suppressed.
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","9p","9p"),
                        melds: [Meld.pung(.redDragon, isConcealed: false),
                                Meld.pung(.greenDragon, isConcealed: false),
                                Meld.pung(.whiteDragon, isConcealed: false)],
                        winningTile: .m(4),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext(seat: .south, prevailing: .south))
        XCTAssertTrue(r.contains(.bigThreeDragons))
        XCTAssertTrue(r.isLimitHand)
        XCTAssertEqual(r.totalFaan, 10)
        XCTAssertFalse(r.contains(.dragonPung), "the dragon pungs are subsumed by 大三元")
        XCTAssertTrue(r.meetsMinimum)
    }

    // MARK: Limit special shapes

    func testThirteenOrphansIsLimit() {
        let hand = Hand(concealedTiles: tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD","1m"),
                        winningTile: .m(1),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.contains(.thirteenOrphans))
        XCTAssertTrue(r.isLimitHand)
        XCTAssertEqual(r.totalFaan, 10)
        XCTAssertTrue(r.meetsMinimum)
    }

    func testNineGatesIsLimit() {
        // 1112345678999 bamboo + an extra 5s, fully concealed.
        let hand = Hand(concealedTiles: tiles("1s","1s","1s","2s","3s","4s","5s","6s","7s","8s","9s","9s","9s","5s"),
                        winningTile: .s(5),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.contains(.nineGates))
        XCTAssertTrue(r.isLimitHand)
        XCTAssertEqual(r.totalFaan, 10)
        XCTAssertFalse(r.contains(.fullFlush), "the full flush is subsumed by 九蓮寶燈")
    }

    func testAllHonorsIsLimit() {
        // Four honor pungs + honor pair — 字一色.
        let hand = Hand(concealedTiles: tiles("N","N"),
                        melds: [Meld.pung(.east, isConcealed: false),
                                Meld.pung(.south, isConcealed: false),
                                Meld.pung(.redDragon, isConcealed: false),
                                Meld.pung(.whiteDragon, isConcealed: false)],
                        winningTile: .north,
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.contains(.allHonors))
        XCTAssertTrue(r.isLimitHand)
        XCTAssertEqual(r.totalFaan, 10)
        XCTAssertFalse(r.contains(.allTriplets), "subsumed by the limit hand")
    }

    func testBigFourWindsIsLimit() {
        // Four wind pungs + a non-honor pair → 大四喜; the half flush is suppressed.
        let hand = Hand(concealedTiles: tiles("5m","5m"),
                        melds: [Meld.pung(.east, isConcealed: false),
                                Meld.pung(.south, isConcealed: false),
                                Meld.pung(.west, isConcealed: false),
                                Meld.pung(.north, isConcealed: false)],
                        winningTile: .m(5),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.contains(.bigFourWinds))
        XCTAssertTrue(r.isLimitHand)
        XCTAssertEqual(r.totalFaan, 10)
        XCTAssertFalse(r.contains(.halfFlush), "subsumed by the limit hand")
        XCTAssertFalse(r.contains(.seatWindPung), "subsumed by the limit hand")
    }

    func testAllTerminalsIsLimit() {
        // Terminal pungs across suits, no honors → 清么九.
        let hand = Hand(concealedTiles: tiles("1s","1s"),
                        melds: [Meld.pung(.m(1), isConcealed: false),
                                Meld.pung(.m(9), isConcealed: false),
                                Meld.pung(.p(1), isConcealed: false),
                                Meld.pung(.p(9), isConcealed: false)],
                        winningTile: .s(1),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.contains(.allTerminals))
        XCTAssertTrue(r.isLimitHand)
        XCTAssertEqual(r.totalFaan, 10)
        XCTAssertFalse(r.contains(.allTriplets), "subsumed by the limit hand")
    }

    // MARK: Below minimum

    func testBelowMinimumFlagged() {
        // A fully concealed win by discard with no other pattern: 1 faan, below the minimum.
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","5m","6m","7m","2p","3p","4p","5p","6p","7p","9s","9s"),
                        winningTile: .m(4),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext(minimumFaan: 3))
        XCTAssertTrue(r.isWin)
        XCTAssertEqual(r.totalFaan, 1)
        XCTAssertFalse(r.meetsMinimum)
    }

    // MARK: Max-faan decomposition selection

    func testPicksMaxFaanDecomposition() {
        // 222333444555 bamboo + EE parses as three chows (half flush only) OR as four
        // pungs (half flush + all triplets). The engine must pick the pung reading.
        let hand = Hand(concealedTiles: tiles("2s","2s","2s","3s","3s","3s","4s","4s","4s","5s","5s","5s","E","E"),
                        winningTile: .s(5),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext(seat: .south, prevailing: .south))
        XCTAssertTrue(r.contains(.allTriplets), "should choose the all-pungs decomposition")
        XCTAssertEqual(r.faan(for: .halfFlush), 3)
        // half flush (3) + all triplets (3) + 門前清 (1, fully concealed by discard) = 7.
        XCTAssertEqual(r.totalFaan, 7)
        XCTAssertNotNil(r.winningDecomposition)
        XCTAssertTrue(r.winningDecomposition?.melds.allSatisfy(\.isTriplet) ?? false)
    }

    // MARK: Flowers

    func testSeatFlowersScored() {
        // East seat: F1 (plum) and S1 (spring) match; F2 is a guest flower.
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","5m","6m","7m","2p","3p","4p","5p","6p","7p","9s","9s"),
                        bonusTiles: tiles("F1","S1","F2"),
                        winningTile: .m(4),
                        isSelfDraw: false)
        let ctx = GameContext(seatWind: .east, prevailingWind: .east,
                              houseRules: HouseRules(scoreFlowers: true))
        let r = ScoringEngine.score(hand: hand, context: ctx)
        XCTAssertEqual(r.faan(for: .seatFlower), 2, "two of three bonus tiles match the East seat")
        XCTAssertFalse(r.contains(.noFlowers))
    }

    func testNoFlowersScored() {
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","5m","6m","7m","2p","3p","4p","5p","6p","7p","9s","9s"),
                        winningTile: .m(4),
                        isSelfDraw: false)
        let ctx = GameContext(houseRules: HouseRules(scoreFlowers: true))
        let r = ScoringEngine.score(hand: hand, context: ctx)
        XCTAssertEqual(r.faan(for: .noFlowers), 1)
    }

    // MARK: Win circumstances

    func testWinCircumstances() {
        let hand = Hand(concealedTiles: tiles("2m","3m","4m","5m","6m","7m","2p","3p","4p","5p","6p","7p","9s","9s"),
                        winningTile: .m(4),
                        isSelfDraw: true)
        let ctx = GameContext(houseRules: HouseRules(scoreFlowers: false),
                              isLastTile: true, isReplacement: true, isRobbingKong: true)
        let r = ScoringEngine.score(hand: hand, context: ctx)
        XCTAssertTrue(r.contains(.selfDraw))
        XCTAssertTrue(r.contains(.winOnKongReplacement))
        XCTAssertTrue(r.contains(.robbingKong))
        XCTAssertTrue(r.contains(.lastTile))
    }

    // MARK: Seven pairs

    func testSevenPairs() {
        let hand = Hand(concealedTiles: tiles("1m","1m","3m","3m","2p","2p","5p","5p","4s","4s","7s","7s","RD","RD"),
                        winningTile: .redDragon,
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.contains(.sevenPairs))
        XCTAssertEqual(r.faan(for: .sevenPairs), 4)
    }

    func testSevenPairsFullFlushCombines() {
        // Seven bamboo pairs: 七對子 (4) + 清一色 (6) = 10.
        let hand = Hand(concealedTiles: tiles("1s","1s","2s","2s","3s","3s","4s","4s","5s","5s","6s","6s","9s","9s"),
                        winningTile: .s(9),
                        isSelfDraw: false)
        let r = ScoringEngine.score(hand: hand, context: plainContext())
        XCTAssertTrue(r.contains(.sevenPairs))
        XCTAssertTrue(r.contains(.fullFlush))
        XCTAssertEqual(r.totalFaan, 10)
    }

    // MARK: Payment helper

    func testPaymentSelfDrawVsDiscard() {
        let selfDraw = PaymentCalculator.settle(faan: 3, isSelfDraw: true)
        XCTAssertEqual(selfDraw.base, 8)                 // 2^3
        XCTAssertEqual(selfDraw.winnerReceives, 24)      // 3 opponents × base
        XCTAssertEqual(selfDraw.perOpponent, 8)

        let discard = PaymentCalculator.settle(faan: 3, isSelfDraw: false)
        XCTAssertEqual(discard.winnerReceives, 8)        // discarder alone
        XCTAssertEqual(discard.discarderPays, 8)
    }
}
