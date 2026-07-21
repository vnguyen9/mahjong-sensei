import Foundation
import MahjongCore
import EfficiencyEngine

/// Source-neutral, wall-aware insight for one tile. Tracker and Coach Live
/// both provide their complete resolved gameplay inventory; this type owns
/// only the shared probability and combination calculations.
struct LiveTileInsight {
    let tile: Tile
    let resolvedCounts: [Tile: Int]

    struct Combo: Identifiable {
        enum Kind: String { case pair = "Pair", chow = "Run", pung = "Triplet" }
        let kind: Kind
        let tiles: [Tile]
        let finishChance: Double
        let moreNeeded: Int
        var id: String { kind.rawValue + tiles.map(\.code).joined() }
    }

    /// Copies of this face still live after every resolved gameplay copy.
    var liveCopies: Int {
        max(0, copyLimit(for: tile) - resolvedCounts[tile, default: 0])
    }

    /// Base-tile wall size after all resolved base-tile copies. Bonus tiles
    /// are excluded from the draw pool because they are replacement draws.
    var unseen: Int {
        let resolvedBase = resolvedCounts.reduce(into: 0) { partial, item in
            if !item.key.isBonus { partial += item.value }
        }
        return max(1, 136 - resolvedBase)
    }

    var drawChance: Double { EfficiencyEngine.winOdds(liveOuts: liveCopies, unseen: unseen) }

    var pungPossible: Bool { liveCopies >= 3 }
    var kongPossible: Bool { liveCopies >= 4 }

    /// Remaining live copies of a face after the same source inventory.
    func remaining(_ face: Tile) -> Int {
        guard !face.isBonus else { return 0 }
        return max(0, copyLimit(for: face) - resolvedCounts[face, default: 0])
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

    private func copyLimit(for tile: Tile) -> Int { tile.isBonus ? 1 : 4 }
}
