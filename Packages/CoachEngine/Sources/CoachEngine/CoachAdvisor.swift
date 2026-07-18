import Foundation
import MahjongCore
import EfficiencyEngine
import ScoringEngine

/// The advisor's single entry point: pure, deterministic, thread-safe.
///
/// `advise(_:)` composes three engines into one faan-aware EV recommendation:
/// `EfficiencyEngine` for shanten/ukeire (a single `rankDiscards` call feeds
/// everything), `WinProbability` for the go-arounds absorbing chain (plan §2a),
/// and `ScoringEngine` (via ``WaitScoring``) for exact per-wait faan at tenpai
/// or ``FaanPotential`` for the pre-tenpai estimate. Every option's expected
/// value is expressed in `PaymentCalculator` base points (`2^faan`), the only
/// unit under which a rarer-but-bigger hand can correctly outrank a common
/// cheap one (plan §2d).
///
/// ## Phase decisions
/// Phase is read from `Hand.effectiveTileCount` (a declared kong counts as 3):
/// - **14 effective**: a winning shape that meets the table minimum ⇒
///   ``HandPhase/win(_:)``, scored on the **self-draw channel** — the 14th tile
///   arrived in hand, so we treat it as drawn (the tracker cannot reliably tell
///   ron from tsumo; documented assumption per the plan). A winning shape
///   *below* the minimum stays ``HandPhase/discardDecision`` with
///   ``CoachAdvice/winnableNow`` set (a legal shape you cannot yet declare).
///   Otherwise, rank the discards.
/// - **13 effective**: ``HandPhase/awaitingDraw`` with a ``WaitSet``.
/// - anything else: ``HandPhase/invalid(expected:actual:)`` — degrade, no crash.
///
/// ## Guardrail (plan §2d)
/// An option whose best reachable faan is below the minimum has its EV forced to
/// `0` (a hand you can never declare has zero win value) and is flagged
/// `meetsMinimum == false` with a `.breaksMinimumFaan` reason — ranked last, not
/// hidden. When *no* option clears the minimum, ``CoachAdvice/minimumUnreachable``
/// is set and `best` becomes the least-bad shape (ceiling, then win chance).
public enum CoachAdvisor {

    /// The calibration priors (plan §2a). Internal — exposed for tests only.
    static let constants = ModelConstants.standard

    /// Derives advice for `table`.
    public static func advise(_ table: TableState) -> CoachAdvice {
        let hand = Hand(concealedTiles: table.concealed, melds: table.melds, bonusTiles: table.bonusTiles)

        switch hand.effectiveTileCount {
        case 14:
            return adviseFourteen(hand: hand, table: table)
        case 13:
            return adviseAwaitingDraw(hand: hand, table: table)
        case let actual:
            let expected = actual < 13 ? 13 : 14
            return CoachAdvice(phase: .invalid(expected: expected, actual: actual),
                               currentShanten: EfficiencyEngine.shanten(table.concealed, melds: hand.melds),
                               options: [],
                               best: nil,
                               waitSet: nil,
                               winnableNow: nil,
                               minimumUnreachable: false)
        }
    }

    // MARK: - 14 effective tiles

    private static func adviseFourteen(hand: Hand, table: TableState) -> CoachAdvice {
        // Score the 14-tile shape on the self-draw channel (the 14th tile is a draw).
        let winHand = Hand(concealedTiles: hand.concealedTiles, melds: hand.melds,
                           bonusTiles: hand.bonusTiles, winningTile: nil, isSelfDraw: true)
        let winScore = ScoringEngine.score(hand: winHand, context: table.context)

        if winScore.isWin && winScore.meetsMinimum {
            let display = WaitSet(shanten: -1, waits: nil, ukeire: [], totalLive: 0,
                                  nextDrawOdds: 0, winProbability: 1,
                                  expectedFaan: Double(winScore.totalFaan), meetsMinimum: true)
            return CoachAdvice(phase: .win(winScore),
                               currentShanten: -1,
                               options: [],
                               best: nil,
                               waitSet: display,
                               winnableNow: nil,
                               minimumUnreachable: false)
        }

        let winnableNow: ScoreResult? = winScore.isWin ? winScore : nil
        return adviseDiscardDecision(hand: hand, table: table, winnableNow: winnableNow)
    }

    // MARK: - Discard ranking (the EV core)

    private static func adviseDiscardDecision(hand: Hand, table: TableState,
                                              winnableNow: ScoreResult?) -> CoachAdvice {
        let minimum = table.context.houseRules.minimumFaan
        let draws = table.drawsRemaining
            ?? WinProbability.derivedDraws(unseen: table.unseenCount, opponentMeldCount: table.opponentMeldCount)
        let memo = ScoreMemo()

        let ranked = EfficiencyEngine.rankDiscards(hand, tableSeen: table.seenHistogram)
        let efficiencyBestTile = ranked.first?.discard

        let cores: [OptionCore] = ranked.map { option in
            buildOption(option: option, hand: hand, table: table,
                        draws: draws, minimum: minimum, memo: memo)
        }

        let minimumUnreachable = !cores.isEmpty && cores.allSatisfy { !$0.meetsMinimum }
        let sorted = sort(cores, minimumUnreachable: minimumUnreachable)
        let bestTile = sorted.first?.tile

        let options: [RankedDiscard] = sorted.map { core in
            let reasons = reasons(for: core, all: sorted,
                                  efficiencyBestTile: efficiencyBestTile, bestTile: bestTile,
                                  minimum: minimum)
            return core.ranked(reasons: reasons)
        }

        let currentShanten = EfficiencyEngine.shanten(hand.concealedTiles, melds: hand.melds)
        return CoachAdvice(phase: .discardDecision,
                           currentShanten: currentShanten,
                           options: options,
                           best: options.first,
                           waitSet: nil,
                           winnableNow: winnableNow,
                           minimumUnreachable: minimumUnreachable)
    }

    // MARK: - 13 effective tiles

    private static func adviseAwaitingDraw(hand: Hand, table: TableState) -> CoachAdvice {
        let minimum = table.context.houseRules.minimumFaan
        let draws = table.drawsRemaining
            ?? WinProbability.derivedDraws(unseen: table.unseenCount, opponentMeldCount: table.opponentMeldCount)

        let shanten = EfficiencyEngine.shanten(hand.concealedTiles, melds: hand.melds)
        let live = EfficiencyEngine.ukeire(hand.concealedTiles, melds: hand.melds, seen: table.seenHistogram)
        let ukeire = tileCounts(from: live, seenHistogram: table.seenHistogram)
        let totalLive = ukeire.reduce(0) { $0 + $1.liveCount }
        let nextDrawOdds = EfficiencyEngine.winOdds(liveOuts: totalLive, unseen: table.unseenCount)
        let winProbability = WinProbability.probability(shanten: shanten, liveOuts: totalLive,
                                                        unseen: table.unseenCount, drawsRemaining: draws,
                                                        constants: constants)

        let waitSet: WaitSet
        if shanten == 0 {
            let memo = ScoreMemo()
            let scored = WaitScoring.scoreWaits(concealed13: hand.concealedTiles, melds: hand.melds,
                                                bonus: hand.bonusTiles, seenHistogram: table.seenHistogram,
                                                context: table.context, memo: memo)
            let waits = scored.map { waitInfo(from: $0, minimum: minimum) }
            let (expFaan, meets) = tenpaiFaanSummary(scored: scored, minimum: minimum)
            waitSet = WaitSet(shanten: 0, waits: waits, ukeire: ukeire, totalLive: totalLive,
                              nextDrawOdds: nextDrawOdds, winProbability: winProbability,
                              expectedFaan: expFaan, meetsMinimum: meets)
        } else {
            let potential = FaanPotential.estimate(concealed: hand.concealedTiles, melds: hand.melds,
                                                   bonus: hand.bonusTiles, context: table.context,
                                                   shanten: shanten, constants: constants)
            let (expFaan, _, ceiling) = estimatorFaan(potential: potential, meldsEmpty: hand.melds.isEmpty,
                                                      limit: table.context.houseRules.faanLimit)
            waitSet = WaitSet(shanten: shanten, waits: nil, ukeire: ukeire, totalLive: totalLive,
                              nextDrawOdds: nextDrawOdds, winProbability: winProbability,
                              expectedFaan: expFaan, meetsMinimum: ceiling >= minimum)
        }

        return CoachAdvice(phase: .awaitingDraw,
                           currentShanten: shanten,
                           options: [],
                           best: nil,
                           waitSet: waitSet,
                           winnableNow: nil,
                           minimumUnreachable: false)
    }

    // MARK: - Per-option assembly

    /// Everything computed for one candidate discard before the cross-option
    /// reason pass runs.
    private struct OptionCore {
        let tile: Tile
        let shantenAfter: Int
        let ukeire: [TileCount]
        let ukeireTotal: Int
        let waits: [WaitInfo]?
        let scoredWaits: [WaitScoring.ScoredWait]?
        let winProbability: Double
        let nextDrawOdds: Double
        let expectedFaan: Double
        let faanFloor: Int
        let faanCeiling: Int
        let expectedValue: Double
        let meetsMinimum: Bool
        let potential: FaanPotential

        func ranked(reasons: [AdviceReason]) -> RankedDiscard {
            RankedDiscard(tile: tile, shantenAfter: shantenAfter, ukeire: ukeire, ukeireTotal: ukeireTotal,
                          waits: waits, winProbability: winProbability, nextDrawOdds: nextDrawOdds,
                          expectedFaan: expectedFaan, faanFloor: faanFloor, faanCeiling: faanCeiling,
                          expectedValue: expectedValue, meetsMinimum: meetsMinimum, reasons: reasons)
        }
    }

    private static func buildOption(option: EfficiencyEngine.DiscardOption,
                                    hand: Hand, table: TableState,
                                    draws: Int, minimum: Int, memo: ScoreMemo) -> OptionCore {
        let limit = table.context.houseRules.faanLimit
        let remaining = removingFirst(option.discard, from: hand.concealedTiles)
        let live = EfficiencyEngine.ukeire(remaining, melds: hand.melds, seen: table.seenHistogram)
        let ukeire = tileCounts(from: live, seenHistogram: table.seenHistogram)
        let nextDrawOdds = EfficiencyEngine.winOdds(liveOuts: option.ukeireCount, unseen: table.unseenCount)
        let winProbability = WinProbability.probability(shanten: option.shantenAfter,
                                                        liveOuts: option.ukeireCount,
                                                        unseen: table.unseenCount, drawsRemaining: draws,
                                                        constants: constants)
        let potential = FaanPotential.estimate(concealed: remaining, melds: hand.melds,
                                               bonus: hand.bonusTiles, context: table.context,
                                               shanten: option.shantenAfter, constants: constants)
        let (wSD, wDC) = WinProbability.channelWeights(constants)

        var waits: [WaitInfo]?
        var scoredWaits: [WaitScoring.ScoredWait]?
        let expectedFaan: Double
        let faanFloor: Int
        let faanCeiling: Int
        var expectedValue: Double
        let meetsMinimum: Bool

        if option.shantenAfter == 0 {
            let scored = WaitScoring.scoreWaits(concealed13: remaining, melds: hand.melds,
                                                bonus: hand.bonusTiles, seenHistogram: table.seenHistogram,
                                                context: table.context, memo: memo)
            scoredWaits = scored
            waits = scored.map { waitInfo(from: $0, minimum: minimum) }

            // Best reachable faan = max self-draw faan over every completing tile.
            faanCeiling = scored.map(\.faanIfSelfDrawn).max() ?? 0
            faanFloor = scored.map(\.faanIfWon).min() ?? 0
            meetsMinimum = faanCeiling >= minimum

            // Payout weights only the *live* waits, each below-minimum channel zeroed.
            let liveWaits = scored.filter { $0.liveCount > 0 }
            let totalLive = liveWaits.reduce(0) { $0 + $1.liveCount }
            var ePayout = 0.0
            var expFaan = 0.0
            if totalLive > 0 {
                for w in liveWaits {
                    let share = Double(w.liveCount) / Double(totalLive)
                    let sdPay = w.faanIfSelfDrawn >= minimum ? payout(Double(w.faanIfSelfDrawn), selfDraw: true, limit: limit) : 0
                    let dcPay = w.faanIfWon >= minimum ? payout(Double(w.faanIfWon), selfDraw: false, limit: limit) : 0
                    ePayout += share * (wSD * sdPay + wDC * dcPay)
                    expFaan += share * (wSD * Double(w.faanIfSelfDrawn) + wDC * Double(w.faanIfWon))
                }
            }
            expectedFaan = expFaan
            expectedValue = winProbability * ePayout
        } else {
            let (expFaan, floor, ceiling) = estimatorFaan(potential: potential,
                                                          meldsEmpty: hand.melds.isEmpty, limit: limit)
            expectedFaan = expFaan
            faanFloor = floor
            faanCeiling = ceiling
            meetsMinimum = ceiling >= minimum

            let sdFaan = capD(potential.typical + 1, limit: limit)
            let dcFaan = capD(potential.typical + (hand.melds.isEmpty ? 1 : 0), limit: limit)
            let ePayout = wSD * payout(sdFaan, selfDraw: true, limit: limit)
                        + wDC * payout(dcFaan, selfDraw: false, limit: limit)
            expectedValue = winProbability * ePayout
        }

        // Guardrail: a line you can never declare is worth nothing.
        if !meetsMinimum { expectedValue = 0 }

        return OptionCore(tile: option.discard, shantenAfter: option.shantenAfter,
                          ukeire: ukeire, ukeireTotal: option.ukeireCount,
                          waits: waits, scoredWaits: scoredWaits,
                          winProbability: winProbability, nextDrawOdds: nextDrawOdds,
                          expectedFaan: expectedFaan, faanFloor: faanFloor, faanCeiling: faanCeiling,
                          expectedValue: expectedValue, meetsMinimum: meetsMinimum, potential: potential)
    }

    // MARK: - Sorting

    private static func sort(_ cores: [OptionCore], minimumUnreachable: Bool) -> [OptionCore] {
        if minimumUnreachable {
            // Least-bad: best shape ceiling, then win chance, then tile order.
            return cores.sorted { a, b in
                if a.faanCeiling != b.faanCeiling { return a.faanCeiling > b.faanCeiling }
                if a.winProbability != b.winProbability { return a.winProbability > b.winProbability }
                return a.tile < b.tile
            }
        }
        return cores.sorted { a, b in
            if a.expectedValue != b.expectedValue { return a.expectedValue > b.expectedValue }
            if a.winProbability != b.winProbability { return a.winProbability > b.winProbability }
            if a.shantenAfter != b.shantenAfter { return a.shantenAfter < b.shantenAfter }
            if a.ukeireTotal != b.ukeireTotal { return a.ukeireTotal > b.ukeireTotal }
            return a.tile < b.tile
        }
    }

    // MARK: - Cross-option "why" reasons (plan §3)

    private static func reasons(for option: OptionCore, all: [OptionCore],
                                efficiencyBestTile: Tile?, bestTile: Tile?,
                                minimum: Int) -> [AdviceReason] {
        var out: [AdviceReason] = []
        let others = all.filter { $0.tile != option.tile }

        // 1. Guardrail warning leads.
        if !option.meetsMinimum { out.append(.breaksMinimumFaan(minimum: minimum)) }

        // 2. Tenpai wait warnings.
        if let scored = option.scoredWaits {
            for w in scored where w.liveCount == 0 { out.append(.deadWait(tile: w.tile)) }
            for w in scored where w.liveCount > 0 && w.faanIfSelfDrawn < minimum {
                out.append(.chickenWait(tile: w.tile))
            }
        }

        // 3. Value kept here but broken by some alternative.
        if let suit = option.potential.flushSuit,
           others.contains(where: { $0.potential.flushSuit == nil }) {
            out.append(.keepsFlushAlive(suit: suit, isFull: option.potential.flushIsFull))
        }
        for dragon in option.potential.dragonPungs
        where others.contains(where: { !$0.potential.dragonPungs.contains(dragon) }) {
            out.append(.keepsDragonPung(dragon: dragon))
        }
        for vw in option.potential.valueWindPungs
        where others.contains(where: { core in !core.potential.valueWindPungs.contains { $0.wind == vw.wind } }) {
            out.append(.keepsValueWindPung(wind: vw.wind, isSeat: vw.isSeat, isPrevailing: vw.isPrevailing))
        }
        for dragon in option.potential.dragonPairs
        where others.contains(where: { !$0.potential.dragonPairs.contains(dragon) && !$0.potential.dragonPungs.contains(dragon) }) {
            out.append(.keepsDragonPair(dragon: dragon))
        }
        for vw in option.potential.valueWindPairs
        where others.contains(where: { core in
            !core.potential.valueWindPairs.contains { $0.wind == vw.wind }
                && !core.potential.valueWindPungs.contains { $0.wind == vw.wind }
        }) {
            out.append(.keepsValueWindPair(wind: vw.wind, isSeat: vw.isSeat, isPrevailing: vw.isPrevailing))
        }

        // 4. This is the EV pick but not the efficiency pick — value bought the trade.
        if option.tile == bestTile, let effTile = efficiencyBestTile, effTile != option.tile,
           let effBest = all.first(where: { $0.tile == effTile }) {
            let extra = Int((option.expectedFaan - effBest.expectedFaan).rounded())
            if extra > 0 { out.append(.valueOverSpeed(extraFaan: extra)) }
        }

        // 5. A whole-hand line that is this option's top faan source.
        if option.potential.lines.contains(.sevenPairs), option.potential.topCategory == .sevenPairs {
            out.append(.sevenPairsLine)
        }
        if option.potential.lines.contains(.allTriplets), option.potential.topCategory == .allTriplets {
            out.append(.allTripletsLine)
        }

        // 6. Speed / width (lowest salience).
        let minShanten = all.map(\.shantenAfter).min()
        if all.count > 1, option.shantenAfter == minShanten,
           all.filter({ $0.shantenAfter == minShanten }).count == 1 {
            out.append(.fastestToTenpai)
        }
        let sameShanten = all.filter { $0.shantenAfter == option.shantenAfter }
        if sameShanten.count > 1, option.ukeireTotal > 0,
           option.ukeireTotal == sameShanten.map(\.ukeireTotal).max() {
            out.append(.widestWait(liveOuts: option.ukeireTotal))
        }

        return out
    }

    // MARK: - Faan / payout helpers

    /// Blended display faan and the floor/ceiling for a pre-tenpai estimate,
    /// folding the channel bonus (自摸 always `+1`; 門前清 `+1` only when
    /// concealed) that ``FaanPotential`` leaves out.
    private static func estimatorFaan(potential: FaanPotential, meldsEmpty: Bool,
                                      limit: Int) -> (expectedFaan: Double, floor: Int, ceiling: Int) {
        let (wSD, wDC) = WinProbability.channelWeights(constants)
        let sdFaan = capD(potential.typical + 1, limit: limit)
        let dcFaan = capD(potential.typical + (meldsEmpty ? 1 : 0), limit: limit)
        let expFaan = wSD * sdFaan + wDC * dcFaan
        let floor = cap(potential.floor + (meldsEmpty ? 1 : 0), limit: limit)
        let ceiling = cap(potential.ceiling + 1, limit: limit)
        return (expFaan, floor, ceiling)
    }

    /// Blended display faan and the option-level minimum flag for a tenpai hand.
    private static func tenpaiFaanSummary(scored: [WaitScoring.ScoredWait],
                                          minimum: Int) -> (expectedFaan: Double, meetsMinimum: Bool) {
        let (wSD, wDC) = WinProbability.channelWeights(constants)
        let ceiling = scored.map(\.faanIfSelfDrawn).max() ?? 0
        let liveWaits = scored.filter { $0.liveCount > 0 }
        let totalLive = liveWaits.reduce(0) { $0 + $1.liveCount }
        var expFaan = 0.0
        if totalLive > 0 {
            for w in liveWaits {
                let share = Double(w.liveCount) / Double(totalLive)
                expFaan += share * (wSD * Double(w.faanIfSelfDrawn) + wDC * Double(w.faanIfWon))
            }
        }
        return (expFaan, ceiling >= minimum)
    }

    private static func payout(_ faan: Double, selfDraw: Bool, limit: Int) -> Double {
        let base = pow(2.0, capD(faan, limit: limit))
        return selfDraw ? 3 * base : base
    }

    private static func cap(_ faan: Int, limit: Int) -> Int { limit > 0 ? min(faan, limit) : faan }
    private static func capD(_ faan: Double, limit: Int) -> Double { limit > 0 ? min(faan, Double(limit)) : faan }

    private static func waitInfo(from wait: WaitScoring.ScoredWait, minimum: Int) -> WaitInfo {
        // meetsMinimum iff the wait clears the minimum on at least one channel.
        let meets = wait.faanIfSelfDrawn >= minimum || wait.faanIfWon >= minimum
        return WaitInfo(tile: wait.tile, liveCount: wait.liveCount, seenCount: wait.seenCount,
                        faanIfWon: wait.faanIfWon, faanIfSelfDrawn: wait.faanIfSelfDrawn,
                        meetsMinimum: meets, isDead: wait.liveCount == 0)
    }

    // MARK: - Small helpers

    private static func removingFirst(_ tile: Tile, from tiles: [Tile]) -> [Tile] {
        var out = tiles
        if let index = out.firstIndex(of: tile) { out.remove(at: index) }
        return out
    }

    private static func tileCounts(from live: [Tile: Int], seenHistogram: [Int]) -> [TileCount] {
        live.keys.sorted().map { tile in
            let seenCount = seenHistogram.indices.contains(tile.classIndex) ? seenHistogram[tile.classIndex] : 0
            return TileCount(tile: tile, liveCount: live[tile] ?? 0, seenCount: seenCount)
        }
    }
}
