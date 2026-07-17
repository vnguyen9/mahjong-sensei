import Foundation

/// A hand under evaluation: concealed tiles + exposed melds + bonus tiles.
public struct Hand: Sendable, Codable, Hashable {
    /// Concealed tiles held in hand (includes the winning tile when scoring a win).
    public var concealedTiles: [Tile]
    /// Exposed / declared melds (claimed pung/chow, declared kongs).
    public var melds: [Meld]
    /// Flowers & seasons set aside (never part of a scoring set).
    public var bonusTiles: [Tile]
    /// The tile that completed the hand, if scoring a win.
    public var winningTile: Tile?
    /// Won by self-draw (自摸) vs off a discard (食糊).
    public var isSelfDraw: Bool

    public init(concealedTiles: [Tile] = [],
                melds: [Meld] = [],
                bonusTiles: [Tile] = [],
                winningTile: Tile? = nil,
                isSelfDraw: Bool = false) {
        self.concealedTiles = concealedTiles.sorted()
        self.melds = melds
        self.bonusTiles = bonusTiles.sorted()
        self.winningTile = winningTile
        self.isSelfDraw = isSelfDraw
    }

    /// All tiles forming the scoring hand (concealed + meld tiles), excluding bonus.
    public var allTiles: [Tile] { (concealedTiles + melds.flatMap(\.tiles)).sorted() }

    /// Hand size counting each kong as 3 — the value checked against 13/14.
    public var effectiveTileCount: Int {
        concealedTiles.count + melds.reduce(0) { $0 + ($1.kind == .kong ? 3 : $1.tiles.count) }
    }

    /// A fully concealed hand (門前清): every meld concealed.
    public var isFullyConcealed: Bool { melds.allSatisfy(\.isConcealed) }
}

/// House-rule knobs that vary by table (HK Old Style defaults).
public struct HouseRules: Sendable, Codable, Hashable {
    /// Minimum faan to declare a win (三番起糊 etc.). 0 = no minimum.
    public var minimumFaan: Int
    /// Faan cap / limit (滿糊). Scores at or above are capped.
    public var faanLimit: Int
    /// Award faan for your seat flower/season and for a full bouquet.
    public var scoreFlowers: Bool

    public init(minimumFaan: Int = 3, faanLimit: Int = 10, scoreFlowers: Bool = true) {
        self.minimumFaan = minimumFaan
        self.faanLimit = faanLimit
        self.scoreFlowers = scoreFlowers
    }
    public static let standard = HouseRules()
}

/// Round/seat context needed to score a hand.
public struct GameContext: Sendable, Codable, Hashable {
    public var seatWind: Wind          // 門風
    public var prevailingWind: Wind    // 圈風
    public var houseRules: HouseRules
    public var isLastTile: Bool        // 海底撈月 / 河底撈魚
    public var isReplacement: Bool     // 花上開花 / 槓上開花
    public var isRobbingKong: Bool     // 搶槓

    public init(seatWind: Wind = .east,
                prevailingWind: Wind = .east,
                houseRules: HouseRules = .standard,
                isLastTile: Bool = false,
                isReplacement: Bool = false,
                isRobbingKong: Bool = false) {
        self.seatWind = seatWind
        self.prevailingWind = prevailingWind
        self.houseRules = houseRules
        self.isLastTile = isLastTile
        self.isReplacement = isReplacement
        self.isRobbingKong = isRobbingKong
    }
}
