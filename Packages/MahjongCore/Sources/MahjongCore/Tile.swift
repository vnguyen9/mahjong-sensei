import Foundation

// MARK: - Suit & honor kinds

/// The three number ("simple") suits. Ranks run 1...9.
public enum Suit: String, CaseIterable, Sendable, Codable, Hashable {
    case characters   // 萬  man / wàn   — code suffix "m"
    case dots         // 筒  pin / tǒng  — code suffix "p"
    case bamboo       // 索  sou / suǒ   — code suffix "s"

    /// Single-letter code suffix used in the 42-class schema ("m" / "p" / "s").
    public var codeSuffix: String {
        switch self {
        case .characters: return "m"
        case .dots:       return "p"
        case .bamboo:     return "s"
        }
    }
}

public enum Wind: Int, CaseIterable, Sendable, Codable, Hashable, Comparable {
    case east = 0, south, west, north
    public static func < (l: Wind, r: Wind) -> Bool { l.rawValue < r.rawValue }
}

public enum Dragon: Int, CaseIterable, Sendable, Codable, Hashable, Comparable {
    case red = 0    // 中  — code "RD"
    case green      // 發  — code "GD"
    case white      // 白  — code "WD"
    public static func < (l: Dragon, r: Dragon) -> Bool { l.rawValue < r.rawValue }
}

/// Bonus "flower" tiles 梅蘭菊竹 (F1–F4).
public enum Flower: Int, CaseIterable, Sendable, Codable, Hashable, Comparable {
    case plum = 1, orchid, chrysanthemum, bamboo
    public static func < (l: Flower, r: Flower) -> Bool { l.rawValue < r.rawValue }
}

/// Bonus "season" tiles 春夏秋冬 (S1–S4).
public enum Season: Int, CaseIterable, Sendable, Codable, Hashable, Comparable {
    case spring = 1, summer, autumn, winter
    public static func < (l: Season, r: Season) -> Bool { l.rawValue < r.rawValue }
}

// MARK: - Tile

/// A single mahjong tile.
///
/// The 42-class schema (matches the recognizer label set and the PRD):
/// `1m–9m · 1p–9p · 1s–9s · E S W N · RD GD WD · F1–F4 · S1–S4`.
/// `classIndex` is the single source of truth for the tile ↔ index mapping
/// consumed by the recognizer's label list and the game engines.
public enum Tile: Hashable, Sendable, Codable {
    case suited(Suit, Int)   // rank 1...9
    case wind(Wind)
    case dragon(Dragon)
    case flower(Flower)
    case season(Season)
}

// MARK: - Ergonomic constructors

public extension Tile {
    /// Characters/萬 tile of the given rank (1...9).
    static func m(_ rank: Int) -> Tile { .suited(.characters, rank) }
    /// Dots/筒 tile of the given rank (1...9).
    static func p(_ rank: Int) -> Tile { .suited(.dots, rank) }
    /// Bamboo/索 tile of the given rank (1...9).
    static func s(_ rank: Int) -> Tile { .suited(.bamboo, rank) }

    static let east  = Tile.wind(.east)
    static let south = Tile.wind(.south)
    static let west  = Tile.wind(.west)
    static let north = Tile.wind(.north)

    static let redDragon   = Tile.dragon(.red)
    static let greenDragon = Tile.dragon(.green)
    static let whiteDragon = Tile.dragon(.white)
}

// MARK: - Canonical ordering / class index

public extension Tile {
    /// Total number of distinct tile faces in the 42-class schema.
    static let classCount = 42
    /// Number of "base" faces (excludes the 8 bonus tiles): 27 suited + 4 winds + 3 dragons.
    static let baseClassCount = 34

    /// Stable 0-based index into the 42-class schema (see the type doc).
    var classIndex: Int {
        switch self {
        case let .suited(.characters, r): return r - 1          // 0...8
        case let .suited(.dots, r):       return 9 + r - 1       // 9...17
        case let .suited(.bamboo, r):     return 18 + r - 1      // 18...26
        case let .wind(w):                return 27 + w.rawValue // 27...30
        case let .dragon(d):              return 31 + d.rawValue // 31...33
        case let .flower(f):              return 34 + f.rawValue - 1  // 34...37
        case let .season(s):              return 38 + s.rawValue - 1  // 38...41
        }
    }

    /// Reconstructs a tile from its canonical class index (0..<42).
    init?(classIndex i: Int) {
        switch i {
        case 0...8:   self = .suited(.characters, i + 1)
        case 9...17:  self = .suited(.dots, i - 9 + 1)
        case 18...26: self = .suited(.bamboo, i - 18 + 1)
        case 27...30: self = .wind(Wind(rawValue: i - 27)!)
        case 31...33: self = .dragon(Dragon(rawValue: i - 31)!)
        case 34...37: self = .flower(Flower(rawValue: i - 34 + 1)!)
        case 38...41: self = .season(Season(rawValue: i - 38 + 1)!)
        default: return nil
        }
    }

    /// All 42 faces in canonical order.
    static let allCanonical: [Tile] = (0..<classCount).compactMap(Tile.init(classIndex:))
    /// The 34 base faces (no flowers/seasons) in canonical order.
    static let allBase: [Tile] = (0..<baseClassCount).compactMap(Tile.init(classIndex:))
}

extension Tile: Comparable {
    public static func < (l: Tile, r: Tile) -> Bool { l.classIndex < r.classIndex }
}

// MARK: - Codes ("1m", "E", "RD", "F1", …)

public extension Tile {
    /// ASCII code from the 42-class schema.
    var code: String {
        switch self {
        case let .suited(suit, r): return "\(r)\(suit.codeSuffix)"
        case .wind(.east):  return "E"
        case .wind(.south): return "S"
        case .wind(.west):  return "W"
        case .wind(.north): return "N"
        case .dragon(.red):   return "RD"
        case .dragon(.green): return "GD"
        case .dragon(.white): return "WD"
        case let .flower(f): return "F\(f.rawValue)"
        case let .season(s): return "S\(s.rawValue)"
        }
    }

    /// Parses an ASCII schema code (case-insensitive). Winds `E/S/W/N`, dragons
    /// `RD/GD/WD`, suited `<rank><m|p|s>`, bonus `F1–F4` / `S1–S4`.
    init?(code raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let upper = s.uppercased()
        switch upper {
        case "E": self = .wind(.east);  return
        case "S": self = .wind(.south); return
        case "W": self = .wind(.west);  return
        case "N": self = .wind(.north); return
        case "RD": self = .dragon(.red);   return
        case "GD": self = .dragon(.green); return
        case "WD": self = .dragon(.white); return
        default: break
        }
        guard upper.count == 2, let lead = upper.first else { return nil }
        let tail = String(upper.dropFirst())
        // Bonus tiles carry a letter lead: F1–F4, S1–S4.
        if lead == "F", let r = Int(tail), let f = Flower(rawValue: r) { self = .flower(f); return }
        if lead == "S", let r = Int(tail), let se = Season(rawValue: r) { self = .season(se); return }
        // Suited tiles carry a digit lead: <rank><suit>.
        guard let rank = Int(String(lead)), (1...9).contains(rank) else { return nil }
        switch upper.last {
        case "M": self = .suited(.characters, rank)
        case "P": self = .suited(.dots, rank)
        case "S": self = .suited(.bamboo, rank)
        default: return nil
        }
    }
}

// MARK: - Classification

public extension Tile {
    /// True for the three number suits (characters/dots/bamboo).
    var isSuited: Bool { if case .suited = self { return true }; return false }
    /// True for winds and dragons.
    var isHonor: Bool {
        switch self { case .wind, .dragon: return true; default: return false }
    }
    /// True for flowers and seasons (set aside, never part of a scoring set).
    var isBonus: Bool {
        switch self { case .flower, .season: return true; default: return false }
    }
    /// Suited 1 or 9.
    var isTerminal: Bool { if case let .suited(_, r) = self { return r == 1 || r == 9 }; return false }
    /// Suited 2...8.
    var isSimple: Bool { if case let .suited(_, r) = self { return r >= 2 && r <= 8 }; return false }
    /// Terminal or honor — the "yao jiu" set used by many yaku.
    var isTerminalOrHonor: Bool { isTerminal || isHonor }

    /// The suit for a number tile, else nil.
    var suit: Suit? { if case let .suited(su, _) = self { return su }; return nil }
    /// The rank for a number tile, else nil.
    var rank: Int? { if case let .suited(_, r) = self { return r }; return nil }
}

// MARK: - Unicode glyph (best effort; the UI draws tiles procedurally)

public extension Tile {
    /// A Unicode Mahjong Tiles code point where one exists (fallback rendering / debugging).
    var unicodeGlyph: String? {
        let base: Int
        switch self {
        case let .suited(.characters, r): base = 0x1F007 + (r - 1)
        case let .suited(.dots, r):       base = 0x1F019 + (r - 1)
        case let .suited(.bamboo, r):     base = 0x1F010 + (r - 1)
        case .wind(.east):  base = 0x1F000
        case .wind(.south): base = 0x1F001
        case .wind(.west):  base = 0x1F002
        case .wind(.north): base = 0x1F003
        case .dragon(.red):   base = 0x1F004
        case .dragon(.green): base = 0x1F005
        case .dragon(.white): base = 0x1F006
        case let .flower(f): base = 0x1F022 + (f.rawValue - 1)
        case let .season(s): base = 0x1F026 + (s.rawValue - 1)
        }
        return Unicode.Scalar(base).map { String($0) }
    }
}

extension Tile: CustomStringConvertible {
    public var description: String { code }
}
