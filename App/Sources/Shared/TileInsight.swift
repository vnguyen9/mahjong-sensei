import Foundation
import MahjongCore
import ScoringEngine

/// Educational, **static** facts about a single tile — how many copies exist in a
/// fresh set, the chance of drawing it, the pair/run/triplet combinations it can
/// form (with fresh-set odds), and the Hong Kong scoring patterns it can appear in.
///
/// Everything here is computed against a full, untouched 144-tile HK set — it is
/// NOT live game state. The "What's this?" (`.lookup`) lens doesn't track discards
/// or the wall, so these numbers are a teaching aid, never live win odds.
struct TileInsight {
    let tile: Tile

    /// Full Hong Kong set size (136 base + 8 bonus) — the denominator for `drawChance`.
    static let setSize = 144
    /// Tiles left in a fresh set once you're already holding this one.
    static let restOfSet = 143
    /// Roughly how many tiles a player draws across a Hong Kong hand — the horizon for
    /// the "chance to complete" figures. A teaching approximation, clearly labelled.
    static let drawsPerHand = 17

    init(_ tile: Tile) { self.tile = tile }

    // MARK: Copies & draw chance

    /// Copies of this exact face in a fresh set: 4 for every suited/honor tile,
    /// 1 for each bonus flower/season.
    var copiesInSet: Int { tile.isBonus ? 1 : 4 }

    /// Chance a single random draw from a fresh set is this exact face.
    var drawChance: Double { Double(copiesInSet) / Double(Self.setSize) }

    // MARK: Basic combinations

    /// The pair / run(s) / triplet this tile can anchor, each carrying what's still
    /// needed and the fresh-set odds of completing it. Empty for bonus tiles, which
    /// are set aside and never part of a scoring set.
    var groups: [TileGroup] {
        guard !tile.isBonus else { return [] }
        var out: [TileGroup] = []

        // Pair — need one more of the same; three copies remain in the set.
        out.append(TileGroup(kind: .pair, tiles: [tile, tile], needed: [tile], livePartners: 3))

        // Runs — suited only. Every chow (s, s+1, s+2) that contains this rank,
        // i.e. starts at r-2 … r, clamped to a legal chow base (1 … 7).
        if case let .suited(su, r) = tile {
            for s in max(1, r - 2)...min(7, r) {
                let run: [Tile] = [.suited(su, s), .suited(su, s + 1), .suited(su, s + 2)]
                let needed = run.filter { $0 != tile }
                out.append(TileGroup(kind: .chow, tiles: run, needed: needed,
                                     livePartners: needed.count * 4))
            }
        }

        // Triplet — need two more of the same; three copies remain in the set.
        out.append(TileGroup(kind: .pung, tiles: [tile, tile, tile], needed: [tile, tile], livePartners: 3))
        return out
    }

    // MARK: Scoring patterns

    /// A curated shortlist of the HK patterns this tile most notably feeds — shown by
    /// default on the card and sheet. Ordered for display. Empty for bonus tiles.
    var notableFaan: [FaanCategory] {
        switch tile {
        case let .suited(_, r):
            var f: [FaanCategory] = [.fullFlush, .halfFlush, .allTriplets]
            if r == 1 || r == 9 { f += [.allTerminals, .thirteenOrphans] }
            return f
        case .wind:
            return [.seatWindPung, .prevailingWindPung, .smallFourWinds, .bigFourWinds,
                    .allHonors, .allTriplets]
        case .dragon:
            return [.dragonPung, .smallThreeDragons, .bigThreeDragons, .allHonors, .allTriplets]
        case .flower, .season:
            return []
        }
    }

    /// Whether this tile can actually contribute to `category` — the superset behind
    /// the "show all patterns" expander (includes exotic 七對子 / 九蓮寶燈). Excludes
    /// the situational patterns (see ``situational``), which don't depend on the tile.
    func applies(_ category: FaanCategory) -> Bool {
        switch tile {
        case .flower, .season:
            return category == .seatFlower           // a matching bonus scores 花
        case let .suited(_, r):
            switch category {
            case .fullFlush, .halfFlush, .allTriplets, .sevenPairs, .nineGates:
                return true
            case .allTerminals, .thirteenOrphans:
                return r == 1 || r == 9
            default:
                return false
            }
        case .wind:
            switch category {
            case .seatWindPung, .prevailingWindPung, .smallFourWinds, .bigFourWinds,
                 .allHonors, .allTriplets, .halfFlush, .sevenPairs, .thirteenOrphans:
                return true
            default:
                return false
            }
        case .dragon:
            switch category {
            case .dragonPung, .smallThreeDragons, .bigThreeDragons,
                 .allHonors, .allTriplets, .halfFlush, .sevenPairs, .thirteenOrphans:
                return true
            default:
                return false
            }
        }
    }

    /// Patterns that depend on *how* you win rather than which tile you hold — listed
    /// on their own in the full sheet so they read as "any hand", not tile-specific.
    static let situational: Set<FaanCategory> = [
        .chickenHand, .selfDraw, .fullyConcealed, .noFlowers,
        .winOnKongReplacement, .robbingKong, .lastTile,
    ]

    // MARK: Pattern examples

    /// A short, representative tile layout illustrating `category`, featuring this tile
    /// where it naturally belongs. Illustrative, not a full 14-tile hand — enough to
    /// convey the shape. Returns `[]` for patterns we don't visualise.
    func example(for category: FaanCategory) -> [Tile] {
        let dragons: [Tile] = [.redDragon, .greenDragon, .whiteDragon]
        let winds: [Tile] = [.east, .south, .west, .north]

        switch category {
        case .dragonPung, .seatWindPung, .prevailingWindPung:
            return [tile, tile, tile]

        case .allTriplets:
            let other: Tile = (tile == .east) ? .south : .east
            return [tile, tile, tile, other, other, other]

        case .allHonors:
            let base: Tile = tile.isHonor ? tile : .redDragon
            let rest = (dragons + winds).filter { $0 != base }
            return [base, base, base, rest[0], rest[0], rest[0], rest[1], rest[1]]

        case .halfFlush:
            if let s = tile.suit, let r = tile.rank {
                return suitedRun(s, around: r) + [.redDragon, .redDragon, .redDragon]
            }
            return [.s(2), .s(3), .s(4), tile, tile, tile]   // honor tile + a suit run

        case .fullFlush:
            if let s = tile.suit, let r = tile.rank {
                return [.suited(s, r), .suited(s, r), .suited(s, r)] + suitedRun(s, around: r == 1 ? 5 : 1)
            }
            return []

        case .allTerminals:
            let t1: Tile = tile.isTerminal ? tile : .m(1)
            let t2: Tile = (t1 == .s(9)) ? .p(9) : .s(9)
            return [t1, t1, t1, t2, t2, t2]

        case .thirteenOrphans:
            var set: [Tile] = [.m(1), .m(9), .p(1), .p(9), .s(1), .s(9), .east, .redDragon]
            if tile.isTerminalOrHonor, !set.contains(tile) {
                set.insert(tile, at: 0)
                set = Array(set.prefix(8))
            }
            return set

        case .smallThreeDragons:
            return [dragons[0], dragons[0], dragons[0], dragons[1], dragons[1], dragons[1], dragons[2], dragons[2]]
        case .bigThreeDragons:
            return dragons.flatMap { [$0, $0, $0] }

        case .smallFourWinds:
            return [winds[0], winds[0], winds[0], winds[1], winds[1], winds[1], winds[2], winds[2]]
        case .bigFourWinds:
            return [winds[0], winds[0], winds[0], winds[1], winds[1], winds[1], winds[2], winds[2], winds[2]]

        default:
            return []
        }
    }

    /// A 3-tile run in `suit` that contains `rank` (clamped to a legal 1…7 base).
    private func suitedRun(_ suit: Suit, around rank: Int) -> [Tile] {
        let start = min(max(1, rank - 1), 7)
        return [.suited(suit, start), .suited(suit, start + 1), .suited(suit, start + 2)]
    }

    // MARK: Formatting

    /// A rough "~2.8%" label — one decimal below 10%, whole number above.
    static func percent(_ p: Double) -> String {
        let v = p * 100
        if v > 0, v < 0.1 { return "<0.1%" }
        return v >= 10 ? String(format: "~%.0f%%", v) : String(format: "~%.1f%%", v)
    }

    // MARK: Hypergeometric helpers (drawing without replacement from a fresh set)

    /// P(at least `need` of a face with `avail` copies appear in `draws` draws from `pool`).
    static func pAtLeast(need: Int, avail: Int, pool: Int, draws: Int) -> Double {
        guard need <= avail else { return 0 }
        var total = 0.0
        for k in need...avail { total += hyp(k: k, avail: avail, pool: pool, draws: draws) }
        return min(1, max(0, total))
    }

    /// Hypergeometric PMF: P(exactly `k` of `avail` good tiles in `draws` from `pool`).
    static func hyp(k: Int, avail: Int, pool: Int, draws: Int) -> Double {
        guard k >= 0, k <= avail, draws - k >= 0, draws - k <= pool - avail else { return 0 }
        return exp(logC(avail, k) + logC(pool - avail, draws - k) - logC(pool, draws))
    }

    /// Log of the binomial coefficient C(n, k), via `lgamma` (stable for our sizes).
    static func logC(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return -.infinity }
        return lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1))
    }

    /// P(drawing zero of `good` specific tiles in `draws` from `pool`). Product form —
    /// exact and cheap, used for the run inclusion–exclusion.
    static func pNone(good: Int, pool: Int, draws: Int) -> Double {
        guard good > 0, draws > 0 else { return 1 }
        var p = 1.0
        for i in 0..<draws {
            let num = pool - good - i
            let den = pool - i
            guard den > 0, num > 0 else { return 0 }
            p *= Double(num) / Double(den)
        }
        return p
    }
}

/// One combination a tile can be part of, with the fresh-set odds of completing it.
struct TileGroup: Identifiable {
    enum Kind: String { case pair = "Pair", chow = "Run", pung = "Triplet" }

    /// The kind of group (pair / run / triplet).
    let kind: Kind
    /// The full group in ascending order — used to draw the mini glyphs.
    let tiles: [Tile]
    /// The partner tiles still required (excludes the one you already hold).
    let needed: [Tile]
    /// Total fresh-set copies of the needed partner faces still drawable.
    let livePartners: Int

    var id: String { kind.rawValue + tiles.map(\.code).joined() }

    /// How many more tiles are needed to complete the group.
    var moreNeeded: Int { needed.count }

    /// Chance of drawing each tile of the group in turn from a fresh 144-set — a
    /// sequential walk without replacement, parallel to `tiles`. Every further copy
    /// of a face is rarer as you draw it, so a triplet reads 2.8% · 2.1% · 1.4% and a
    /// pair 2.8% · 2.1% (the first is just the tile's own fresh-draw chance).
    var perTileOdds: [Double] {
        var faceRemaining: [Tile: Int] = [:]
        for t in tiles { faceRemaining[t] = 4 }        // fresh-set copies per face
        var pool = TileInsight.setSize
        var out: [Double] = []
        for t in tiles {
            let avail = faceRemaining[t, default: 0]
            out.append(pool > 0 ? Double(avail) / Double(pool) : 0)
            faceRemaining[t] = max(0, avail - 1)
            pool -= 1
        }
        return out
    }

    /// Chance of gathering every tile this group still needs over a full hand
    /// (`TileInsight.drawsPerHand` draws from a fresh set). A pair (need 1) beats a run
    /// (need 2 different faces) beats a triplet (need 2 of only 3 left) — so this cleanly
    /// separates shapes that share the same per-draw odds.
    var completionChance: Double {
        let pool = TileInsight.restOfSet
        let draws = TileInsight.drawsPerHand
        switch kind {
        case .pair:
            return TileInsight.pAtLeast(need: 1, avail: 3, pool: pool, draws: draws)
        case .pung:
            return TileInsight.pAtLeast(need: 2, avail: 3, pool: pool, draws: draws)
        case .chow:
            // Two distinct partner faces, 4 copies each. Need ≥1 of both →
            // inclusion–exclusion on the "miss" events.
            let a = 4, b = 4
            let missA = TileInsight.pNone(good: a, pool: pool, draws: draws)
            let missB = TileInsight.pNone(good: b, pool: pool, draws: draws)
            let missBoth = TileInsight.pNone(good: a + b, pool: pool, draws: draws)
            return max(0, min(1, 1 - missA - missB + missBoth))
        }
    }
}
