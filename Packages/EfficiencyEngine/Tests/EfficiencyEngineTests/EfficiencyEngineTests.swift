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

// MARK: - Table-aware live counting (seen tiles)

final class TableSeenTests: XCTestCase {
    private func histogram(_ codes: String...) -> [Int] {
        var h = [Int](repeating: 0, count: Tile.baseClassCount)
        for c in codes { h[tile(c).classIndex] += 1 }
        return h
    }

    /// Open wait 1m/4m; the table shows two 1m + one 4m gone → live outs drop.
    func testSeenTilesReduceLiveOuts() {
        let hand = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s")
        let seen = histogram("1m","1m","4m")
        XCTAssertEqual(EfficiencyEngine.ukeire(hand, seen: seen), [tile("1m"): 2, tile("4m"): 3])
    }

    /// All four 1m visible on the table ⇒ that side of the wait is dead and drops out.
    func testDeadWaitDropsOut() {
        let hand = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s")
        let seen = histogram("1m","1m","1m","1m")
        let uke = EfficiencyEngine.ukeire(hand, seen: seen)
        XCTAssertEqual(uke, [tile("4m"): 4])
        XCTAssertNil(uke[tile("1m")])
    }

    /// Defensive: an impossible over-count (bad recognition) clamps to 0, never negative.
    func testOverCountClampsToZero() {
        let hand = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s")
        var seen = histogram()
        seen[tile("1m").classIndex] = 7
        let uke = EfficiencyEngine.ukeire(hand, seen: seen)
        XCTAssertNil(uke[tile("1m")])
        XCTAssertEqual(uke[tile("4m")], 4)
    }

    /// `seen: nil` and an all-zero histogram both equal today's own-hand-only output.
    func testNilSeenMatchesUnseeded() {
        let hand = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s")
        XCTAssertEqual(EfficiencyEngine.ukeire(hand, seen: nil), EfficiencyEngine.ukeire(hand))
        XCTAssertEqual(EfficiencyEngine.ukeire(hand, seen: histogram()), EfficiencyEngine.ukeire(hand))
    }

    /// `rankDiscards` threads the table through: the best discard's live ukeire
    /// reflects the pond, and a fully-killed wait becomes a 0-out (dead) tenpai.
    func testRankDiscardsUsesTableSeen() {
        let hand = Hand(concealedTiles: tiles(
            "2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s","W"))
        let two1m = histogram("1m","1m")
        let opts = EfficiencyEngine.rankDiscards(hand, tableSeen: two1m)
        XCTAssertEqual(opts.first?.discard, tile("W"))
        XCTAssertEqual(opts.first?.ukeireCount, 6)          // 1m:2 + 4m:4
        XCTAssertEqual(opts.first?.ukeireTiles, [tile("1m"), tile("4m")])

        let killed = histogram("1m","1m","1m","1m","4m","4m","4m","4m")
        let dead = EfficiencyEngine.rankDiscards(hand, tableSeen: killed)
        XCTAssertEqual(dead.first?.discard, tile("W"))      // still shanten 0 → ranks first
        XCTAssertEqual(dead.first?.shantenAfter, 0)
        XCTAssertEqual(dead.first?.ukeireCount, 0)          // …but a dead wait — UI must flag
    }

    func testWinOddsClamps() {
        XCTAssertEqual(EfficiencyEngine.winOdds(liveOuts: 6, unseen: 60), 0.1, accuracy: 1e-9)
        XCTAssertEqual(EfficiencyEngine.winOdds(liveOuts: 0, unseen: 60), 0)
        XCTAssertEqual(EfficiencyEngine.winOdds(liveOuts: 6, unseen: 0), 0)
        XCTAssertEqual(EfficiencyEngine.winOdds(liveOuts: 99, unseen: 10), 1)
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

    /// Pruning runs can never *help*, so the all-triplets distance dominates the
    /// full standard/overall shanten across thousands of random shapes.
    func testPungOnlyShantenDominatesShanten() {
        var rng = SplitMix64(state: 0x9A9A)
        for _ in 0..<4000 {
            let hand = randomHand(13, using: &rng)
            XCTAssertGreaterThanOrEqual(
                EfficiencyEngine.pungOnlyShanten(hand),
                EfficiencyEngine.shanten(hand),
                "\(hand.sorted().map(\.code))")
        }
    }
}

// MARK: - Kernel export wrappers (對對糊 / 七對子 / 十三么 distances)

final class KernelExportTests: XCTestCase {

    /// A complete all-triplets hand is -1; a hand needing runs is not reachable
    /// pung-only even at tenpai on the run.
    func testPungOnlyShanten() {
        // 111m 999m 333p EEE + 5s5s — four pungs + a pair → complete pung-only.
        let allTriplets = tiles("1m","1m","1m","9m","9m","9m","3p","3p","3p","E","E","E","5s","5s")
        XCTAssertEqual(EfficiencyEngine.pungOnlyShanten(allTriplets), -1)
        XCTAssertEqual(EfficiencyEngine.shanten(allTriplets), -1)

        // A pure chow hand is a standard win (-1) but far from all-triplets.
        let chowHand = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","1p","2p","3p","9s","9s")
        XCTAssertEqual(EfficiencyEngine.shanten(chowHand), -1)
        XCTAssertGreaterThan(EfficiencyEngine.pungOnlyShanten(chowHand), 0)
    }

    /// A fixed chow meld makes 對對糊 impossible.
    func testPungOnlyShantenWithChowMeldUnreachable() {
        let concealed = tiles("1m","1m","1m","9m","9m","9m","3p","3p","3p","5s")
        let chow = Meld.chow(.m(4), isConcealed: false)!
        XCTAssertGreaterThan(EfficiencyEngine.pungOnlyShanten(concealed, melds: [chow]), 10)
    }

    /// A concealed pung of East reduces the all-triplets requirement, matching
    /// the standard meld-reduction behaviour.
    func testPungOnlyShantenWithPungMeld() {
        // 111m 999m 333p 5s5s + claimed pung of East → complete pung-only.
        let concealed = tiles("1m","1m","1m","9m","9m","9m","3p","3p","3p","5s","5s")
        let melds = [Meld.pung(.east, isConcealed: false)]
        XCTAssertEqual(EfficiencyEngine.pungOnlyShanten(concealed, melds: melds), -1)
    }

    /// The seven-pairs wrapper agrees with the internal closed form across the
    /// documented shapes.
    func testSevenPairsShanten() {
        // Six pairs + a floater → tenpai for the seventh.
        let tenpai = tiles("1m","1m","3m","3m","5m","5m","7p","7p","9p","9p","2s","2s","4s")
        XCTAssertEqual(EfficiencyEngine.sevenPairsShanten(tenpai), 0)
        // Seven complete pairs → -1.
        let complete = tiles("1m","1m","3m","3m","5m","5m","7p","7p","9p","9p","2s","2s","4s","4s")
        XCTAssertEqual(EfficiencyEngine.sevenPairsShanten(complete), -1)
        // No pairs at all → 6.
        let noPairs = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","1p","2p","3p","4p")
        XCTAssertEqual(EfficiencyEngine.sevenPairsShanten(noPairs), 6)
    }

    /// The thirteen-orphans wrapper agrees with the internal closed form.
    func testThirteenOrphansShanten() {
        // 13 distinct terminals/honours → tenpai (missing the pair).
        let tenpai = tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD")
        XCTAssertEqual(EfficiencyEngine.thirteenOrphansShanten(tenpai), 0)
        // Add a duplicate terminal → complete.
        let complete = tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD","1m")
        XCTAssertEqual(EfficiencyEngine.thirteenOrphansShanten(complete), -1)
    }
}
