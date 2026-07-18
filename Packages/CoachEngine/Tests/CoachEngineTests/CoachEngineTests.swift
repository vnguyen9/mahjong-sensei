import XCTest
import MahjongCore
import EfficiencyEngine
import ScoringEngine
@testable import CoachEngine

// MARK: - Shared helpers

private func tiles(_ codes: String...) -> [Tile] { codes.map { Tile(code: $0)! } }
private func tile(_ code: String) -> Tile { Tile(code: code)! }

private func histogram(_ codes: [String]) -> [Int] {
    var h = [Int](repeating: 0, count: Tile.baseClassCount)
    for c in codes { h[tile(c).classIndex] += 1 }
    return h
}

/// Builds a `TableState`; `seen` defaults to nothing on the table.
private func makeTable(_ concealed: [Tile],
                       melds: [Meld] = [],
                       bonus: [Tile] = [],
                       seen: [String] = [],
                       unseen: Int? = nil,
                       draws: Int? = nil,
                       opponentMelds: Int = 0,
                       seat: Wind = .east,
                       prevailing: Wind = .east,
                       rules: HouseRules = .standard) -> TableState {
    let seenHist = histogram(seen)
    let mineCount = concealed.count + melds.flatMap(\.tiles).count + bonus.count
    let seenTotal = seenHist.reduce(0, +)
    let ctx = GameContext(seatWind: seat, prevailingWind: prevailing, houseRules: rules)
    return TableState(concealed: concealed, melds: melds, bonusTiles: bonus,
                      seenHistogram: seenHist,
                      unseenCount: unseen ?? max(1, 136 - mineCount - seenTotal),
                      drawsRemaining: draws, opponentMeldCount: opponentMelds, context: ctx)
}

// MARK: - #10 An independent reference DP (different formulation from production)

/// A naive, recursive, memoised implementation of the §2a chain — written
/// forward over (stage, draws-left) rather than as the production iterative
/// push, so agreement is a genuine cross-check.
private func referenceWinProbability(shanten: Int, liveOuts: Int, unseen: Int, draws: Int,
                                     rho: Double = 0.5, h: Double = 0.06, nT: Int = 6) -> Double {
    guard unseen > 0, draws > 0, liveOuts >= 0 else { return 0 }
    let s = max(0, shanten)
    func stagePrior(_ l: Int) -> Int { switch l { case ...1: return 20; case 2: return 26; case 3: return 32; default: return 36 } }
    var memo: [Int: Double] = [:]
    func f(_ k: Int, _ d: Int) -> Double {
        if d <= 0 { return 0 }
        let key = k * 1000 + d
        if let v = memo[key] { return v }
        let result: Double
        if k < s {
            let remaining = s - k
            let n = (k == 0) ? liveOuts : stagePrior(remaining)
            let p = Swift.min(1.0, Double(n) / Double(unseen))
            result = (1 - h) * p * f(k + 1, d - 1) + (1 - h) * (1 - p) * f(k, d - 1)
        } else {
            let nWait = (s == 0) ? liveOuts : nT
            let a = Double(nWait) / Double(unseen)
            let q = 1 - (1 - a) * pow(1 - rho * a, 3)
            result = q + (1 - q) * (1 - h) * f(k, d - 1)
        }
        memo[key] = result
        return result
    }
    return f(0, draws)
}

final class WinProbabilityTests: XCTestCase {

    func testMatchesIndependentReference() {
        for s in 0...5 {
            for n in [0, 1, 3, 6, 12, 20] {
                for u in [30, 50, 70, 100] {
                    for d in [1, 3, 8, 15] {
                        let mine = WinProbability.probability(shanten: s, liveOuts: n, unseen: u, drawsRemaining: d)
                        let ref = referenceWinProbability(shanten: s, liveOuts: n, unseen: u, draws: d)
                        XCTAssertEqual(mine, ref, accuracy: 1e-9, "s=\(s) n=\(n) u=\(u) d=\(d)")
                    }
                }
            }
        }
    }

    func testClosedFormTenpai() {
        // Single-step: D=1 tenpai ⇒ P == q exactly.
        let a = 5.0 / 70.0
        let q = 1 - (1 - a) * pow(1 - 0.5 * a, 3)
        XCTAssertEqual(WinProbability.probability(shanten: 0, liveOuts: 5, unseen: 70, drawsRemaining: 1),
                       q, accuracy: 1e-12)
    }

    func testMonotonicInLiveOuts() {
        // More live outs never lowers P (fix s, U, D).
        for s in 0...3 {
            var previous = -1.0
            for n in 0...24 {
                let p = WinProbability.probability(shanten: s, liveOuts: n, unseen: 80, drawsRemaining: 10)
                XCTAssertGreaterThanOrEqual(p + 1e-12, previous, "s=\(s) n=\(n)")
                previous = p
            }
        }
    }

    func testSeenCopiesLowerProbability() {
        // A wait with fewer live copies (more seen) wins less often.
        let full = WinProbability.probability(shanten: 0, liveOuts: 4, unseen: 60, drawsRemaining: 8)
        let halved = WinProbability.probability(shanten: 0, liveOuts: 2, unseen: 60, drawsRemaining: 8)
        XCTAssertGreaterThan(full, halved)
    }

    func testZeroDrawsAndDeadTenpaiAreZero() {
        XCTAssertEqual(WinProbability.probability(shanten: 0, liveOuts: 8, unseen: 60, drawsRemaining: 0), 0)
        XCTAssertEqual(WinProbability.probability(shanten: 0, liveOuts: 0, unseen: 60, drawsRemaining: 8), 0)
    }

    func testChannelWeights() {
        let (sd, dc) = WinProbability.channelWeights()
        XCTAssertEqual(sd, 0.4, accuracy: 1e-12)
        XCTAssertEqual(dc, 0.6, accuracy: 1e-12)
        XCTAssertEqual(sd + dc, 1.0, accuracy: 1e-12)
    }
}

// MARK: - #3 Worked example (§2e): seat-wind pung value

final class WorkedExampleTests: XCTestCase {

    func testSeatWindPungValueLocksEV() {
        // 2m3m 4p5p6p 7p8p9p 9s9s EEE + drawn 1s. Seat = round = East. Table: two 1m, one 4m.
        let concealed = tiles("2m","3m","4p","5p","6p","7p","8p","9p","9s","9s","E","E","E","1s")
        let table = makeTable(concealed, seen: ["1m","1m","4m"], unseen: 70, draws: 8)

        let advice = CoachAdvisor.advise(table)
        XCTAssertEqual(advice.phase, .discardDecision)
        let best = try! XCTUnwrap(advice.best)

        // Discard 1s → tenpai on 1m (2 live) / 4m (3 live).
        XCTAssertEqual(best.tile, tile("1s"))
        XCTAssertEqual(best.shantenAfter, 0)
        let waits = try! XCTUnwrap(best.waits)
        XCTAssertEqual(Set(waits.map(\.tile)), [tile("1m"), tile("4m")])
        for w in waits {
            XCTAssertEqual(w.faanIfWon, 4, "\(w.tile.code)")          // 門風+圈風+門前清+無花
            XCTAssertEqual(w.faanIfSelfDrawn, 4, "\(w.tile.code)")    // 門風+圈風+自摸+無花
            XCTAssertTrue(w.meetsMinimum)
        }
        XCTAssertEqual(waits.first { $0.tile == tile("1m") }?.liveCount, 2)
        XCTAssertEqual(waits.first { $0.tile == tile("4m") }?.liveCount, 3)

        // Locked verified numbers (this implementation): P = 0.66176,
        // expectedFaan = 4.0, E[payout|win] = 28.8, EV = 19.0588. The plan's
        // 19.06 is the same number computed from a P rounded to 0.662; both
        // round to 19.06, so there is no real discrepancy.
        XCTAssertEqual(best.winProbability, 0.66176, accuracy: 5e-4)
        XCTAssertEqual(best.expectedFaan, 4.0, accuracy: 1e-9)
        XCTAssertEqual(best.expectedValue, 19.0588, accuracy: 5e-3)
        XCTAssertEqual(best.nextDrawOdds, 5.0 / 70.0, accuracy: 1e-9)

        // Discarding E collapses the value (breaks the seat/round pung) → lower EV.
        let eOption = try! XCTUnwrap(advice.options.first { $0.tile == tile("E") })
        XCTAssertLessThan(eOption.expectedValue, best.expectedValue)

        // The 1s pick advertises the wind value it protects.
        XCTAssertTrue(best.reasons.contains { if case .keepsValueWindPung = $0 { return true }; return false },
                      "expected a keepsValueWindPung reason, got \(best.reasons)")
    }
}

// MARK: - #1 Guardrail kills a faanless line

final class GuardrailTests: XCTestCase {

    func testGuardrailKillsFaanlessLine() {
        // 2m3m 4p5p6p 7p8p9p 1s2s3s 9s9s + RD: discarding RD is the only tenpai,
        // but the completed hand is 門前清/自摸 + 無花 = 2 < 3.
        let concealed = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s","RD")
        let advice = CoachAdvisor.advise(makeTable(concealed, unseen: 90, draws: 12))

        let rd = try! XCTUnwrap(advice.options.first { $0.tile == tile("RD") })
        XCTAssertEqual(rd.shantenAfter, 0)                 // the lone tenpai
        XCTAssertFalse(rd.meetsMinimum)
        XCTAssertEqual(rd.expectedValue, 0)                // guardrail zeroes it
        XCTAssertTrue(rd.reasons.contains(.breaksMinimumFaan(minimum: 3)))

        // No keep-RD line reaches three faan either.
        XCTAssertTrue(advice.minimumUnreachable)
        XCTAssertTrue(advice.options.allSatisfy { !$0.meetsMinimum })
        XCTAssertTrue(advice.options.allSatisfy { $0.expectedValue == 0 })
    }
}

// MARK: - #2 Flush keep beats a faster/cheaper line

final class FlushKeepTests: XCTestCase {

    func testFlushKeepBeatsSpeed() {
        // 123s 456s 789s 9s9s EE + lone 5m: discarding 5m keeps 混一色 (bamboo + East),
        // any bamboo discard keeps the off-suit 5m and loses the flush.
        let concealed = tiles("1s","2s","3s","4s","5s","6s","7s","8s","9s","9s","9s","E","E","5m")
        let advice = CoachAdvisor.advise(makeTable(concealed, unseen: 90, draws: 12))

        let best = try! XCTUnwrap(advice.best)
        XCTAssertEqual(best.tile, tile("5m"))              // shed the off-suit tile
        XCTAssertTrue(best.reasons.contains(.keepsFlushAlive(suit: .bamboo, isFull: false)),
                      "expected keepsFlushAlive(.bamboo, half), got \(best.reasons)")
        XCTAssertGreaterThan(best.expectedValue, 0)

        // A flush-breaking discard keeps 5m: no flush reason, and lower EV.
        let breaker = try! XCTUnwrap(advice.options.first { $0.tile == tile("9s") })
        XCTAssertFalse(breaker.reasons.contains { if case .keepsFlushAlive = $0 { return true }; return false })
        XCTAssertGreaterThan(best.expectedValue, breaker.expectedValue)
    }
}

// MARK: - #4 Seven pairs line

final class SevenPairsTests: XCTestCase {

    func testSevenPairsLine() {
        // Six pairs + 4s + a junk 8s: discarding the floater keeps the seven-pairs line.
        let concealed = tiles("1m","1m","3m","3m","5m","5m","7p","7p","9p","9p","2s","2s","4s","8s")
        let advice = CoachAdvisor.advise(makeTable(concealed, unseen: 90, draws: 12))

        let best = try! XCTUnwrap(advice.best)
        XCTAssertEqual(best.shantenAfter, 0)               // seven-pairs tenpai
        XCTAssertTrue(best.reasons.contains(.sevenPairsLine),
                      "expected sevenPairsLine, got \(best.reasons)")

        // Breaking a pair drops off the line to a worse shape.
        let breaker = try! XCTUnwrap(advice.options.first { $0.tile == tile("1m") })
        XCTAssertGreaterThan(breaker.shantenAfter, best.shantenAfter)
    }
}

// MARK: - #5 A live wait beats a wide-but-dead one

final class DeadWaitTests: XCTestCase {

    func testTenpaiLiveBeatsDeadWide() {
        // 123m 456m 789m EEE + 5s 6s, seat = round = East. Two valuable tenpai discards:
        //   discard 6s → tanki 5s (live);  discard 5s → tanki 6s (killed dead by the table).
        // Both would score 門風+圈風+自摸+無花 = 4, but the dead one can never arrive.
        let concealed = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","E","E","E","5s","6s")
        let advice = CoachAdvisor.advise(makeTable(concealed, seen: ["6s","6s","6s","6s"],
                                                   unseen: 80, draws: 12))

        let best = try! XCTUnwrap(advice.best)
        XCTAssertEqual(best.tile, tile("6s"))              // keep the live 5s tanki
        XCTAssertEqual(best.shantenAfter, 0)
        XCTAssertGreaterThan(best.winProbability, 0)
        XCTAssertGreaterThan(best.expectedValue, 0)

        let dead = try! XCTUnwrap(advice.options.first { $0.tile == tile("5s") })
        XCTAssertEqual(dead.shantenAfter, 0)               // still tenpai…
        XCTAssertEqual(dead.winProbability, 0)             // …but a dead wait ⇒ P = 0
        XCTAssertEqual(dead.expectedValue, 0)
        XCTAssertTrue(dead.reasons.contains(.deadWait(tile: tile("6s"))))
        XCTAssertGreaterThan(best.expectedValue, dead.expectedValue)
    }

    /// A cleaner dead-wait unit: fully seen tanki ⇒ isDead, P == 0, deadWait reason.
    func testFullyDeadTanki() {
        // 123m 456m 789m 555s + 2p, waiting tanki on 2p; all four 2p already on the table.
        let concealed = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","5s","5s","5s","2p","W")
        let advice = CoachAdvisor.advise(makeTable(concealed,
                                                   seen: ["2p","2p","2p","2p"],
                                                   unseen: 80, draws: 12))
        // Discard W → tanki on 2p, which is dead.
        let opt = try! XCTUnwrap(advice.options.first { $0.tile == tile("W") })
        XCTAssertEqual(opt.shantenAfter, 0)
        let waits = try! XCTUnwrap(opt.waits)
        let twoP = try! XCTUnwrap(waits.first { $0.tile == tile("2p") })
        XCTAssertTrue(twoP.isDead)
        XCTAssertEqual(twoP.liveCount, 0)
        XCTAssertEqual(opt.winProbability, 0)              // dead ⇒ cannot win
        XCTAssertTrue(opt.reasons.contains(.deadWait(tile: tile("2p"))))
    }
}

// MARK: - #6 Thirteen orphans advice

final class ThirteenOrphansTests: XCTestCase {

    func testThirteenOrphansAdvice() {
        // One of each terminal/honour (13 tiles) → awaiting a draw, 13-way wait, each a limit hand.
        let concealed = tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD")
        let advice = CoachAdvisor.advise(makeTable(concealed, unseen: 90, draws: 12))

        XCTAssertEqual(advice.phase, .awaitingDraw)
        let waitSet = try! XCTUnwrap(advice.waitSet)
        XCTAssertEqual(waitSet.shanten, 0)
        let waits = try! XCTUnwrap(waitSet.waits)
        XCTAssertEqual(waits.count, 13)
        XCTAssertTrue(waits.allSatisfy { $0.faanIfSelfDrawn == 10 })   // limit hand
        XCTAssertTrue(waits.allSatisfy(\.meetsMinimum))
        XCTAssertTrue(waitSet.meetsMinimum)
    }
}

// MARK: - #7 Melded hand

final class MeldedHandTests: XCTestCase {

    func testMeldedHandPhasesAndConcealedFaan() {
        // 10 concealed + claimed East pung = 13 effective ⇒ awaitingDraw, tanki on 5p.
        let concealed = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","5p")
        let melds = [Meld.pung(.east, isConcealed: false)]
        let advice = CoachAdvisor.advise(makeTable(concealed, melds: melds, unseen: 90, draws: 12))

        XCTAssertEqual(advice.phase, .awaitingDraw)
        let waitSet = try! XCTUnwrap(advice.waitSet)
        XCTAssertEqual(waitSet.shanten, 0)
        let fivep = try! XCTUnwrap(waitSet.waits?.first { $0.tile == tile("5p") })
        // Melded (not fully concealed): discard win has NO 門前清; self-draw adds 自摸.
        // 門風(1)+圈風(1)+無花(1) = 3 on discard; +自摸 = 4 self-draw.
        XCTAssertEqual(fivep.faanIfWon, 3)
        XCTAssertEqual(fivep.faanIfSelfDrawn, 4)
        XCTAssertLessThan(fivep.faanIfWon, fivep.faanIfSelfDrawn)

        // 11 concealed + pung = 14 effective ⇒ discardDecision.
        let concealed11 = concealed + tiles("9s")
        let advice14 = CoachAdvisor.advise(makeTable(concealed11, melds: melds, unseen: 90, draws: 12))
        XCTAssertEqual(advice14.phase, .discardDecision)
        XCTAssertFalse(advice14.options.isEmpty)
    }
}

// MARK: - #8 Win phases

final class WinPhaseTests: XCTestCase {

    func testDeclarableWinBecomesWinPhase() {
        // 123m 456p 789p EEE 9s9s — complete, self-draw = 門風+圈風+自摸+無花 = 4 ≥ 3.
        let concealed = tiles("1m","2m","3m","4p","5p","6p","7p","8p","9p","E","E","E","9s","9s")
        let advice = CoachAdvisor.advise(makeTable(concealed, unseen: 90, draws: 12))
        guard case let .win(score) = advice.phase else {
            return XCTFail("expected .win, got \(advice.phase)")
        }
        XCTAssertTrue(score.isWin)
        XCTAssertTrue(score.meetsMinimum)
        XCTAssertEqual(score.totalFaan, 4)
        XCTAssertNil(advice.best)
        XCTAssertTrue(advice.options.isEmpty)
    }

    func testChickenCompleteBecomesWinnableNow() {
        // 123m 456p 789p 123s 9s9s — complete but 自摸+無花 = 2 < 3: legal shape, can't declare.
        let concealed = tiles("1m","2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s")
        let advice = CoachAdvisor.advise(makeTable(concealed, unseen: 90, draws: 12))
        XCTAssertEqual(advice.phase, .discardDecision)
        let winnable = try! XCTUnwrap(advice.winnableNow)
        XCTAssertTrue(winnable.isWin)
        XCTAssertFalse(winnable.meetsMinimum)
        XCTAssertEqual(winnable.totalFaan, 2)
    }
}

// MARK: - #9 Awaiting-draw wait set

final class AwaitingDrawTests: XCTestCase {

    func testAwaitingDrawWaitSetMatchesWinOdds() {
        // 23m 456p 789p 123s 99s — tenpai on 1m/4m, 8 live outs.
        let concealed = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s")
        let table = makeTable(concealed, unseen: 100, draws: 15)
        let advice = CoachAdvisor.advise(table)

        XCTAssertEqual(advice.phase, .awaitingDraw)
        XCTAssertTrue(advice.options.isEmpty)
        let waitSet = try! XCTUnwrap(advice.waitSet)
        XCTAssertEqual(waitSet.shanten, 0)
        XCTAssertEqual(Set(waitSet.waits?.map(\.tile) ?? []), [tile("1m"), tile("4m")])
        XCTAssertEqual(waitSet.totalLive, 8)
        XCTAssertEqual(waitSet.nextDrawOdds, EfficiencyEngine.winOdds(liveOuts: 8, unseen: 100), accuracy: 1e-12)
    }
}

// MARK: - #11 Estimator category table

final class EstimatorTableTests: XCTestCase {

    private func estimate(_ concealed: [Tile], melds: [Meld] = [], bonus: [Tile] = [],
                          seat: Wind = .east, prevailing: Wind = .east) -> FaanPotential {
        let ctx = GameContext(seatWind: seat, prevailingWind: prevailing)
        let s = EfficiencyEngine.shanten(concealed, melds: melds)
        return FaanPotential.estimate(concealed: concealed, melds: melds, bonus: bonus,
                                      context: ctx, shanten: s)
    }

    func testDragonPungGuaranteedVsPairPotential() {
        // Held dragon triplet ⇒ guaranteed; held dragon pair ⇒ potential only.
        let pung = estimate(tiles("RD","RD","RD","1m","2m","3m","4p","5p","6p","7s","8s","9s","1m"))
        XCTAssertTrue(pung.dragonPungs.contains(.red))
        XCTAssertGreaterThanOrEqual(pung.floor, 1)             // 番子 guaranteed

        let pair = estimate(tiles("RD","RD","1m","2m","3m","4p","5p","6p","7s","8s","9s","1m","2m"))
        XCTAssertTrue(pair.dragonPairs.contains(.red))
        XCTAssertGreaterThan(pair.ceiling, pair.floor)         // potential lifts ceiling only
    }

    func testDoubleEastWindGuaranteed() {
        // Seat == prevailing == East, East triplet held ⇒ both 門風 and 圈風.
        let p = estimate(tiles("E","E","E","1m","2m","3m","4p","5p","6p","7s","8s","9s","1m"))
        XCTAssertTrue(p.categories.contains(.seatWindPung))
        XCTAssertTrue(p.categories.contains(.prevailingWindPung))
        XCTAssertGreaterThanOrEqual(p.floor, 2)                // 門風 + 圈風
    }

    func testAllTripletsLiveVsDeadByChowMeld() {
        // A pung-shaped 1-shanten with no chow ⇒ 對對糊 line credit.
        let alive = estimate(tiles("1m","1m","1m","3p","3p","3p","5s","5s","5s","E","E","9m","9m"))
        XCTAssertTrue(alive.lines.contains(.allTriplets))

        // Same value tiles but a fixed chow meld ⇒ all-triplets is impossible.
        let melds = [Meld.chow(.m(4), isConcealed: false)!]
        let dead = estimate(tiles("1m","1m","1m","3p","3p","3p","5s","5s","5s","E"), melds: melds)
        XCTAssertFalse(dead.lines.contains(.allTriplets))
    }

    func testAllHonorsIsGuaranteedLimit() {
        let p = estimate(tiles("E","E","E","S","S","S","W","W","N","N","RD","RD","RD"))
        XCTAssertTrue(p.categories.contains(.allHonors))
        XCTAssertEqual(p.floor, 10)                            // limit
    }

    func testFlowersFloorAndNoFlowers() {
        // Seat flower held (East → flower/season #1) ⇒ guaranteed 正花.
        let withFlower = estimate(tiles("1m","2m","3m","4p","5p","6p","7s","8s","9s","E","E","9m","9m"),
                                  bonus: tiles("F1"))
        XCTAssertTrue(withFlower.categories.contains(.seatFlower))

        // No bonus at all ⇒ 無花 potential (a future flower draw would break it).
        let noBonus = estimate(tiles("1m","2m","3m","4p","5p","6p","7s","8s","9s","2m","5p","9m","9m"))
        XCTAssertTrue(noBonus.categories.contains(.noFlowers))
    }
}

// MARK: - #12 Invalid counts

final class InvalidCountTests: XCTestCase {

    func testInvalidCounts() {
        for n in [12, 15] {
            let concealed = (0..<n).map { Tile(classIndex: $0 % 27)! }   // suited spread
            let advice = CoachAdvisor.advise(makeTable(concealed, unseen: 90, draws: 12))
            guard case .invalid = advice.phase else {
                return XCTFail("expected .invalid for \(n) tiles, got \(advice.phase)")
            }
            XCTAssertTrue(advice.options.isEmpty)
            XCTAssertNil(advice.best)
        }
    }
}

// MARK: - #13 Cache identity + perf budget

final class CacheAndPerfTests: XCTestCase {

    func testCacheReturnsEqualAdviceForEqualStates() async {
        let concealed = tiles("2m","3m","4p","5p","6p","7p","8p","9p","9s","9s","E","E","E","1s")
        let table = makeTable(concealed, seen: ["1m","1m","4m"], unseen: 70, draws: 8)
        let cache = AdvisorCache(cacheSize: 8)

        let first = await cache.advice(for: table)
        let second = await cache.advice(for: table)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, CoachAdvisor.advise(table))     // cache changes latency, not answers
        let n = await cache.count
        XCTAssertEqual(n, 1)                                    // one distinct state cached
    }

    func testCacheEvictsBeyondCapacity() async {
        let cache = AdvisorCache(cacheSize: 2)
        for k in 0..<5 {
            let concealed = tiles("1m","2m","3m","4m","5m","6m","7m","8m","9m","1p","2p","3p","9s")
                + [Tile(classIndex: 18 + k)!]                  // vary the 14th tile
            _ = await cache.advice(for: makeTable(concealed, unseen: 90, draws: 12))
        }
        let n = await cache.count
        XCTAssertLessThanOrEqual(n, 2)
    }

    func testPerformanceBudget() {
        // Worst case: a 14-distinct-tile hand near thirteen-orphans tenpai (13 waits).
        let concealed = tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD","5m")
        let table = makeTable(concealed, unseen: 90, draws: 12)

        let iterations = 20
        let start = Date()
        for _ in 0..<iterations { _ = CoachAdvisor.advise(table) }
        let perCall = Date().timeIntervalSince(start) / Double(iterations) * 1000.0   // ms
        XCTAssertLessThan(perCall, 25.0, "advise worst case \(perCall) ms exceeds 25 ms CI budget")

        measure { _ = CoachAdvisor.advise(table) }
    }
}

// MARK: - #14 EV units + faan cap

final class EVUnitsTests: XCTestCase {

    func testGuardrailFailingOptionIsExactlyZero() {
        // Reuse the faanless line: the tenpai discard's EV must be exactly 0.
        let concealed = tiles("2m","3m","4p","5p","6p","7p","8p","9p","1s","2s","3s","9s","9s","RD")
        let advice = CoachAdvisor.advise(makeTable(concealed, unseen: 90, draws: 12))
        let rd = try! XCTUnwrap(advice.options.first { $0.tile == tile("RD") })
        XCTAssertEqual(rd.expectedValue, 0)
    }

    func testLimitHandCapsPayout() {
        // Thirteen-orphans tenpai (14 tiles: 13 orphans + a spare) → discard the spare,
        // completing at the faan limit. EV must not exceed P × (w_sd·3 + w_dc)·2^limit.
        let concealed = tiles("1m","9m","1p","9p","1s","9s","E","S","W","N","RD","GD","WD","5m")
        let table = makeTable(concealed, unseen: 90, draws: 12)
        let advice = CoachAdvisor.advise(table)
        let best = try! XCTUnwrap(advice.best)
        XCTAssertEqual(best.tile, tile("5m"))              // shed the non-orphan
        XCTAssertEqual(best.shantenAfter, 0)

        let waits = try! XCTUnwrap(best.waits)
        XCTAssertEqual(waits.count, 13)
        XCTAssertTrue(waits.allSatisfy { $0.faanIfSelfDrawn == 10 })

        let (wSD, wDC) = WinProbability.channelWeights()
        let capPayout = wSD * 3 * pow(2.0, 10) + wDC * pow(2.0, 10)
        XCTAssertLessThanOrEqual(best.expectedValue, best.winProbability * capPayout + 1e-6)
        XCTAssertGreaterThan(best.expectedValue, 0)
    }
}
