import MahjongCore

/// Internal shanten kernels. Every function operates on a 34-slot histogram of
/// the *base* faces (`Tile.baseClassCount`): suited 0..<27, winds 27..<31,
/// dragons 31..<34. Bonus tiles are dropped by ``counts(of:)`` and honours
/// never participate in runs.
///
/// Shanten convention (shared with ``EfficiencyEngine``):
/// `-1` complete · `0` tenpai · `n` = `n` tiles from tenpai.
enum Shanten {
    /// A value no real shanten can reach; loses every `min`.
    static let unreachable = 99

    /// Class indices (0..<34) of the 13 terminal/honour faces used by 十三么.
    static let terminalHonorIndices: [Int] =
        Tile.allBase.filter(\.isTerminalOrHonor).map(\.classIndex)

    /// Histogram of the 34 base faces; bonus tiles ignored.
    @inline(__always)
    static func counts(of tiles: [Tile]) -> [Int] {
        var c = [Int](repeating: 0, count: Tile.baseClassCount)
        for t in tiles where !t.isBonus { c[t.classIndex] += 1 }
        return c
    }

    /// Minimum shanten across every applicable shape. Seven pairs and thirteen
    /// orphans only apply to a fully concealed hand (`melds` empty).
    static func overall(counts: [Int], melds: [Meld]) -> Int {
        var best = standard(counts: counts, melds: melds)
        if melds.isEmpty {
            best = min(best, sevenPairs(counts: counts))
            best = min(best, thirteenOrphans(counts: counts))
        }
        return best
    }

    // MARK: Standard shape (4 sets + a pair)

    /// Standard shanten. `melds` are pre-formed groups: each set meld pre-fills
    /// one of the four sets, and a `.pair` meld pre-fills the eye.
    ///
    /// - Parameter allowChows: when `false`, runs (chows) and their proto-groups
    ///   (ryanmen/penchan/kanchan) are pruned from the search, leaving only
    ///   triplet-shaped groups — the 對對糊 (all-triplets) distance. Because this
    ///   only ever *removes* branches, the pung-only distance can never undercut
    ///   the full standard shanten.
    static func standard(counts: [Int], melds: [Meld], allowChows: Bool = true) -> Int {
        let fixedSets = melds.reduce(0) { $0 + ($1.isSet ? 1 : 0) }
        let hasPairMeld = melds.contains { $0.kind == .pair }
        var work = counts
        return decompose(&work, index: 0, sets: fixedSets, partials: 0,
                         hasPair: hasPairMeld, allowChows: allowChows)
    }

    /// Standard shanten with runs disabled — the distance to a 對對糊 (all
    /// triplets) shape. A chow meld already fixed in `melds` makes all-triplets
    /// impossible, so any such meld yields ``unreachable``.
    static func pungOnly(counts: [Int], melds: [Meld]) -> Int {
        if melds.contains(where: { $0.kind == .chow }) { return unreachable }
        return standard(counts: counts, melds: melds, allowChows: false)
    }

    /// Depth-first decomposition maximising completion.
    ///
    /// - `sets`: complete groups so far (chow/pung/kong + fixed melds).
    /// - `partials`: two-tile proto-groups (taatsu or a pair used as a
    ///   proto-triplet) counting toward the four sets.
    /// - `hasPair`: a pair has been reserved as the eye.
    ///
    /// The four-set budget caps `sets + partials` at 4; the eye is tracked
    /// separately. At the leaf, a complete `4 sets + eye` hand scores
    /// `8 − 8 − 0 − 1 = −1`, a 13-tile tenpai scores `0`.
    private static func decompose(_ counts: inout [Int], index: Int,
                                  sets: Int, partials: Int, hasPair: Bool,
                                  allowChows: Bool = true) -> Int {
        var i = index
        while i < Tile.baseClassCount && counts[i] == 0 { i += 1 }
        if i >= Tile.baseClassCount {
            return 8 - 2 * sets - partials - (hasPair ? 1 : 0)
        }

        var best = unreachable
        let canGroup = sets + partials < 4       // room left in the four-set budget
        let suited = i < 27
        let rank = i % 9                          // 0..8 inside a suit block (honours ignore)

        // Pung.
        if canGroup && counts[i] >= 3 {
            counts[i] -= 3
            best = min(best, decompose(&counts, index: i, sets: sets + 1, partials: partials, hasPair: hasPair, allowChows: allowChows))
            counts[i] += 3
        }
        // Chow (i, i+1, i+2) inside one suit block.
        if allowChows && canGroup && suited && rank <= 6 && counts[i + 1] > 0 && counts[i + 2] > 0 {
            counts[i] -= 1; counts[i + 1] -= 1; counts[i + 2] -= 1
            best = min(best, decompose(&counts, index: i, sets: sets + 1, partials: partials, hasPair: hasPair, allowChows: allowChows))
            counts[i] += 1; counts[i + 1] += 1; counts[i + 2] += 1
        }
        // Pair reserved as the eye.
        if !hasPair && counts[i] >= 2 {
            counts[i] -= 2
            best = min(best, decompose(&counts, index: i, sets: sets, partials: partials, hasPair: true, allowChows: allowChows))
            counts[i] += 2
        }
        // Pair used as a proto-triplet.
        if canGroup && counts[i] >= 2 {
            counts[i] -= 2
            best = min(best, decompose(&counts, index: i, sets: sets, partials: partials + 1, hasPair: hasPair, allowChows: allowChows))
            counts[i] += 2
        }
        // Open proto-run — ryanmen/penchan (i, i+1).
        if allowChows && canGroup && suited && rank <= 7 && counts[i + 1] > 0 {
            counts[i] -= 1; counts[i + 1] -= 1
            best = min(best, decompose(&counts, index: i, sets: sets, partials: partials + 1, hasPair: hasPair, allowChows: allowChows))
            counts[i] += 1; counts[i + 1] += 1
        }
        // Closed proto-run — kanchan (i, i+2).
        if allowChows && canGroup && suited && rank <= 6 && counts[i + 2] > 0 {
            counts[i] -= 1; counts[i + 2] -= 1
            best = min(best, decompose(&counts, index: i, sets: sets, partials: partials + 1, hasPair: hasPair, allowChows: allowChows))
            counts[i] += 1; counts[i + 2] += 1
        }
        // Leave the remaining tile(s) at i ungrouped and advance. Groups whose
        // lowest tile is i were all tried above, so this branch is complete.
        best = min(best, decompose(&counts, index: i + 1, sets: sets, partials: partials, hasPair: hasPair, allowChows: allowChows))

        return best
    }

    // MARK: Seven pairs (七對子)

    /// `6 − pairs + max(0, 7 − kinds)`. Four-of-a-kind counts as a single pair
    /// (one kind), so the missing-kinds term correctly penalises it.
    static func sevenPairs(counts: [Int]) -> Int {
        var pairs = 0, kinds = 0
        for c in counts where c > 0 {
            kinds += 1
            if c >= 2 { pairs += 1 }
        }
        return 6 - pairs + max(0, 7 - kinds)
    }

    // MARK: Thirteen orphans (十三么)

    /// `13 − distinct terminal/honour kinds − (any such pair ? 1 : 0)`.
    static func thirteenOrphans(counts: [Int]) -> Int {
        var kinds = 0
        var hasPair = false
        for idx in terminalHonorIndices {
            let c = counts[idx]
            if c > 0 { kinds += 1 }
            if c >= 2 { hasPair = true }
        }
        return 13 - kinds - (hasPair ? 1 : 0)
    }
}
