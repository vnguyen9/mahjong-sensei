import MahjongCore

/// Deterministic mahjong efficiency engine — **shanten**, **ukeire**, and
/// **discard ranking** over standard, seven-pairs, and thirteen-orphans shapes.
///
/// ## Shanten convention
/// | value  | meaning |
/// |--------|---------|
/// | `-1`   | complete / winning hand |
/// | `0`    | tenpai (one tile from a win) |
/// | `n > 0`| `n` tiles away from tenpai |
///
/// Everything is computed on a 34-slot histogram of the *base* faces
/// (`Tile.baseClassCount`); flowers/seasons are ignored. `melds` are treated as
/// already-completed sets — each set meld reduces the standard four-set
/// requirement, and a `.pair` meld fills the eye. Seven pairs (七對子) and
/// thirteen orphans (十三么) are only considered for a fully concealed hand
/// (`melds` empty), matching `HandParser`.
///
/// Pure and deterministic: no globals, no randomness, safe to call from
/// multiple threads.
public enum EfficiencyEngine {

    // MARK: Shanten

    /// Minimum shanten across the standard, seven-pairs, and thirteen-orphans
    /// shapes. See the type doc for the `-1 / 0 / n` convention. Bonus tiles are
    /// ignored; `melds` count as pre-formed sets.
    public static func shanten(_ tiles: [Tile], melds: [Meld] = []) -> Int {
        Shanten.overall(counts: Shanten.counts(of: tiles), melds: melds)
    }

    // MARK: Ukeire (accepting tiles)

    /// Tiles whose draw strictly lowers the hand's shanten, each mapped to the
    /// number still **live** (`4 −` copies already visible). Copies are counted
    /// across the hand `tiles`, its `melds`, and — when table-aware coaching is on
    /// — the `seen` histogram of every other face-up tile on the table (discards +
    /// opponents' melds). Only tiles with ≥ 1 live copy are returned; an
    /// already-complete hand (shanten `-1`) yields an empty map.
    ///
    /// - Parameter seen: a 34-slot `classIndex`-keyed count of tiles visible
    ///   **outside** this hand — the discard pond + opponents' revealed melds.
    ///   Must NOT include the player's own concealed tiles or `melds` (already
    ///   counted), or copies double-count. `nil` = today's own-hand-only behaviour.
    ///
    /// Intended for a hand awaiting a draw (e.g. 13 tiles, or 10 + one meld).
    public static func ukeire(_ tiles: [Tile], melds: [Meld] = [], seen: [Int]? = nil) -> [Tile: Int] {
        let base = Shanten.counts(of: tiles)
        let current = Shanten.overall(counts: base, melds: melds)
        guard current >= 0 else { return [:] }        // a win cannot be improved

        // Copies already seen (hand + melds + the table) bound how many remain drawable.
        var visible = base
        for m in melds { for t in m.tiles where !t.isBonus { visible[t.classIndex] += 1 } }
        if let seen {
            for i in 0..<min(seen.count, Tile.baseClassCount) { visible[i] += seen[i] }
        }

        var work = base
        var result: [Tile: Int] = [:]
        for idx in 0..<Tile.baseClassCount {
            let available = max(0, 4 - visible[idx])
            guard available > 0 else { continue }     // no copies left to draw (dead wait)
            work[idx] += 1
            let improves = Shanten.overall(counts: work, melds: melds) < current
            work[idx] -= 1
            if improves { result[Tile(classIndex: idx)!] = available }
        }
        return result
    }

    /// A rough per-draw chance that your next tile advances the hand: total live
    /// outs over the count of tiles you can't yet see. HK has 136 base tiles; a
    /// caller derives `unseen = 136 − everything visible`. Clamped to `0...1`.
    public static func winOdds(liveOuts: Int, unseen: Int) -> Double {
        guard unseen > 0, liveOuts > 0 else { return 0 }
        return min(1, Double(liveOuts) / Double(unseen))
    }

    // MARK: Discard ranking

    /// One candidate discard from a 14-tile hand and its resulting efficiency.
    public struct DiscardOption: Sendable, Hashable {
        /// The tile discarded.
        public let discard: Tile
        /// Shanten of the 13-tile hand left after the discard.
        public let shantenAfter: Int
        /// Distinct tiles the resulting hand then accepts, ascending.
        public let ukeireTiles: [Tile]
        /// Total live copies across all accepting tiles.
        public let ukeireCount: Int

        public init(discard: Tile, shantenAfter: Int, ukeireTiles: [Tile], ukeireCount: Int) {
            self.discard = discard
            self.shantenAfter = shantenAfter
            self.ukeireTiles = ukeireTiles
            self.ukeireCount = ukeireCount
        }
    }

    /// Ranks every *distinct* discardable concealed tile of `hand`. For each,
    /// the resulting 13-tile shanten and its ukeire (total live accepting
    /// tiles) are computed. Sorted best → worst: lowest shanten, then highest
    /// `ukeireCount`, then tile order. Bonus tiles are never candidates.
    ///
    /// - Parameter tableSeen: a 34-slot `classIndex`-keyed count of tiles visible
    ///   on the table outside this hand (discard pond + opponents' melds), passed
    ///   straight to ``ukeire(_:melds:seen:)`` so the reported ukeire is **live**
    ///   outs. `nil` = own-hand-only (today's behaviour).
    /// - Parameter hkValueTiebreak: when `true`, exact ties (same shanten *and*
    ///   `ukeireCount`) are broken by the light HK value overlay
    ///   (``hkPotentialScore(remaining:melds:)``) before falling back to tile
    ///   order. Off by default — pure efficiency.
    public static func rankDiscards(_ hand: Hand, tableSeen: [Int]? = nil,
                                    hkValueTiebreak: Bool = false) -> [DiscardOption] {
        let melds = hand.melds
        let concealed = hand.concealedTiles.filter { !$0.isBonus }

        var seen = Set<Int>()
        var rows: [(option: DiscardOption, score: Int)] = []
        rows.reserveCapacity(concealed.count)

        for tile in concealed {
            guard seen.insert(tile.classIndex).inserted else { continue }   // distinct only
            var remaining = concealed
            if let pos = remaining.firstIndex(of: tile) { remaining.remove(at: pos) }

            let after = shanten(remaining, melds: melds)
            let accepts = ukeire(remaining, melds: melds, seen: tableSeen)
            let option = DiscardOption(discard: tile,
                                       shantenAfter: after,
                                       ukeireTiles: accepts.keys.sorted(),
                                       ukeireCount: accepts.values.reduce(0, +))
            let score = hkValueTiebreak ? hkPotentialScore(remaining: remaining, melds: melds) : 0
            rows.append((option, score))
        }

        rows.sort { a, b in
            if a.option.shantenAfter != b.option.shantenAfter { return a.option.shantenAfter < b.option.shantenAfter }
            if a.option.ukeireCount != b.option.ukeireCount { return a.option.ukeireCount > b.option.ukeireCount }
            if hkValueTiebreak && a.score != b.score { return a.score > b.score }
            return a.option.discard < b.option.discard
        }
        return rows.map(\.option)
    }
}
