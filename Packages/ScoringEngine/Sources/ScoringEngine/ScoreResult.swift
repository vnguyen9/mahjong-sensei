import Foundation
import MahjongCore

/// A single line in a scored hand's faan breakdown.
public struct ScoreComponent: Sendable, Hashable, Codable {
    /// The scoring pattern.
    public let category: FaanCategory
    /// Faan contributed by this line. For aggregating patterns (flowers, dragon
    /// pungs) this is the summed value across all matches (e.g. two dragon pungs → 2).
    public let faan: Int

    public init(category: FaanCategory, faan: Int) {
        self.category = category
        self.faan = faan
    }

    /// Convenience passthroughs to the category's display names.
    public var englishName: String { category.englishName }
    public var traditionalChineseName: String { category.traditionalChineseName }
}

/// The scored result of one hand.
public struct ScoreResult: Sendable, Hashable {
    /// The faan breakdown. For a valid-but-scoreless shape this is `[.chickenHand]`;
    /// for a non-winning hand it is empty.
    public let components: [ScoreComponent]
    /// Sum of every component's faan, before the limit cap is applied.
    public let rawFaan: Int
    /// `min(rawFaan, HouseRules.faanLimit)` — the payable faan.
    public let totalFaan: Int
    /// True when the hand reached the limit (a named limit hand, or an accumulated
    /// score at/above the cap). Limit hands always meet the minimum.
    public let isLimitHand: Bool
    /// True when `totalFaan >= HouseRules.minimumFaan` (or the hand is a limit hand):
    /// i.e. the win may legally be declared at this table.
    public let meetsMinimum: Bool
    /// The decomposition the score was computed from (nil for a non-winning hand).
    public let winningDecomposition: HandDecomposition?
    /// True when the tiles form a valid winning shape. Note this is independent of
    /// ``meetsMinimum``: a chicken hand is a valid win that cannot be declared.
    public let isWin: Bool

    public init(components: [ScoreComponent],
                rawFaan: Int,
                totalFaan: Int,
                isLimitHand: Bool,
                meetsMinimum: Bool,
                winningDecomposition: HandDecomposition?,
                isWin: Bool) {
        self.components = components
        self.rawFaan = rawFaan
        self.totalFaan = totalFaan
        self.isLimitHand = isLimitHand
        self.meetsMinimum = meetsMinimum
        self.winningDecomposition = winningDecomposition
        self.isWin = isWin
    }

    /// The empty result for tiles that do not form any winning shape.
    public static let notAWin = ScoreResult(
        components: [],
        rawFaan: 0,
        totalFaan: 0,
        isLimitHand: false,
        meetsMinimum: false,
        winningDecomposition: nil,
        isWin: false
    )

    /// Faan contributed by a given category in this result, if present.
    public func faan(for category: FaanCategory) -> Int? {
        components.first { $0.category == category }?.faan
    }

    /// Whether the breakdown contains a given category.
    public func contains(_ category: FaanCategory) -> Bool {
        components.contains { $0.category == category }
    }
}
