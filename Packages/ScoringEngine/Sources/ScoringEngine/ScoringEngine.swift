import Foundation
import MahjongCore

/// A deterministic, pure Hong Kong Old Style faan scoring engine.
///
/// A hand can decompose several ways (`HandParser.standardDecompositions` returns
/// them all); the engine scores every decomposition plus the seven-pairs and
/// thirteen-orphans special shapes, and returns the **highest-faan** result.
///
/// The engine holds no mutable state and performs no I/O. All faan values come from
/// an injected ``FaanTable`` (defaulting to ``FaanTable/standard``) except limit
/// hands, which are always scored at `context.houseRules.faanLimit`.
public enum ScoringEngine {

    /// Scores `hand` in `context`, returning the best-scoring decomposition.
    ///
    /// For a non-winning hand the result is ``ScoreResult/notAWin``.
    public static func score(hand: Hand,
                             context: GameContext = GameContext(),
                             table: FaanTable = .standard) -> ScoreResult {
        // Circumstance / bonus faan is identical across every decomposition, so
        // compute it once and fold it into each candidate.
        let bonuses = bonusComponents(hand: hand, context: context, table: table)

        var candidates: [ScoreResult] = []

        // Standard 4-sets-plus-a-pair readings.
        for decomposition in HandParser.standardDecompositions(concealed: hand.concealedTiles,
                                                               fixedMelds: hand.melds) {
            let structural = flatPatternComponents(hand: hand, context: context, table: table)
                + meldPatternComponents(decomposition, context: context, table: table)
            candidates.append(finalize(structural: structural,
                                       bonuses: bonuses,
                                       decomposition: decomposition,
                                       context: context,
                                       table: table))
        }

        // Special shapes are only possible from a fully-hand-concealed set of tiles
        // (no claimed melds).
        if hand.melds.isEmpty {
            if let decomposition = HandParser.sevenPairs(hand.concealedTiles) {
                let structural = flatPatternComponents(hand: hand, context: context, table: table)
                    + [ScoreComponent(category: .sevenPairs, faan: table[.sevenPairs])]
                candidates.append(finalize(structural: structural,
                                           bonuses: bonuses,
                                           decomposition: decomposition,
                                           context: context,
                                           table: table))
            }
            if let decomposition = HandParser.thirteenOrphans(hand.concealedTiles) {
                let structural = [ScoreComponent(category: .thirteenOrphans,
                                                 faan: context.houseRules.faanLimit)]
                candidates.append(finalize(structural: structural,
                                           bonuses: bonuses,
                                           decomposition: decomposition,
                                           context: context,
                                           table: table))
            }
        }

        // Best = highest raw faan (which also maximizes the capped total). Ties keep
        // the first, which is deterministic given the parser's ordering.
        return candidates.max { $0.rawFaan < $1.rawFaan } ?? .notAWin
    }

    /// True when the hand forms any winning shape (standard, seven pairs, thirteen orphans).
    public static func isWinningShape(_ hand: Hand) -> Bool {
        HandParser.isWinningHand(concealed: hand.concealedTiles, fixedMelds: hand.melds)
    }

    // MARK: - Assembly

    /// Applies limit-hand suppression + the faan cap and packages a ``ScoreResult``.
    private static func finalize(structural: [ScoreComponent],
                                 bonuses: [ScoreComponent],
                                 decomposition: HandDecomposition,
                                 context: GameContext,
                                 table: FaanTable) -> ScoreResult {
        var components = structural
        // A limit hand subsumes the lesser structural patterns it contains: keep only
        // the limit lines. Independent bonuses (flowers, self-draw, circumstance) are
        // still listed, though the cap makes them non-additive.
        if components.contains(where: { $0.category.isLimitHand }) {
            components = components.filter { $0.category.isLimitHand }
        }
        components += bonuses

        var raw = components.reduce(0) { $0 + $1.faan }
        if raw == 0 {
            // A valid shape with no yaku: 雞糊.
            components = [ScoreComponent(category: .chickenHand, faan: table[.chickenHand])]
            raw = 0
        }

        let limit = context.houseRules.faanLimit
        let total = limit > 0 ? min(raw, limit) : raw
        let isLimitHand = limit > 0 && raw >= limit
        let meetsMinimum = isLimitHand || total >= context.houseRules.minimumFaan

        return ScoreResult(components: components,
                           rawFaan: raw,
                           totalFaan: total,
                           isLimitHand: isLimitHand,
                           meetsMinimum: meetsMinimum,
                           winningDecomposition: decomposition,
                           isWin: true)
    }

    // MARK: - Circumstance / bonus faan

    /// Faan that does not depend on how the tiles are grouped.
    private static func bonusComponents(hand: Hand,
                                        context: GameContext,
                                        table: FaanTable) -> [ScoreComponent] {
        var out: [ScoreComponent] = []

        if context.houseRules.scoreFlowers {
            // A seat flower/season is one whose number matches the seat wind
            // (East → 1, South → 2, West → 3, North → 4).
            let seatNumber = context.seatWind.rawValue + 1
            let matches = hand.bonusTiles.reduce(into: 0) { count, tile in
                switch tile {
                case let .flower(flower) where flower.rawValue == seatNumber: count += 1
                case let .season(season) where season.rawValue == seatNumber: count += 1
                default: break
                }
            }
            if hand.bonusTiles.isEmpty {
                out.append(ScoreComponent(category: .noFlowers, faan: table[.noFlowers]))
            } else if matches > 0 {
                out.append(ScoreComponent(category: .seatFlower, faan: matches * table[.seatFlower]))
            }
        }

        // 自摸 and 門前清 are mutually exclusive here: a self-draw scores 自摸; a
        // fully concealed win *by discard* scores 門前清.
        if hand.isSelfDraw {
            out.append(ScoreComponent(category: .selfDraw, faan: table[.selfDraw]))
        } else if hand.isFullyConcealed {
            out.append(ScoreComponent(category: .fullyConcealed, faan: table[.fullyConcealed]))
        }

        if context.isReplacement {
            out.append(ScoreComponent(category: .winOnKongReplacement, faan: table[.winOnKongReplacement]))
        }
        if context.isRobbingKong {
            out.append(ScoreComponent(category: .robbingKong, faan: table[.robbingKong]))
        }
        if context.isLastTile {
            out.append(ScoreComponent(category: .lastTile, faan: table[.lastTile]))
        }
        return out
    }

    // MARK: - Flat (grouping-independent) patterns

    /// Suit-composition and whole-hand shape patterns: flushes, all honors, all
    /// terminals, nine gates. These depend only on the flat multiset of tiles.
    private static func flatPatternComponents(hand: Hand,
                                              context: GameContext,
                                              table: FaanTable) -> [ScoreComponent] {
        let tiles = hand.allTiles.filter { !$0.isBonus }
        guard !tiles.isEmpty else { return [] }
        let limit = context.houseRules.faanLimit

        // 九蓮寶燈 — the most specific single-suit shape; check first and return, as
        // it subsumes the full flush it is built on.
        if hand.melds.isEmpty, hand.isFullyConcealed, isNineGates(tiles) {
            return [ScoreComponent(category: .nineGates, faan: limit)]
        }

        let suited = tiles.filter(\.isSuited)
        let suits = Set(suited.compactMap(\.suit))
        let hasHonor = tiles.contains(where: \.isHonor)

        if !hasHonor, !suited.isEmpty, suited.allSatisfy(\.isTerminal) {
            // 清么九 — terminals only, no honors (may span suits).
            return [ScoreComponent(category: .allTerminals, faan: limit)]
        }
        if suits.isEmpty {
            // 字一色 — no suited tiles at all.
            return [ScoreComponent(category: .allHonors, faan: limit)]
        }
        if suits.count == 1 {
            return hasHonor
                ? [ScoreComponent(category: .halfFlush, faan: table[.halfFlush])]   // 混一色
                : [ScoreComponent(category: .fullFlush, faan: table[.fullFlush])]   // 清一色
        }
        return []
    }

    /// The completed 九蓮寶燈 shape: a single-suit, 14-tile hand whose ranks cover
    /// 1112345678999 with exactly one extra tile.
    private static func isNineGates(_ tiles: [Tile]) -> Bool {
        guard tiles.count == 14, tiles.allSatisfy(\.isSuited) else { return false }
        guard Set(tiles.compactMap(\.suit)).count == 1 else { return false }
        var counts = [Int](repeating: 0, count: 10)   // index by rank 1...9
        for tile in tiles { counts[tile.rank ?? 0] += 1 }
        guard counts[1] >= 3, counts[9] >= 3 else { return false }
        return (2...8).allSatisfy { counts[$0] >= 1 }
    }

    // MARK: - Meld (grouping-dependent) patterns

    /// Patterns that depend on the specific decomposition: triplet-based honors and
    /// all-triplets.
    private static func meldPatternComponents(_ decomposition: HandDecomposition,
                                              context: GameContext,
                                              table: FaanTable) -> [ScoreComponent] {
        var out: [ScoreComponent] = []
        let triplets = decomposition.melds.filter(\.isTriplet)

        let dragonTriplets = triplets.filter { if case .dragon = $0.representative { return true }; return false }
        let windTriplets = triplets.filter { if case .wind = $0.representative { return true }; return false }

        var pairIsDragon = false
        var pairIsWind = false
        if let rep = decomposition.pair?.representative {
            if case .dragon = rep { pairIsDragon = true }
            if case .wind = rep { pairIsWind = true }
        }

        // 對對糊 — all four sets are triplets/kongs.
        if decomposition.melds.count == 4, decomposition.melds.allSatisfy(\.isTriplet) {
            out.append(ScoreComponent(category: .allTriplets, faan: table[.allTriplets]))
        }

        // Dragons.
        if dragonTriplets.count == 3 {
            out.append(ScoreComponent(category: .bigThreeDragons, faan: context.houseRules.faanLimit))
        } else {
            if !dragonTriplets.isEmpty {
                out.append(ScoreComponent(category: .dragonPung,
                                          faan: dragonTriplets.count * table[.dragonPung]))
            }
            if dragonTriplets.count == 2, pairIsDragon {
                out.append(ScoreComponent(category: .smallThreeDragons, faan: table[.smallThreeDragons]))
            }
        }

        // Winds.
        if windTriplets.count == 4 {
            out.append(ScoreComponent(category: .bigFourWinds, faan: context.houseRules.faanLimit))
        } else {
            for meld in windTriplets {
                guard case let .wind(wind) = meld.representative else { continue }
                if wind == context.prevailingWind {
                    out.append(ScoreComponent(category: .prevailingWindPung, faan: table[.prevailingWindPung]))
                }
                if wind == context.seatWind {
                    out.append(ScoreComponent(category: .seatWindPung, faan: table[.seatWindPung]))
                }
            }
            if windTriplets.count == 3, pairIsWind {
                out.append(ScoreComponent(category: .smallFourWinds, faan: table[.smallFourWinds]))
            }
        }

        return out
    }
}
