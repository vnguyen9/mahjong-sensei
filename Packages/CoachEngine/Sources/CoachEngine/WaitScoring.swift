import MahjongCore
import EfficiencyEngine
import ScoringEngine

/// A single-`advise` scratch cache of `ScoringEngine` results. Tenpai options
/// often complete on the same tiles, and each completion is scored twice (once
/// per channel); memoising by the exact `Hand` + `GameContext` collapses those
/// repeats. Not thread-safe by design — it lives and dies inside one synchronous
/// `advise` call.
final class ScoreMemo {
    private struct Key: Hashable { let hand: Hand; let context: GameContext }
    private var cache: [Key: ScoreResult] = [:]

    func score(_ hand: Hand, _ context: GameContext) -> ScoreResult {
        let key = Key(hand: hand, context: context)
        if let hit = cache[key] { return hit }
        let result = ScoringEngine.score(hand: hand, context: context)
        cache[key] = result
        return result
    }
}

/// Exact per-wait faan for a tenpai hand (plan §2b). For every tile that
/// completes the kept 13-tile hand — *including dead ones the table has already
/// exhausted* — it scores the finished 14-tile hand twice: once as a discard win
/// (門前清 when concealed) and once as a self-draw (自摸). Both channels are
/// needed because the EV formula weighs them separately and each has its own
/// minimum-faan gate.
///
/// The `GameContext` is passed through with its event flags (海底/槓上/搶槓)
/// zeroed: prospective advice cannot know them, so crediting them would be a lie.
enum WaitScoring {

    /// One completing tile and its exact faan on both channels.
    struct ScoredWait: Sendable, Hashable {
        let tile: Tile
        /// Copies of this tile not yet visible anywhere (`4 −` hand − melds −
        /// seen). Zero ⇒ a dead wait: it completes the hand but can never arrive.
        let liveCount: Int
        let seenCount: Int
        /// Capped faan if won off a discard (門前清 channel).
        let faanIfWon: Int
        /// Capped faan if self-drawn (自摸 channel). Always `>= faanIfWon`.
        let faanIfSelfDrawn: Int
    }

    /// Scores every completing tile of `concealed13 + melds`.
    static func scoreWaits(concealed13: [Tile],
                           melds: [Meld],
                           bonus: [Tile],
                           seenHistogram: [Int],
                           context: GameContext,
                           memo: ScoreMemo) -> [ScoredWait] {
        let base = concealed13.filter { !$0.isBonus }

        // Copies already visible (hand + melds + table) bound how many remain.
        var visible = [Int](repeating: 0, count: Tile.baseClassCount)
        for t in base { visible[t.classIndex] += 1 }
        for m in melds { for t in m.tiles where !t.isBonus { visible[t.classIndex] += 1 } }
        for i in 0..<min(seenHistogram.count, Tile.baseClassCount) { visible[i] += seenHistogram[i] }

        let ctx = neutralize(context)

        var out: [ScoredWait] = []
        for idx in 0..<Tile.baseClassCount {
            let w = Tile(classIndex: idx)!
            guard EfficiencyEngine.shanten(base + [w], melds: melds) == -1 else { continue }

            let completed = base + [w]
            let discardWin = Hand(concealedTiles: completed, melds: melds, bonusTiles: bonus,
                                  winningTile: w, isSelfDraw: false)
            let selfDraw = Hand(concealedTiles: completed, melds: melds, bonusTiles: bonus,
                                winningTile: w, isSelfDraw: true)
            let dc = memo.score(discardWin, ctx)
            let sd = memo.score(selfDraw, ctx)

            let seenCount = idx < seenHistogram.count ? seenHistogram[idx] : 0
            out.append(ScoredWait(tile: w,
                                  liveCount: max(0, 4 - visible[idx]),
                                  seenCount: seenCount,
                                  faanIfWon: dc.totalFaan,
                                  faanIfSelfDrawn: sd.totalFaan))
        }
        return out.sorted { $0.tile < $1.tile }
    }

    /// The context with prospective-unknowable circumstance flags cleared.
    static func neutralize(_ context: GameContext) -> GameContext {
        GameContext(seatWind: context.seatWind,
                    prevailingWind: context.prevailingWind,
                    houseRules: context.houseRules,
                    isLastTile: false,
                    isReplacement: false,
                    isRobbingKong: false)
    }
}
