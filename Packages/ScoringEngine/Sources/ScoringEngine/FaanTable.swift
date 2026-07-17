import Foundation

/// The single, central source of faan values, kept separate from ``FaanCategory``
/// so a house can retune scores without touching the stable identifiers.
///
/// Values below are Hong Kong Old Style defaults. Anything genuinely table-dependent
/// is flagged `HOUSE`. Limit hands (``FaanCategory/isLimitHand``) are **not** read
/// from this table at scoring time — the engine always scores them at
/// `HouseRules.faanLimit` — so their entries here are documentation of the default
/// limit only.
public struct FaanTable: Sendable, Hashable {

    /// Faan awarded per single occurrence of a category. Aggregating categories
    /// (``FaanCategory/seatFlower``, ``FaanCategory/dragonPung``) are multiplied by
    /// their count by the engine.
    public var values: [FaanCategory: Int]

    public init(values: [FaanCategory: Int]) {
        self.values = values
    }

    /// Faan for a category, or `0` if the table does not list it.
    public subscript(_ category: FaanCategory) -> Int { values[category] ?? 0 }

    /// Hong Kong Old Style defaults.
    public static let standard = FaanTable(values: [
        // Trivial / circumstance
        .chickenHand:          0,   // no faan — cannot meet a non-zero minimum
        .selfDraw:             1,   // 自摸
        .fullyConcealed:       1,   // 門前清 (concealed win by discard)
        .seatFlower:           1,   // per flower/season matching the seat
        .noFlowers:            1,   // 無花
        .winOnKongReplacement: 1,   // 槓上開花
        .robbingKong:          1,   // 搶槓
        .lastTile:             1,   // 海底撈月 / 河底

        // Honor triplets
        .dragonPung:           1,   // per dragon triplet/kong
        .prevailingWindPung:   1,   // 圈風
        .seatWindPung:         1,   // 門風

        // Structural
        .allTriplets:          3,   // 對對糊
        .halfFlush:            3,   // 混一色
        .fullFlush:            6,   // 清一色
        .smallThreeDragons:    3,   // 小三元 — added on top of the two dragon pungs
        .smallFourWinds:       6,   // 小四喜 — HOUSE: some tables treat this as a limit hand
        .sevenPairs:           4,   // 七對子 — HOUSE: optional; set to 0 to disable the pattern

        // Limit hands — nominal only; engine scores these at HouseRules.faanLimit
        .bigThreeDragons:      10,  // 大三元
        .bigFourWinds:         10,  // 大四喜
        .allHonors:            10,  // 字一色
        .allTerminals:         10,  // 清么九
        .thirteenOrphans:      10,  // 十三么
        .nineGates:            10,  // 九蓮寶燈
    ])
}
