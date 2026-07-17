import XCTest
import MahjongCore
@testable import EfficiencyEngine

/// Small helpers shared across the suites.
private func tiles(_ codes: String...) -> [Tile] { codes.map { Tile(code: $0)! } }
private func tile(_ code: String) -> Tile { Tile(code: code)! }

// MARK: - Shanten

final class ShantenTests: XCTestCase {

    /// A complete standard hand is -1 and agrees with `HandParser`.
    func testCompleteStandardHandIsMinusOne() {
        // 123m 456m 789m 123p 99s
        let hand = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","1p","2p","3p","9s","9s")
        XCTAssertEqual(EfficiencyEngine.shanten(hand), -1)
        XCTAssertTrue(HandParser.isWinningHand(concealed: hand))
        // A winning hand cannot be improved.
        XCTAssertTrue(EfficiencyEngine.ukeire(hand).isEmpty)
    }

    /// Every shape `HandParser` calls a win must be shanten -1.
    func testWinningHandsAreMinusOne() {
        let wins: [[Tile]] = [
            tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","1p","2p","3p","9s","9s"),   // chows + pair
            tiles("1m","1m","1m","2p","3p","4p","5s","5s","5s","6s","7s","8s","7p","7p"),   // pungs/chows
            tiles("1m","1m","3m","3m","2p","2p","5p","5p","4s","4s","7s","7s","RD","RD"),   // seven pairs
            tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD","1m"),       // thirteen orphans
        ]
        for w in wins {
            XCTAssertTrue(HandParser.isWinningHand(concealed: w), "\(w.map(\.code))")
            XCTAssertEqual(EfficiencyEngine.shanten(w), -1, "\(w.map(\.code))")
        }
    }

    /// A pung claimed off a discard (a fixed set) reaches the win with one fewer
    /// concealed set — verifies melds reduce the four-set requirement.
    func testMeldReducesRequirement() {
        // 123m 456m 789m 5p  + claimed pung of East  → tanki tenpai on 5p.
        let concealed = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","5p")
        let melds = [Meld.pung(.east, isConcealed: false)]
        XCTAssertEqual(EfficiencyEngine.shanten(concealed, melds: melds), 0)
        let uke = EfficiencyEngine.ukeire(concealed, melds: melds)
        XCTAssertEqual(uke, [tile("5p"): 3])   // hold one 5p already → 3 live
    }

    /// A clearly non-winning hand is well above tenpai.
    func testJunkHandIsNotTenpai() {
        let junk = tiles("1m","3m","5m","7m","9m","1p","3p","5p","7p","9p","1s","3s","5s","7s")
        XCTAssertFalse(HandParser.isWinningHand(concealed: junk))
        XCTAssertGreaterThan(EfficiencyEngine.shanten(junk), 0)
    }

    func testOneShanten() {
        // 3 chows + pair + two isolated floaters (2p, 5p) → 1 away from tenpai.
        let hand = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","2p","5p","9s","9s")
        XCTAssertEqual(EfficiencyEngine.shanten(hand), 1)
    }
}

// MARK: - Ukeire

final class UkeireTests: XCTestCase {

    /// Open (ryanmen) wait: 23m completed by 1m or 4m, isolated from other m.
    func testOpenWaitUkeire() {
        // 23m 456p 789p 123s 99s  (tenpai)
        let hand = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s")
        XCTAssertEqual(EfficiencyEngine.shanten(hand), 0)
        let uke = EfficiencyEngine.ukeire(hand)
        // Only 1m / 4m improve the hand; none held or melded → 4 live each.
        XCTAssertEqual(uke, [tile("1m"): 4, tile("4m"): 4])
    }

    /// Shanpon (dual pair) wait exercises availability accounting: we already
    /// hold two of each winning tile, so only two of each remain.
    func testShanponWaitAvailability() {
        // 11m 99m 123p 456p 789p  → shanpon on 1m / 9m
        let hand = tiles("1m","1m","9m","9m","1p","2p","3p","4p","5p","6p","7p","8p","9p")
        XCTAssertEqual(EfficiencyEngine.shanten(hand), 0)
        let uke = EfficiencyEngine.ukeire(hand)
        XCTAssertEqual(uke, [tile("1m"): 2, tile("9m"): 2])
    }
}

// MARK: - Special shapes

final class SpecialShapeTests: XCTestCase {

    func testSevenPairsTenpai() {
        // Six pairs + a lone 4s → seven-pairs tenpai (standard shape would be 3).
        let hand = tiles("1m","1m","3m","3m","5m","5m","7p","7p","9p","9p","2s","2s","4s")
        XCTAssertEqual(EfficiencyEngine.shanten(hand), 0)
        let uke = EfficiencyEngine.ukeire(hand)
        XCTAssertEqual(uke, [tile("4s"): 3])   // only pairing 4s wins; hold one → 3 live
    }

    func testThirteenOrphansThirteenWait() {
        // One of each terminal/honour → tenpai waiting on any of the 13.
        let hand = tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD")
        XCTAssertEqual(EfficiencyEngine.shanten(hand), 0)
        let uke = EfficiencyEngine.ukeire(hand)
        XCTAssertEqual(uke.count, 13)
        XCTAssertTrue(uke.keys.allSatisfy { $0.isTerminalOrHonor })
        XCTAssertTrue(uke.values.allSatisfy { $0 == 3 })   // hold one of each → 3 live
    }

    func testThirteenOrphansSingleWait() {
        // 12 kinds present, one paired (E), missing 9s → single wait on 9s.
        let hand = tiles("1m","9m","1p","9p","1s","E","E","S","W","N","RD","GD","WD")
        XCTAssertEqual(EfficiencyEngine.shanten(hand), 0)
        let uke = EfficiencyEngine.ukeire(hand)
        XCTAssertEqual(uke, [tile("9s"): 4])
    }
}

// MARK: - Discard ranking

final class RankDiscardsTests: XCTestCase {

    /// A 14-tile hand that is a tenpai shape plus one isolated honour. Discarding
    /// the honour keeps tenpai; anything else drops to 1-shanten.
    func testBestDiscardFirst() {
        // 23m 456p 789p 123s 99s  + lone West
        let hand = Hand(concealedTiles: tiles(
            "2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s","W"))
        let options = EfficiencyEngine.rankDiscards(hand)

        XCTAssertEqual(options.first?.discard, tile("W"))
        XCTAssertEqual(options.first?.shantenAfter, 0)
        XCTAssertEqual(options.first?.ukeireCount, 8)                 // 1m×4 + 4m×4
        XCTAssertEqual(options.first?.ukeireTiles, [tile("1m"), tile("4m")])

        // The West discard is strictly the unique best (shanten 0); the rest are worse.
        XCTAssertTrue(options.dropFirst().allSatisfy { $0.shantenAfter >= 1 })
        // One row per distinct concealed tile.
        XCTAssertEqual(options.count, Set(hand.concealedTiles.map(\.classIndex)).count)
    }

    /// Sort order: shanten first, then ukeireCount, then tile order.
    func testSortOrdering() {
        let hand = Hand(concealedTiles: tiles(
            "2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s","W"))
        let options = EfficiencyEngine.rankDiscards(hand)
        for (a, b) in zip(options, options.dropFirst()) {
            XCTAssertTrue(
                a.shantenAfter < b.shantenAfter
                || (a.shantenAfter == b.shantenAfter && a.ukeireCount > b.ukeireCount)
                || (a.shantenAfter == b.shantenAfter && a.ukeireCount == b.ukeireCount && a.discard <= b.discard),
                "ordering violated between \(a.discard.code) and \(b.discard.code)")
        }
    }
}

// MARK: - Cross-checks / invariants

final class InvariantTests: XCTestCase {

    /// Adding a ukeire tile must actually lower the shanten by the definition.
    func testUkeireLowersShanten() {
        let hand = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s")
        let before = EfficiencyEngine.shanten(hand)
        for (t, _) in EfficiencyEngine.ukeire(hand) {
            XCTAssertLessThan(EfficiencyEngine.shanten(hand + [t]), before, "\(t.code)")
        }
    }

    /// The HK overlay only reorders exact ties; the shanten of the best discard
    /// is unaffected by turning it on.
    func testHKOverlayPreservesShanten() {
        let hand = Hand(concealedTiles: tiles(
            "2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s","W"))
        let plain = EfficiencyEngine.rankDiscards(hand)
        let biased = EfficiencyEngine.rankDiscards(hand, hkValueTiebreak: true)
        XCTAssertEqual(plain.first?.shantenAfter, biased.first?.shantenAfter)
        XCTAssertEqual(Set(plain.map(\.discard)), Set(biased.map(\.discard)))
    }

    /// Deterministic PRNG so the randomised cross-checks are reproducible.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Draw `n` distinct-face-capped tiles (max 4 each) from the 34-tile wall.
    private func randomHand(_ n: Int, using rng: inout SplitMix64) -> [Tile] {
        var wall: [Int] = []
        for face in 0..<Tile.baseClassCount { wall += Array(repeating: face, count: 4) }
        wall.shuffle(using: &rng)
        return wall.prefix(n).map { Tile(classIndex: $0)! }
    }

    /// The load-bearing invariant: shanten is `-1` **iff** `HandParser` agrees the
    /// 14-tile hand wins — checked across thousands of random shapes.
    func testShantenMatchesParserOnRandomHands() {
        var rng = SplitMix64(state: 0xC0FFEE)
        for _ in 0..<4000 {
            let hand = randomHand(14, using: &rng)
            let complete = EfficiencyEngine.shanten(hand) == -1
            XCTAssertEqual(complete, HandParser.isWinningHand(concealed: hand),
                           "disagreement on \(hand.sorted().map(\.code))")
        }
    }

    /// A 13-tile hand can never already be complete.
    func testThirteenTileHandsAreNeverComplete() {
        var rng = SplitMix64(state: 0x1234)
        for _ in 0..<1000 {
            XCTAssertGreaterThanOrEqual(EfficiencyEngine.shanten(randomHand(13, using: &rng)), 0)
        }
    }

    /// Ukeire is exactly "the draws that lower shanten", verified by brute force
    /// against the shanten oracle on random 13-tile hands.
    func testUkeireMatchesBruteForce() {
        var rng = SplitMix64(state: 0xABCDEF)
        for _ in 0..<400 {
            let hand = randomHand(13, using: &rng)
            let before = EfficiencyEngine.shanten(hand)
            let uke = EfficiencyEngine.ukeire(hand)
            var visible = [Int](repeating: 0, count: Tile.baseClassCount)
            for t in hand { visible[t.classIndex] += 1 }
            for face in 0..<Tile.baseClassCount {
                let t = Tile(classIndex: face)!
                let lowers = EfficiencyEngine.shanten(hand + [t]) < before
                let live = 4 - visible[face]
                if lowers && live > 0 {
                    XCTAssertEqual(uke[t], live, "\(t.code)")
                } else {
                    XCTAssertNil(uke[t], "\(t.code) should not be an accepting tile")
                }
            }
        }
    }
}
