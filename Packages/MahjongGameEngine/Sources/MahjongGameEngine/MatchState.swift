import Foundation
import MahjongCore

/// Difficulty belongs to a match, even while all three seats use the same
/// placeholder policy. It keeps the match/replay wire format forward-compatible
/// with the policy workstream without influencing certified hand rules.
public enum BotDifficulty: String, Codable, CaseIterable, Sendable, Hashable {
    case easy, normal, hard
}

/// Immutable inputs for one four-wind match. Table seats are absolute 0...3;
/// `humanSeat` never changes while winds and dealer positions rotate around it.
public struct MatchConfiguration: Codable, Sendable, Hashable {
    public var seed: UInt64
    public var humanSeat: Int
    public var rules: MatchRulesConfiguration
    public var botDifficulty: BotDifficulty
    public var rulesProfileID: String { (try? rules.makeProfile().id) ?? RulesProfile.hkClassicV3.id }
    public var settlementPolicyID: String { rules.settlementStyle.policy.id }

    public init(seed: UInt64 = 0,
                humanSeat: Int = 0,
                rules: MatchRulesConfiguration = MatchRulesConfiguration(),
                botDifficulty: BotDifficulty = .normal) throws {
        guard (0..<4).contains(humanSeat) else { throw MatchError.invalidHumanSeat(humanSeat) }
        self.seed = seed
        self.humanSeat = humanSeat
        self.rules = rules
        self.botDifficulty = botDifficulty
    }
}

public struct MatchSeatStats: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public var wins: Int
    public var biggestFaan: Int

    public init(seat: Int, wins: Int = 0, biggestFaan: Int = 0) {
        id = seat; self.wins = wins; self.biggestFaan = biggestFaan
    }
}

/// A settled hand, including the exact replay needed to prove its ledger entry.
public struct MatchHandRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public var handIndex: Int
    public var seed: UInt64
    public var dealer: Int
    public var prevailingWind: Wind
    public var dealerRepeatCount: Int
    public var result: TerminalResult
    public var totalsAfter: [Int]
    public var replay: GameReplayV2

    public init(handIndex: Int, seed: UInt64, dealer: Int, prevailingWind: Wind,
                dealerRepeatCount: Int, result: TerminalResult, totalsAfter: [Int], replay: GameReplayV2) {
        id = handIndex
        self.handIndex = handIndex; self.seed = seed; self.dealer = dealer; self.prevailingWind = prevailingWind
        self.dealerRepeatCount = dealerRepeatCount; self.result = result; self.totalsAfter = totalsAfter; self.replay = replay
    }
}

public struct MatchSummary: Codable, Sendable, Hashable {
    public var isComplete: Bool
    public var totals: [Int]
    public var standings: [Int]
    public var seatStats: [MatchSeatStats]
    public var handsPlayed: Int
    public init(isComplete: Bool, totals: [Int], seatStats: [MatchSeatStats], handsPlayed: Int) {
        self.isComplete = isComplete; self.totals = totals
        self.standings = (0..<4).sorted { totals[$0] == totals[$1] ? $0 < $1 : totals[$0] > totals[$1] }
        self.seatStats = seatStats; self.handsPlayed = handsPlayed
    }
}

/// Codable persistence/replay envelope. `currentHand` is retained separately so
/// replay works at an interstitial, during an active hand, and at match end.
public struct MatchReplayV1: Codable, Sendable, Hashable {
    public static let schema = "MatchReplayV1"
    public var schemaVersion: String
    public var configuration: MatchConfiguration
    public var currentHandIndex: Int
    public var currentDealer: Int
    public var prevailingWind: Wind
    public var dealerRepeatCount: Int
    public var dealerAdvancesInWind: Int
    public var totals: [Int]
    public var seatStats: [MatchSeatStats]
    public var history: [MatchHandRecord]
    public var currentHand: GameReplayV2
    public var isMatchComplete: Bool

    public init(configuration: MatchConfiguration, currentHandIndex: Int, currentDealer: Int,
                prevailingWind: Wind, dealerRepeatCount: Int, dealerAdvancesInWind: Int,
                totals: [Int], seatStats: [MatchSeatStats], history: [MatchHandRecord],
                currentHand: GameReplayV2, isMatchComplete: Bool) {
        schemaVersion = Self.schema; self.configuration = configuration; self.currentHandIndex = currentHandIndex
        self.currentDealer = currentDealer; self.prevailingWind = prevailingWind; self.dealerRepeatCount = dealerRepeatCount
        self.dealerAdvancesInWind = dealerAdvancesInWind; self.totals = totals; self.seatStats = seatStats
        self.history = history; self.currentHand = currentHand; self.isMatchComplete = isMatchComplete
    }
}

public enum MatchError: Error, LocalizedError, Sendable, Equatable {
    case invalidHumanSeat(Int), noNextHand, handNotFinished, replayMismatch(String), matchComplete
    public var errorDescription: String? {
        switch self {
        case let .invalidHumanSeat(seat): return "Human seat must be 0...3, got \(seat)"
        case .noNextHand: return "The match is complete; there is no next hand"
        case .handNotFinished: return "Finish the current hand before advancing"
        case let .replayMismatch(detail): return "Match replay mismatch: \(detail)"
        case .matchComplete: return "The match is already complete"
        }
    }
}

/// Pure, deterministic multi-hand state machine. It delegates every tile/action
/// decision to `GameState`; this wrapper only sequences completed hands and keeps
/// the match ledger, dealer rotation and wind progression.
public struct MatchState: Sendable {
    public let configuration: MatchConfiguration
    public private(set) var currentHand: GameState
    public private(set) var handIndex: Int
    public private(set) var currentDealer: Int
    public private(set) var prevailingWind: Wind
    /// Number of consecutive dealer hands, including the current one.
    public private(set) var dealerRepeatCount: Int
    public private(set) var totals: [Int]
    public private(set) var seatStats: [MatchSeatStats]
    public private(set) var history: [MatchHandRecord]
    public private(set) var isMatchComplete: Bool
    private var dealerAdvancesInWind: Int

    public init(configuration: MatchConfiguration) throws {
        self.configuration = configuration
        handIndex = 0; currentDealer = 0; prevailingWind = .east; dealerRepeatCount = 1
        totals = [0, 0, 0, 0]; seatStats = (0..<4).map { MatchSeatStats(seat: $0) }
        history = []; isMatchComplete = false; dealerAdvancesInWind = 0
        let rules = try configuration.rules.makeProfile()
        currentHand = try GameState.newGame(seed: Self.handSeed(matchSeed: configuration.seed, handIndex: 0), dealer: 0, prevailingWind: .east, rulesProfile: rules)
    }

    public var currentActor: Int? { currentHand.currentActor }
    public var canAdvanceToNextHand: Bool { currentHand.isTerminal && !isMatchComplete && history.count == handIndex + 1 }
    public var summary: MatchSummary { MatchSummary(isComplete: isMatchComplete, totals: totals, seatStats: seatStats, handsPlayed: history.count) }

    public func legalActions(for seat: Int) -> [GameAction] { currentHand.legalActions(for: seat) }
    public func legalMask(for seat: Int) -> [Bool] { currentHand.legalMask(for: seat) }
    public func observation(for seat: Int) -> PublicObservationV3 { currentHand.observation(for: seat) }

    /// Applies one action to the current hand and immediately settles it into the
    /// match ledger when that action ends the hand. The terminal hand remains
    /// visible for an interstitial until `advanceToNextHand()` is called.
    public mutating func apply(actionID: Int) throws {
        guard !isMatchComplete else { throw MatchError.matchComplete }
        try currentHand.apply(actionID: actionID)
        try recordCurrentHandIfTerminal()
    }

    /// Starts the next hand after its terminal result has been recorded.
    public mutating func advanceToNextHand() throws {
        guard currentHand.isTerminal else { throw MatchError.handNotFinished }
        guard !isMatchComplete else { throw MatchError.noNextHand }
        guard history.count == handIndex + 1 else { throw MatchError.handNotFinished }
        handIndex += 1
        currentHand = try GameState.newGame(seed: Self.handSeed(matchSeed: configuration.seed, handIndex: handIndex), dealer: currentDealer, prevailingWind: prevailingWind, rulesProfile: try configuration.rules.makeProfile())
    }

    public func serializeReplay() -> MatchReplayV1 {
        MatchReplayV1(configuration: configuration, currentHandIndex: handIndex, currentDealer: currentDealer,
                      prevailingWind: prevailingWind, dealerRepeatCount: dealerRepeatCount,
                      dealerAdvancesInWind: dealerAdvancesInWind, totals: totals, seatStats: seatStats,
                      history: history, currentHand: currentHand.serializeReplay(), isMatchComplete: isMatchComplete)
    }

    public static func replay(_ replay: MatchReplayV1) throws -> MatchState {
        guard replay.schemaVersion == MatchReplayV1.schema else { throw MatchError.replayMismatch("schema") }
        var state = try MatchState(configuration: replay.configuration)
        guard replay.history.allSatisfy({ $0.handIndex >= 0 }), replay.history.map(\.handIndex) == Array(replay.history.indices) else { throw MatchError.replayMismatch("hand index sequence") }

        for (index, record) in replay.history.enumerated() {
            guard state.handIndex == index, state.currentDealer == record.dealer,
                  state.prevailingWind == record.prevailingWind,
                  state.currentHand.seed == record.seed else { throw MatchError.replayMismatch("context at hand \(index)") }
            let rebuilt = try GameState.replay(record.replay)
            guard rebuilt.isTerminal, rebuilt.terminal == record.result else { throw MatchError.replayMismatch("terminal at hand \(index)") }
            state.currentHand = rebuilt
            try state.recordCurrentHandIfTerminal()
            guard state.history.last == record else { throw MatchError.replayMismatch("ledger at hand \(index)") }
            let needsNext = index < replay.history.count - 1 || replay.currentHandIndex == replay.history.count
            if needsNext, !state.isMatchComplete { try state.advanceToNextHand() }
        }

        guard state.handIndex == replay.currentHandIndex, state.currentDealer == replay.currentDealer,
              state.prevailingWind == replay.prevailingWind, state.dealerRepeatCount == replay.dealerRepeatCount,
              state.dealerAdvancesInWind == replay.dealerAdvancesInWind, state.totals == replay.totals,
              state.seatStats == replay.seatStats, state.isMatchComplete == replay.isMatchComplete else {
            throw MatchError.replayMismatch("derived match state")
        }
        let rebuiltCurrent = try GameState.replay(replay.currentHand)
        guard rebuiltCurrent.seed == state.currentHand.seed, rebuiltCurrent.dealer == state.currentDealer,
              rebuiltCurrent.prevailingWind == state.prevailingWind else { throw MatchError.replayMismatch("current hand context") }
        if state.currentHand.isTerminal {
            guard rebuiltCurrent.serializeReplay() == state.currentHand.serializeReplay() else { throw MatchError.replayMismatch("current terminal hand") }
        } else {
            // An active hand's action stream must rebuild from the same derived seed.
            guard rebuiltCurrent.serializeReplay() == replay.currentHand else { throw MatchError.replayMismatch("current hand actions") }
        }
        state.currentHand = rebuiltCurrent
        return state
    }

    /// Stable match seed derivation, intentionally local to the match contract.
    public static func handSeed(matchSeed: UInt64, handIndex: Int) -> UInt64 {
        var rng = MatchSplitMix64(state: matchSeed &+ UInt64(handIndex) &* 0x9E3779B97F4A7C15)
        return rng.next()
    }

    // Internal test seam: it exercises rotation/ledger with hand outcomes without
    // mutating `GameState`, which remains the single-hand rules authority.
    mutating func recordForTesting(_ result: TerminalResult) throws {
        guard !isMatchComplete else { throw MatchError.matchComplete }
        try settle(result: result, replay: currentHand.serializeReplay())
    }

    mutating func advanceForTesting() throws {
        guard !isMatchComplete, history.count == handIndex + 1 else { throw MatchError.noNextHand }
        handIndex += 1
        currentHand = try GameState.newGame(seed: Self.handSeed(matchSeed: configuration.seed, handIndex: handIndex), dealer: currentDealer, prevailingWind: prevailingWind, rulesProfile: try configuration.rules.makeProfile())
    }

    private mutating func recordCurrentHandIfTerminal() throws {
        guard let result = currentHand.terminal else { return }
        guard history.count == handIndex else { return }
        try settle(result: result, replay: currentHand.serializeReplay())
    }

    private mutating func settle(result: TerminalResult, replay: GameReplayV2) throws {
        guard result.payments.count == 4, result.payments.reduce(0, +) == 0 else { throw MatchError.replayMismatch("non-zero-sum settlement") }
        for seat in 0..<4 { totals[seat] += result.payments[seat] }
        if let winner = result.winner {
            seatStats[winner].wins += 1
            seatStats[winner].biggestFaan = max(seatStats[winner].biggestFaan, result.faan)
        }
        let record = MatchHandRecord(handIndex: handIndex, seed: currentHand.seed, dealer: currentDealer,
                                     prevailingWind: prevailingWind, dealerRepeatCount: dealerRepeatCount,
                                     result: result, totalsAfter: totals, replay: replay)
        history.append(record)
        rotate(after: result)
    }

    private mutating func rotate(after result: TerminalResult) {
        let dealerRepeats = result.cause == "exhaustive" || result.winner == currentDealer
        if dealerRepeats {
            dealerRepeatCount += 1
            return
        }
        currentDealer = (currentDealer + 1) % 4
        dealerRepeatCount = 1
        dealerAdvancesInWind += 1
        guard dealerAdvancesInWind == 4 else { return }
        dealerAdvancesInWind = 0
        if prevailingWind == .north {
            isMatchComplete = true
        } else {
            prevailingWind = Wind(rawValue: prevailingWind.rawValue + 1)!
        }
    }
}

private struct MatchSplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
