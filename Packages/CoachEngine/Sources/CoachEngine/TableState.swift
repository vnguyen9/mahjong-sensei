import MahjongCore
import ScoringEngine

/// A snapshot of one player's hand and the table around it — the tracker's
/// truth, and the sole input to ``CoachAdvisor/advise(_:)``.
///
/// Ownership: the tracker (today's `ScanSession`, or its successor) builds
/// this fresh every frame from recognized tiles, the discard pond, and
/// opponents' revealed melds. CoachEngine treats it as a pure value — it
/// never mutates or persists a `TableState`.
public struct TableState: Sendable, Hashable {
    /// Concealed tiles held in hand — 13 (awaiting a draw) or 14 (deciding a
    /// discard), minus 3 per declared meld. Bonus tiles are excluded; see
    /// ``bonusTiles``.
    public var concealed: [Tile]
    /// This player's declared melds (claimed pung/chow, declared kongs).
    public var melds: [Meld]
    /// This player's flowers/seasons, set aside.
    public var bonusTiles: [Tile]
    /// 34-slot `classIndex`-keyed count of tiles visible on the table
    /// **excluding** this player's own concealed hand and melds — the
    /// discard pond plus every opponent's revealed melds. Mirrors the `seen`
    /// parameter threaded through `EfficiencyEngine.ukeire(_:melds:seen:)`.
    public var seenHistogram: [Int]
    /// Tiles nobody has seen yet: `136 − mine − seen` (the `ScanSession`
    /// convention). Drives the "next draw" odds and, absent
    /// ``drawsRemaining``, the go-arounds-left derivation.
    public var unseenCount: Int
    /// Go-arounds left in the wall, when the tracker's event log can compute
    /// it exactly. `nil` lets the advisor derive an estimate from
    /// ``unseenCount``.
    public var drawsRemaining: Int?
    /// Opponents' declared meld count, for the same go-arounds derivation.
    /// Defaults to 0 when the tracker doesn't track opponent melds.
    public var opponentMeldCount: Int
    /// Seat + prevailing wind and house rules (minimum faan, limit, flowers).
    public var context: GameContext

    public init(concealed: [Tile],
                melds: [Meld] = [],
                bonusTiles: [Tile] = [],
                seenHistogram: [Int],
                unseenCount: Int,
                drawsRemaining: Int? = nil,
                opponentMeldCount: Int = 0,
                context: GameContext = GameContext()) {
        self.concealed = concealed
        self.melds = melds
        self.bonusTiles = bonusTiles
        self.seenHistogram = seenHistogram
        self.unseenCount = unseenCount
        self.drawsRemaining = drawsRemaining
        self.opponentMeldCount = opponentMeldCount
        self.context = context
    }
}

/// Where a hand stands relative to a discard decision, derived from
/// `Hand.effectiveTileCount` (a declared kong still counts as 3).
public enum HandPhase: Sendable, Hashable {
    /// 14 effective tiles — rank the discards.
    case discardDecision
    /// 13 effective tiles — no discard to make; report the current wait instead.
    case awaitingDraw
    /// A 14-tile winning shape that meets the table's minimum faan — declare it.
    case win(ScoreResult)
    /// Neither 13 nor 14 effective tiles reached the advisor (a tracker gate
    /// failure, or a kong mid-resolve). The advisor degrades gracefully
    /// rather than crashing; `expected` is the nearer of 13/14.
    case invalid(expected: Int, actual: Int)
}
