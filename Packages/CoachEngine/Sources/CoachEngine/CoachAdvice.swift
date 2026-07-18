import MahjongCore
import ScoringEngine

/// One tile that would advance the hand (an ukeire entry), paired with how
/// many copies are still live versus already visible on the table.
public struct TileCount: Sendable, Hashable {
    /// The accepting tile.
    public let tile: Tile
    /// Copies not yet visible anywhere (`4 −` hand − melds − seen, clamped at
    /// 0). Zero means this out is dead.
    public let liveCount: Int
    /// Copies already visible on the table (discard pond + opponents' melds).
    public let seenCount: Int

    public init(tile: Tile, liveCount: Int, seenCount: Int) {
        self.tile = tile
        self.liveCount = liveCount
        self.seenCount = seenCount
    }
}

/// A tenpai wait chip: one tile that completes the hand, with its exact faan
/// on both win channels.
public struct WaitInfo: Sendable, Hashable {
    /// The winning tile.
    public let tile: Tile
    public let liveCount: Int
    public let seenCount: Int
    /// Exact faan if this tile is won off a discard (門前清 channel).
    public let faanIfWon: Int
    /// Exact faan if this tile is self-drawn (自摸 channel). Always `>= faanIfWon`
    /// (自摸 adds one faan; 門前清 adds one only when the hand is concealed).
    public let faanIfSelfDrawn: Int
    /// Whether this wait can be declared at all — true iff it clears
    /// `houseRules.minimumFaan` on **at least one** win channel. Because
    /// `faanIfSelfDrawn >= faanIfWon`, this is equivalently
    /// `faanIfSelfDrawn >= minimumFaan`. A live wait with `meetsMinimum == false`
    /// is a *chicken wait* (see `AdviceReason.chickenWait`): a win you cannot
    /// legally call. The narrower case `faanIfWon < minimum <= faanIfSelfDrawn`
    /// is a self-draw-only wait (討自摸) — declarable, but only by tsumo; the UI
    /// reads that nuance straight off the two faan values.
    public let meetsMinimum: Bool
    /// `liveCount == 0` — every copy of this wait is already visible.
    public let isDead: Bool

    public init(tile: Tile,
                liveCount: Int,
                seenCount: Int,
                faanIfWon: Int,
                faanIfSelfDrawn: Int,
                meetsMinimum: Bool,
                isDead: Bool) {
        self.tile = tile
        self.liveCount = liveCount
        self.seenCount = seenCount
        self.faanIfWon = faanIfWon
        self.faanIfSelfDrawn = faanIfSelfDrawn
        self.meetsMinimum = meetsMinimum
        self.isDead = isDead
    }
}

/// One candidate discard from a 14-tile hand, ranked by expected value.
///
/// - Note: Phase 0 (`CoachAdvisor.advise`) populates this with
///   efficiency-derived placeholders — `expectedFaan`/`expectedValue` are 0
///   and `reasons` is empty — until the EV task lands `WinProbability` and
///   `FaanPotential`. The shape is real today so the UI can build against it.
public struct RankedDiscard: Sendable, Hashable, Identifiable {
    public var id: Int { tile.classIndex }
    /// The tile this option discards.
    public let tile: Tile
    /// Shanten of the resulting 13-tile hand.
    public let shantenAfter: Int
    /// Tiles that advance the resulting hand — always populated.
    public let ukeire: [TileCount]
    /// Total live copies across `ukeire`.
    public let ukeireTotal: Int
    /// Tenpai wait chips — non-nil iff `shantenAfter == 0`.
    public let waits: [WaitInfo]?
    /// Probability of winning within the remaining go-arounds (the plan's
    /// §2a absorbing-chain model). Range 0...1.
    public let winProbability: Double
    /// `EfficiencyEngine.winOdds` for this option — the "next draw" chip.
    public let nextDrawOdds: Double
    /// Wait-weighted exact faan at tenpai, or the estimator's typical faan
    /// before tenpai.
    public let expectedFaan: Double
    /// Faan guaranteed on any completion of this option.
    public let faanFloor: Int
    /// Best faan reachable from this option (exact at tenpai).
    public let faanCeiling: Int
    /// Expected value in `PaymentCalculator` base-point units (`2^faan`) —
    /// the ranking key.
    public let expectedValue: Double
    /// The minimum-faan guardrail: false when even the best reachable faan is
    /// below the table's minimum. The option is still ranked (last), not hidden.
    public let meetsMinimum: Bool
    /// Salience-ordered "why" chips; the UI shows the first 1–2.
    public let reasons: [AdviceReason]

    public init(tile: Tile,
                shantenAfter: Int,
                ukeire: [TileCount],
                ukeireTotal: Int,
                waits: [WaitInfo]?,
                winProbability: Double,
                nextDrawOdds: Double,
                expectedFaan: Double,
                faanFloor: Int,
                faanCeiling: Int,
                expectedValue: Double,
                meetsMinimum: Bool,
                reasons: [AdviceReason]) {
        self.tile = tile
        self.shantenAfter = shantenAfter
        self.ukeire = ukeire
        self.ukeireTotal = ukeireTotal
        self.waits = waits
        self.winProbability = winProbability
        self.nextDrawOdds = nextDrawOdds
        self.expectedFaan = expectedFaan
        self.faanFloor = faanFloor
        self.faanCeiling = faanCeiling
        self.expectedValue = expectedValue
        self.meetsMinimum = meetsMinimum
        self.reasons = reasons
    }
}

/// Advice for a 13-tile hand awaiting a draw: the current wait, not a discard
/// choice.
public struct WaitSet: Sendable, Hashable {
    public let shanten: Int
    /// Non-nil iff `shanten == 0`.
    public let waits: [WaitInfo]?
    public let ukeire: [TileCount]
    public let totalLive: Int
    public let nextDrawOdds: Double
    public let winProbability: Double
    public let expectedFaan: Double
    public let meetsMinimum: Bool

    public init(shanten: Int,
                waits: [WaitInfo]?,
                ukeire: [TileCount],
                totalLive: Int,
                nextDrawOdds: Double,
                winProbability: Double,
                expectedFaan: Double,
                meetsMinimum: Bool) {
        self.shanten = shanten
        self.waits = waits
        self.ukeire = ukeire
        self.totalLive = totalLive
        self.nextDrawOdds = nextDrawOdds
        self.winProbability = winProbability
        self.expectedFaan = expectedFaan
        self.meetsMinimum = meetsMinimum
    }
}

/// The advisor's full answer for one `TableState` — the sole output of
/// ``CoachAdvisor/advise(_:)``.
public struct CoachAdvice: Sendable, Hashable {
    public let phase: HandPhase
    public let currentShanten: Int
    /// EV-sorted candidate discards; empty unless `phase == .discardDecision`.
    public let options: [RankedDiscard]
    /// `options.first`; nil unless `phase == .discardDecision`.
    public let best: RankedDiscard?
    /// Non-nil for `.awaitingDraw` (and for `.win`, kept for display).
    public let waitSet: WaitSet?
    /// Set when the 14-tile shape already wins but falls below the table's
    /// minimum faan — a legal shape the player cannot yet declare, so the
    /// phase stays `.discardDecision` instead of becoming `.win`.
    public let winnableNow: ScoreResult?
    /// True when no discard option reaches the minimum faan — every option
    /// carries the warning, and `best` is the least-bad fallback.
    public let minimumUnreachable: Bool

    public init(phase: HandPhase,
                currentShanten: Int,
                options: [RankedDiscard],
                best: RankedDiscard?,
                waitSet: WaitSet?,
                winnableNow: ScoreResult?,
                minimumUnreachable: Bool) {
        self.phase = phase
        self.currentShanten = currentShanten
        self.options = options
        self.best = best
        self.waitSet = waitSet
        self.winnableNow = winnableNow
        self.minimumUnreachable = minimumUnreachable
    }
}
