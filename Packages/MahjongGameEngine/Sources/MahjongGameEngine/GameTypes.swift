import Foundation
import MahjongCore

/// The physical, uniquely identified tile used by the simulator. IDs 0...135
/// are four copies of the 34 base faces; IDs 136...143 are the eight bonuses.
public struct TileInstance: Codable, Hashable, Sendable, Identifiable, Comparable {
    public let id: Int
    public let tile: Tile

    public init(id: Int, tile: Tile) { self.id = id; self.tile = tile }
    public var isBonus: Bool { tile.isBonus }
    public static func < (lhs: TileInstance, rhs: TileInstance) -> Bool { lhs.id < rhs.id }

    public static let standard: [TileInstance] = (0..<144).map { id in
        if id < 136 { return TileInstance(id: id, tile: Tile(classIndex: id / 4)!) }
        return TileInstance(id: id, tile: Tile(classIndex: 34 + id - 136)!)
    }

    public static func validateWall(_ ids: [Int]) throws {
        guard ids.count == 144, Set(ids).count == 144, ids.sorted() == Array(0..<144) else {
            throw MahjongGameError.invalidWall
        }
    }
}

public enum GameActionKind: String, Codable, CaseIterable, Sendable {
    case pass, win, discard, chow, pung, exposedKong, concealedKong, addedKong
}

/// Stable v1 action encoding shared with the Python/Core ML policy contract.
public struct GameAction: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let kind: GameActionKind
    public let tile: Tile?
    public let chowIndex: Int?

    public init(id: Int) throws {
        guard (0...126).contains(id) else { throw MahjongGameError.invalidActionID(id) }
        self.id = id
        switch id {
        case 0: kind = .pass; tile = nil; chowIndex = nil
        case 1: kind = .win; tile = nil; chowIndex = nil
        case 2...35: kind = .discard; tile = Tile(classIndex: id - 2)!; chowIndex = nil
        case 36...56: kind = .chow; tile = nil; chowIndex = id - 36
        case 57: kind = .pung; tile = nil; chowIndex = nil
        case 58: kind = .exposedKong; tile = nil; chowIndex = nil
        case 59...92: kind = .concealedKong; tile = Tile(classIndex: id - 59)!; chowIndex = nil
        default: kind = .addedKong; tile = Tile(classIndex: id - 93)!; chowIndex = nil
        }
    }

    public static let all: [GameAction] = (0...126).compactMap { try? GameAction(id: $0) }
    public static func discard(_ tile: Tile) -> GameAction { try! GameAction(id: tile.classIndex + 2) }
    public static func chow(_ index: Int) -> GameAction { try! GameAction(id: 36 + index) }
}

/// Canonical 21 chow patterns, three suits each beginning at ranks 1...7.
public let chowPatterns: [[Tile]] = [Suit.characters, .dots, .bamboo].flatMap { suit in
    (1...7).map { start in [Tile.suited(suit, start), .suited(suit, start + 1), .suited(suit, start + 2)] }
}

public enum GamePhase: String, Codable, Sendable { case deal, draw, selfAction, reaction, terminal }
public enum DrawKind: String, Codable, Sendable { case ordinary, flowerReplacement, kongReplacement }
public enum WinSource: String, Codable, Sendable { case selfDraw, discard, robKong, flowerSeven, flowerEight }
public enum GameEventKind: String, Codable, Sendable { case deal, draw, flower, discard, chow, pung, kong, addedKong, concealedKong, pass, win, exhaustive }
public enum GameMeldKind: String, Codable, Sendable { case chow, pung, exposedKong, concealedKong, addedKong }

public struct GameMeld: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var kind: GameMeldKind
    public var tiles: [TileInstance]
    public var fromSeat: Int?
    public var claimedTile: Tile?
    public init(id: UUID = UUID(), kind: GameMeldKind, tiles: [TileInstance], fromSeat: Int? = nil, claimedTile: Tile? = nil) {
        self.id = id; self.kind = kind; self.tiles = tiles.sorted(); self.fromSeat = fromSeat; self.claimedTile = claimedTile
    }
    public var isConcealed: Bool { kind == .concealedKong }
}

public struct GamePlayer: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public var seatWind: Wind
    public var concealed: [TileInstance]
    public var melds: [GameMeld]
    public var flowers: [TileInstance]
    public var score: Int
    public init(id: Int, seatWind: Wind, concealed: [TileInstance] = [], melds: [GameMeld] = [], flowers: [TileInstance] = [], score: Int = 0) {
        self.id = id; self.seatWind = seatWind; self.concealed = concealed; self.melds = melds; self.flowers = flowers; self.score = score
    }
}

public struct PendingOffer: Codable, Hashable, Sendable {
    public var tile: Tile
    public var fromSeat: Int
    public var instance: TileInstance?
    public var isRobKong: Bool
    public init(tile: Tile, fromSeat: Int, instance: TileInstance? = nil, isRobKong: Bool = false) { self.tile = tile; self.fromSeat = fromSeat; self.instance = instance; self.isRobKong = isRobKong }
}

public struct GameEventV2: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var kind: GameEventKind
    public var seat: Int
    public var tile: Tile?
    public var instanceID: Int?
    public var drawKind: DrawKind?
    public var data: [Int]
    public init(id: UUID = UUID(), kind: GameEventKind, seat: Int, tile: Tile? = nil, instanceID: Int? = nil, drawKind: DrawKind? = nil, data: [Int] = []) {
        self.id = id; self.kind = kind; self.seat = seat; self.tile = tile; self.instanceID = instanceID; self.drawKind = drawKind; self.data = data
    }
}

public struct PatternLine: Codable, Hashable, Sendable { public var name: String; public var faan: Int; public init(name: String, faan: Int) { self.name = name; self.faan = faan } }
public struct TerminalResult: Codable, Hashable, Sendable {
    public var cause: String
    public var winner: Int?
    public var discarder: Int?
    public var winSource: WinSource?
    public var patternBreakdown: [PatternLine]
    public var faan: Int
    public var payments: [Int]
    public init(cause: String, winner: Int? = nil, discarder: Int? = nil, winSource: WinSource? = nil, patternBreakdown: [PatternLine] = [], faan: Int = 0, payments: [Int] = [0, 0, 0, 0]) {
        self.cause = cause; self.winner = winner; self.discarder = discarder; self.winSource = winSource; self.patternBreakdown = patternBreakdown; self.faan = faan; self.payments = payments
    }
}

public struct ReplayActionV2: Codable, Hashable, Sendable { public var actor: Int; public var actionID: Int; public init(actor: Int, actionID: Int) { self.actor = actor; self.actionID = actionID } }
public struct GameReplayV2: Codable, Hashable, Sendable {
    public var rulesProfileID: String
    public var rulesHash: String
    public var seed: UInt64
    public var wallInstanceIDs: [Int]
    public var initialDealer: Int
    public var prevailingWind: Wind
    public var actions: [ReplayActionV2]
    public var events: [GameEventV2]
    public var terminal: TerminalResult?
    public init(rulesProfileID: String = "hk_3faan_v2", rulesHash: String = "0e0ce106e67fbc42", seed: UInt64, wallInstanceIDs: [Int], initialDealer: Int, prevailingWind: Wind, actions: [ReplayActionV2] = [], events: [GameEventV2] = [], terminal: TerminalResult? = nil) { self.rulesProfileID = rulesProfileID; self.rulesHash = rulesHash; self.seed = seed; self.wallInstanceIDs = wallInstanceIDs; self.initialDealer = initialDealer; self.prevailingWind = prevailingWind; self.actions = actions; self.events = events; self.terminal = terminal }
}

/// Public policy input. Opponents' concealed tiles are deliberately absent.
public struct PublicObservationV3: Codable, Hashable, Sendable {
    public var schema: String = "PublicObservationV3"
    public var concealed: [Int]
    public var melds: [GameMeld]
    public var flowers: [Tile]
    public var opponentMelds: [[GameMeld]]
    public var opponentFlowers: [[Tile]]
    public var opponentDiscards: [[Tile]]
    public var ownDiscards: [Tile]
    public var physicalPublic: [Int]
    public var remainingBelief: [Int]
    public var seatWind: Wind
    public var prevailingWind: Wind
    public var dealerRelative: Int
    public var dealerAbsolute: Int
    public var wallRemaining: Int
    public var turn: Int
    public var phase: GamePhase
    public var lastDraw: Tile?
    public var lastDrawKind: DrawKind?
    public var offerTile: Tile?
    public var offerFromRelative: Int?
    public var offerFromAbsolute: Int?
    public var legalMask: [Bool]
    public var isTerminal: Bool
}

public struct PolicyDecision: Codable, Hashable, Sendable { public var actionID: Int; public var diagnostics: String?; public init(actionID: Int, diagnostics: String? = nil) { self.actionID = actionID; self.diagnostics = diagnostics } }
public protocol MahjongPolicy: Sendable { func decision(for observation: PublicObservationV3, legalMask: [Bool]) async throws -> PolicyDecision }

public enum MahjongGameError: Error, LocalizedError, Sendable, Equatable {
    case invalidWall, invalidActionID(Int), illegalAction(Int, Int), noCurrentActor, terminal, replayMismatch(String), invariantFailure([String])
    public var errorDescription: String? { switch self { case .invalidWall: return "Wall must be a permutation of 0...143"; case let .invalidActionID(id): return "Invalid action id \(id)"; case let .illegalAction(id, seat): return "Action \(id) is illegal for seat \(seat)"; case .noCurrentActor: return "No player is currently acting"; case .terminal: return "The hand has finished"; case let .replayMismatch(s): return "Replay mismatch: \(s)"; case let .invariantFailure(s): return s.joined(separator: "; ") } }
}

/// Declares the deliberately narrow compatibility boundary while the production
/// scorer is being certified. The simulator contract (wall, actions, claims,
/// observation, replay and payments) is v2; scoring reuses the app scorer with
/// v2 values for common hand/full flush and rejects seven-pairs. Python parity
/// fixtures should be added before treating every exotic flower exclusion as
/// policy-training truth.
public enum RulesCompatibility {
    public static let profileID = "hk_3faan_v2"
    public static let scoringNotes = "Uses ScoringEngine with v2 3-faan, 13-cap, common-hand=1, full-flush=7; seven pairs disabled. Exotic flower-set exclusions remain pending scorer parity fixtures."
}
