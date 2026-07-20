import Foundation
import MahjongCore
import EfficiencyEngine

/// Live (wall-aware) insight for one tile in Tracker mode — remaining copies
/// after the table histogram + hand, with finish odds for pair / chow / pung.
/// Educational `TileInsight` stays fresh-set-only for Learn / What’s this.
struct TrackerLiveInsight {
    let tile: Tile
    /// Draft table-seen count for `tile` (stepper value before Apply).
    let draftSeen: Int
    let hand: [Tile]
    let seenHistogram: [Int]

    struct Combo: Identifiable {
        enum Kind: String { case pair = "Pair", chow = "Run", pung = "Triplet" }
        let kind: Kind
        let tiles: [Tile]
        let finishChance: Double
        let moreNeeded: Int
        var id: String { kind.rawValue + tiles.map(\.code).joined() }
    }

    /// Effective seen count per base face, substituting `draftSeen` for `tile`.
    private var effectiveSeen: [Int] {
        var h = seenHistogram
        while h.count < Tile.baseClassCount { h.append(0) }
        if (0..<Tile.baseClassCount).contains(tile.classIndex) {
            h[tile.classIndex] = min(4, max(0, draftSeen))
        }
        return h
    }

    private var inHandCount: Int { hand.filter { $0 == tile }.count }

    /// Copies of this face still in the wall (after draft seen + hand).
    var liveCopies: Int {
        max(0, 4 - min(4, max(0, draftSeen)) - inHandCount)
    }

    /// Wall size after draft table counts + hand.
    var unseen: Int {
        let table = effectiveSeen.reduce(0, +)
        return max(1, 136 - table - hand.count)
    }

    var drawChance: Double { EfficiencyEngine.winOdds(liveOuts: liveCopies, unseen: unseen) }

    var pungPossible: Bool { liveCopies >= 3 }
    var kongPossible: Bool { liveCopies >= 4 }

    /// Remaining wall copies of a face (after draft + hand).
    func remaining(_ face: Tile) -> Int {
        guard !face.isBonus, (0..<Tile.baseClassCount).contains(face.classIndex) else { return 0 }
        let seen = effectiveSeen[face.classIndex]
        let held = hand.filter { $0 == face }.count
        return max(0, 4 - seen - held)
    }

    /// Pair / runs containing this rank / pung, with live finish odds over ~17 draws.
    var combos: [Combo] {
        guard !tile.isBonus else { return [] }
        var out: [Combo] = []
        let pool = unseen
        let draws = TileInsight.drawsPerHand

        out.append(Combo(kind: .pair, tiles: [tile, tile],
                         finishChance: TileInsight.pAtLeast(need: 1, avail: liveCopies, pool: pool, draws: draws),
                         moreNeeded: 1))

        if case let .suited(su, r) = tile {
            for s in max(1, r - 2)...min(7, r) {
                let run: [Tile] = [.suited(su, s), .suited(su, s + 1), .suited(su, s + 2)]
                let partners = run.filter { $0 != tile }
                guard partners.count == 2 else { continue }
                let a = remaining(partners[0]), b = remaining(partners[1])
                let missA = TileInsight.pNone(good: a, pool: pool, draws: draws)
                let missB = TileInsight.pNone(good: b, pool: pool, draws: draws)
                let missBoth = TileInsight.pNone(good: a + b, pool: pool, draws: draws)
                let finish = max(0, min(1, 1 - missA - missB + missBoth))
                out.append(Combo(kind: .chow, tiles: run, finishChance: finish, moreNeeded: 2))
            }
        }

        out.append(Combo(kind: .pung, tiles: [tile, tile, tile],
                         finishChance: TileInsight.pAtLeast(need: 2, avail: liveCopies, pool: pool, draws: draws),
                         moreNeeded: 2))
        return out
    }
}
