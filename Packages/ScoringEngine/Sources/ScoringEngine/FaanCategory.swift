import Foundation

/// One scoring pattern (番種) in the Hong Kong Old Style faan system.
///
/// This enum is the **stable identifier** the UI and localization layers map on:
/// the `rawValue` string is what should be persisted / used as a translation key,
/// while `englishName` / `traditionalChineseName` are convenience defaults for
/// display. Faan *values* live in ``FaanTable`` (not here) so they can be tuned
/// per house without touching the identifiers.
public enum FaanCategory: String, Hashable, Sendable, Codable, CaseIterable {

    // MARK: Trivial / circumstance

    /// 雞糊 — a valid winning shape that scores no faan at all.
    case chickenHand
    /// 自摸 — won by self-draw.
    case selfDraw
    /// 門前清 — a fully concealed hand won on a discard.
    case fullyConcealed
    /// 花 (正花) — a flower/season matching the winner's seat (1 per match).
    case seatFlower
    /// 無花 — no flowers or seasons at all.
    case noFlowers
    /// 槓上開花 — the winning tile was the kong-replacement draw.
    case winOnKongReplacement
    /// 搶槓 — robbing a kong.
    case robbingKong
    /// 海底撈月 / 河底 — won on the very last tile of the wall / last discard.
    case lastTile

    // MARK: Honor triplets

    /// 番子 — a triplet/kong of a dragon (中/發/白), 1 per dragon.
    case dragonPung
    /// 圈風 — a triplet/kong of the prevailing (round) wind.
    case prevailingWindPung
    /// 門風 — a triplet/kong of the seat wind.
    case seatWindPung

    // MARK: Structural

    /// 對對糊 — every set is a triplet/kong (no chows).
    case allTriplets
    /// 混一色 — one suit plus honors.
    case halfFlush
    /// 清一色 — a single suit, no honors.
    case fullFlush
    /// 小三元 — two dragon triplets plus a pair of the third dragon.
    case smallThreeDragons
    /// 小四喜 — three wind triplets plus a pair of the fourth wind.
    case smallFourWinds
    /// 七對子 — seven distinct pairs (house-optional; some HK tables drop it).
    case sevenPairs

    // MARK: Limit hands (滿糊) — scored at `HouseRules.faanLimit`

    /// 大三元 — triplets/kongs of all three dragons.
    case bigThreeDragons
    /// 大四喜 — triplets/kongs of all four winds.
    case bigFourWinds
    /// 字一色 — every tile is an honor.
    case allHonors
    /// 清么九 — every tile is a terminal (1/9), no honors.
    case allTerminals
    /// 十三么 — the thirteen orphans.
    case thirteenOrphans
    /// 九蓮寶燈 — the nine gates (a concealed 1112345678999 + 1 full flush).
    case nineGates
}

// MARK: - Metadata

public extension FaanCategory {
    /// Limit hands (滿糊) are always scored at `HouseRules.faanLimit` and always
    /// meet the table minimum. They suppress the lesser structural patterns they
    /// contain (e.g. 大三元 subsumes its dragon pungs and 對對糊) in the breakdown.
    var isLimitHand: Bool {
        switch self {
        case .bigThreeDragons, .bigFourWinds, .allHonors,
             .allTerminals, .thirteenOrphans, .nineGates:
            return true
        default:
            return false
        }
    }

    /// Default English display name.
    var englishName: String {
        switch self {
        case .chickenHand:          return "Chicken Hand"
        case .selfDraw:             return "Self-Draw"
        case .fullyConcealed:       return "Fully Concealed"
        case .seatFlower:           return "Seat Flower"
        case .noFlowers:            return "No Flowers"
        case .winOnKongReplacement: return "Win on Kong Replacement"
        case .robbingKong:          return "Robbing a Kong"
        case .lastTile:             return "Last Tile"
        case .dragonPung:           return "Dragon Pung"
        case .prevailingWindPung:   return "Prevailing Wind Pung"
        case .seatWindPung:         return "Seat Wind Pung"
        case .allTriplets:          return "All Triplets"
        case .halfFlush:            return "Half Flush"
        case .fullFlush:            return "Full Flush"
        case .smallThreeDragons:    return "Small Three Dragons"
        case .smallFourWinds:       return "Small Four Winds"
        case .sevenPairs:           return "Seven Pairs"
        case .bigThreeDragons:      return "Big Three Dragons"
        case .bigFourWinds:         return "Big Four Winds"
        case .allHonors:            return "All Honors"
        case .allTerminals:         return "All Terminals"
        case .thirteenOrphans:      return "Thirteen Orphans"
        case .nineGates:            return "Nine Gates"
        }
    }

    /// Traditional Chinese name (番種名).
    var traditionalChineseName: String {
        switch self {
        case .chickenHand:          return "雞糊"
        case .selfDraw:             return "自摸"
        case .fullyConcealed:       return "門前清"
        case .seatFlower:           return "花"
        case .noFlowers:            return "無花"
        case .winOnKongReplacement: return "槓上開花"
        case .robbingKong:          return "搶槓"
        case .lastTile:             return "海底撈月"
        case .dragonPung:           return "番子"
        case .prevailingWindPung:   return "圈風"
        case .seatWindPung:         return "門風"
        case .allTriplets:          return "對對糊"
        case .halfFlush:            return "混一色"
        case .fullFlush:            return "清一色"
        case .smallThreeDragons:    return "小三元"
        case .smallFourWinds:       return "小四喜"
        case .sevenPairs:           return "七對子"
        case .bigThreeDragons:      return "大三元"
        case .bigFourWinds:         return "大四喜"
        case .allHonors:            return "字一色"
        case .allTerminals:         return "清么九"
        case .thirteenOrphans:      return "十三么"
        case .nineGates:            return "九蓮寶燈"
        }
    }
}
