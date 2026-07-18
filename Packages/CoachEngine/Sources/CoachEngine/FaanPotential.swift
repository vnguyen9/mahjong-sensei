import MahjongCore
import EfficiencyEngine
import ScoringEngine

/// A value-wind shape tied to the table context — carries whether the wind is
/// the seat wind, the prevailing wind, or (a double) both.
struct ValueWind: Sendable, Hashable {
    let wind: Wind
    let isSeat: Bool
    let isPrevailing: Bool
}

/// The pre-tenpai faan estimator (plan §2b/§2c). It credits only the scoring
/// categories the *kept* tiles are already consistent with — never speculation
/// that a future draw opens a brand-new category — and reports three
/// **structural** faan levels (channel faan, 自摸/門前清, is added later at EV
/// time so it is never double-counted):
///
/// - ``floor``: Σ of every *guaranteed* category (a shape the hand already holds).
/// - ``ceiling``: guaranteed + every *potential* category at face value.
/// - ``typical``: guaranteed + Σ of each potential weighted by its credit.
///
/// All three are capped at `HouseRules.faanLimit`.
///
/// Known limitations, matching the plan: 九蓮寶燈 (unreliable before
/// completion) and the circumstance faan (槓上開花/搶槓/海底) are not credited —
/// they are event-conditional and prospective advice cannot know them.
///
/// The struct also surfaces the value shapes it found (``flushSuit``,
/// ``dragonPungs``, …) so the advisor's cross-option reason pass can compare
/// categories without any extra engine calls — this feature side is extracted
/// for *every* option, tenpai or not, even though tenpai EV uses exact scoring.
struct FaanPotential: Sendable, Hashable {

    /// One credited category: its face faan and the weight applied to it
    /// (`1.0` = guaranteed, `< 1.0` = potential).
    struct Credit: Sendable, Hashable {
        let category: FaanCategory
        let faan: Int
        let weight: Double
        var isGuaranteed: Bool { weight >= 1.0 }
    }

    let floor: Int
    let typical: Double
    let ceiling: Int
    let credits: [Credit]

    // Value-shape features (for the reason pass) --------------------------------
    let flushSuit: Suit?
    let flushIsFull: Bool
    let dragonPungs: [Dragon]
    let dragonPairs: [Dragon]
    let valueWindPungs: [ValueWind]
    let valueWindPairs: [ValueWind]
    /// Whole-hand line categories the shape is on (七對子 / 對對糊 / 十三么).
    let lines: Set<FaanCategory>

    /// Every credited category, guaranteed or potential.
    var categories: Set<FaanCategory> { Set(credits.map(\.category)) }

    /// The dominant credited category by face faan — the option's "top source",
    /// used to decide whether a line reason leads the chips.
    var topCategory: FaanCategory? {
        credits.max { $0.faan < $1.faan }?.category
    }

    /// Estimates the faan potential of a kept hand.
    ///
    /// - Parameter shanten: the kept hand's already-computed shanten (overall) —
    ///   passed in to avoid recomputation and to gate the line categories.
    static func estimate(concealed: [Tile],
                         melds: [Meld],
                         bonus: [Tile],
                         context: GameContext,
                         shanten: Int,
                         constants: ModelConstants = .standard,
                         faanTable: FaanTable = .standard) -> FaanPotential {
        let rules = context.houseRules
        let limit = rules.faanLimit
        func cap(_ f: Int) -> Int { limit > 0 ? min(f, limit) : f }
        func capD(_ f: Double) -> Double { limit > 0 ? min(f, Double(limit)) : f }

        let concealedBase = concealed.filter { !$0.isBonus }
        let meldTiles = melds.flatMap(\.tiles).filter { !$0.isBonus }
        let allTiles = concealedBase + meldTiles

        var counts = [Int](repeating: 0, count: Tile.baseClassCount)
        for t in allTiles { counts[t.classIndex] += 1 }

        var credits: [Credit] = []
        func add(_ category: FaanCategory, _ faan: Int, _ weight: Double) {
            credits.append(Credit(category: category, faan: faan, weight: weight))
        }

        // MARK: Whole-hand suit shape (limit hands first, then flushes)
        var flushSuit: Suit?
        var flushIsFull = false
        if !allTiles.isEmpty {
            let suits = Set(allTiles.compactMap(\.suit))
            let hasHonor = allTiles.contains(where: \.isHonor)
            if allTiles.allSatisfy(\.isHonor) {
                add(.allHonors, limit, 1.0)                          // 字一色 (guaranteed-limit)
            } else if allTiles.allSatisfy(\.isTerminal) {
                add(.allTerminals, limit, 1.0)                       // 清么九 (guaranteed-limit)
            } else if suits.count == 1 {
                flushSuit = suits.first
                if hasHonor {
                    add(.halfFlush, faanTable[.halfFlush], 1.0)      // 混一色
                } else {
                    flushIsFull = true
                    add(.fullFlush, faanTable[.fullFlush], 1.0)      // 清一色
                }
            }
        }

        // MARK: Dragons
        var dragonPungs: [Dragon] = []
        var dragonPairs: [Dragon] = []
        for dragon in Dragon.allCases {
            let c = counts[Tile.dragon(dragon).classIndex]
            if c >= 3 {
                add(.dragonPung, faanTable[.dragonPung], 1.0)
                dragonPungs.append(dragon)
            } else if c == 2 {
                add(.dragonPung, faanTable[.dragonPung], constants.pairToPungCredit)
                dragonPairs.append(dragon)
            }
        }
        if dragonPungs.count == 3 {
            add(.bigThreeDragons, limit, 1.0)                        // 大三元 (guaranteed-limit)
        } else if dragonPungs.count == 2, !dragonPairs.isEmpty {
            add(.smallThreeDragons, faanTable[.smallThreeDragons], constants.pairToPungCredit)
        }

        // MARK: Winds (value winds tracked for reasons; all winds for the four-wind shapes)
        var valueWindPungs: [ValueWind] = []
        var valueWindPairs: [ValueWind] = []
        var windPungCount = 0
        var windPairCount = 0
        for wind in Wind.allCases {
            let c = counts[Tile.wind(wind).classIndex]
            let isSeat = wind == context.seatWind
            let isPrev = wind == context.prevailingWind
            if c >= 3 {
                windPungCount += 1
                if isSeat { add(.seatWindPung, faanTable[.seatWindPung], 1.0) }
                if isPrev { add(.prevailingWindPung, faanTable[.prevailingWindPung], 1.0) }
                if isSeat || isPrev { valueWindPungs.append(ValueWind(wind: wind, isSeat: isSeat, isPrevailing: isPrev)) }
            } else if c == 2 {
                windPairCount += 1
                if isSeat { add(.seatWindPung, faanTable[.seatWindPung], constants.pairToPungCredit) }
                if isPrev { add(.prevailingWindPung, faanTable[.prevailingWindPung], constants.pairToPungCredit) }
                if isSeat || isPrev { valueWindPairs.append(ValueWind(wind: wind, isSeat: isSeat, isPrevailing: isPrev)) }
            }
        }
        if windPungCount == 4 {
            add(.bigFourWinds, limit, 1.0)                           // 大四喜 (guaranteed-limit)
        } else if windPungCount == 3, windPairCount >= 1 {
            add(.smallFourWinds, faanTable[.smallFourWinds], constants.pairToPungCredit)
        }

        // MARK: Whole-hand lines (line-credit)
        var lines: Set<FaanCategory> = []
        let hasChowMeld = melds.contains { $0.kind == .chow }
        if !hasChowMeld, EfficiencyEngine.pungOnlyShanten(concealedBase, melds: melds) == shanten {
            add(.allTriplets, faanTable[.allTriplets], constants.lineCredit)
            lines.insert(.allTriplets)
        }
        if melds.isEmpty {
            if EfficiencyEngine.sevenPairsShanten(concealedBase) <= shanten {
                add(.sevenPairs, faanTable[.sevenPairs], constants.lineCredit)
                lines.insert(.sevenPairs)
            }
            if EfficiencyEngine.thirteenOrphansShanten(concealedBase) == shanten {
                add(.thirteenOrphans, limit, constants.lineCredit)
                lines.insert(.thirteenOrphans)
            }
        }

        // MARK: Flowers
        if rules.scoreFlowers {
            let seatNumber = context.seatWind.rawValue + 1
            let matches = bonus.reduce(into: 0) { count, tile in
                switch tile {
                case let .flower(flower) where flower.rawValue == seatNumber: count += 1
                case let .season(season) where season.rawValue == seatNumber: count += 1
                default: break
                }
            }
            if bonus.isEmpty {
                add(.noFlowers, faanTable[.noFlowers], constants.noFlowersCredit)
            } else if matches > 0 {
                add(.seatFlower, matches * faanTable[.seatFlower], 1.0)
            }
        }

        // MARK: Roll up the three levels (structural, capped)
        let guaranteedSum = credits.filter(\.isGuaranteed).reduce(0) { $0 + $1.faan }
        let potentialSum = credits.filter { !$0.isGuaranteed }.reduce(0) { $0 + $1.faan }
        let weightedPotential = credits.filter { !$0.isGuaranteed }
            .reduce(0.0) { $0 + Double($1.faan) * $1.weight }

        return FaanPotential(
            floor: cap(guaranteedSum),
            typical: capD(Double(guaranteedSum) + weightedPotential),
            ceiling: cap(guaranteedSum + potentialSum),
            credits: credits,
            flushSuit: flushSuit,
            flushIsFull: flushIsFull,
            dragonPungs: dragonPungs,
            dragonPairs: dragonPairs,
            valueWindPungs: valueWindPungs,
            valueWindPairs: valueWindPairs,
            lines: lines)
    }
}
