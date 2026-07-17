import MahjongCore

/// Localized display information for a tile (spec §20 Tile detail: EN + 繁中 + Jyutping + lore).
public struct TileName: Sendable, Hashable, Codable {
    public let english: String
    public let traditional: String   // 繁中
    public let jyutping: String      // Yale-style romanization, matching the design sample
    public let category: Category
    public let note: String

    public enum Category: String, Sendable, Codable { case suit = "Suit tile", honor = "Honor", bonus = "Bonus" }

    public init(english: String, traditional: String, jyutping: String, category: Category, note: String = "") {
        self.english = english
        self.traditional = traditional
        self.jyutping = jyutping
        self.category = category
        self.note = note
    }
}

/// Names, romanization, and lore for all 42 tile faces — derived, not hand-typed.
public enum MahjongData {

    public static func name(for tile: Tile) -> TileName {
        switch tile {
        case let .suited(suit, r):
            let s = suitInfo(suit)
            return TileName(
                english: "\(ordinal[r]) \(s.english)",
                traditional: "\(cn[r])\(s.zh)",
                jyutping: "\(numJyut[r]) \(s.jyut)",
                category: .suit,
                note: note(forSuited: suit, rank: r)
            )
        case let .wind(w):
            let i = w.rawValue
            return TileName(english: "\(windEN[i]) Wind", traditional: "\(windZH[i])風",
                            jyutping: "\(windJyut[i]) fūng", category: .honor,
                            note: "A wind tile — scores as a triplet only when it matches your seat or the round.")
        case let .dragon(d):
            switch d {
            case .red:   return TileName(english: "Red Dragon", traditional: "紅中", jyutping: "hùhng jūng",
                                         category: .honor, note: "A triplet of dragons always scores, whatever your seat.")
            case .green: return TileName(english: "Green Dragon", traditional: "青發", jyutping: "faat chòih",
                                         category: .honor, note: "發 — “to prosper”. A triplet always scores.")
            case .white: return TileName(english: "White Dragon", traditional: "白板", jyutping: "baahk báan",
                                         category: .honor, note: "The blank dragon. A triplet always scores.")
            }
        case let .flower(f):
            let i = f.rawValue
            return TileName(english: "\(flowerEN[i]) (Flower)", traditional: flowerZH[i], jyutping: flowerJyut[i],
                            category: .bonus, note: "A bonus flower — set aside; each matching one is worth faan.")
        case let .season(s):
            let i = s.rawValue
            return TileName(english: "\(seasonEN[i]) (Season)", traditional: seasonZH[i], jyutping: seasonJyut[i],
                            category: .bonus, note: "A bonus season — set aside; each matching one is worth faan.")
        }
    }

    // MARK: Tables

    private static let ordinal = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]
    private static let cn      = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    private static let numJyut = ["", "jāt", "yih", "sāam", "sei", "ńgh", "luhk", "chāt", "baat", "gáu"]

    private static func suitInfo(_ s: Suit) -> (english: String, zh: String, jyut: String) {
        switch s {
        case .characters: return ("Characters", "萬", "maahn")
        case .dots:       return ("Dots", "筒", "tùhng")
        case .bamboo:     return ("Bamboo", "索", "sok")
        }
    }

    private static let windEN   = ["East", "South", "West", "North"]
    private static let windZH   = ["東", "南", "西", "北"]
    private static let windJyut = ["dūng", "nàahm", "sāi", "bāk"]

    private static let flowerEN   = ["", "Plum", "Orchid", "Chrysanthemum", "Bamboo"]
    private static let flowerZH   = ["", "梅", "蘭", "菊", "竹"]
    private static let flowerJyut = ["", "mùih", "làahn", "gūk", "jūk"]

    private static let seasonEN   = ["", "Spring", "Summer", "Autumn", "Winter"]
    private static let seasonZH   = ["", "春", "夏", "秋", "冬"]
    private static let seasonJyut = ["", "chēun", "hah", "chāu", "dūng"]

    private static func note(forSuited suit: Suit, rank: Int) -> String {
        if suit == .bamboo && rank == 1 {
            return "Despite its name, the 1 of Bamboo is drawn as a bird, not a stick — a classic beginner trip-up."
        }
        if rank == 1 || rank == 9 { return "A terminal tile (1 or 9) — part of many terminal/honor hands." }
        return ""
    }
}
