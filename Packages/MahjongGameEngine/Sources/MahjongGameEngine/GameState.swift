import Foundation
import MahjongCore
import ScoringEngine
import CoachEngine

/// Authoritative, deterministic, single-hand HK Mahjong state machine.
/// It owns all physical tiles and rejects an action before it changes state.
public struct GameState: Sendable {
    public static let rulesProfileID = "hk_3faan_v2"
    /// Frozen identity of `configs/rules/hk_3faan_v2.yaml` in the certified
    /// Python simulator. Replays fail closed if this contract changes.
    public static let rulesHash = "0e0ce106e67fbc42"

    public private(set) var players: [GamePlayer]
    public private(set) var wallOrder: [Int]
    public private(set) var wallFront: Int
    public private(set) var wallRear: Int
    public private(set) var river: [[TileInstance]]
    /// Retained even when a physical river tile is claimed, matching obs_v3.
    public private(set) var discardHistory: [(seat: Int, tile: Tile)]
    public private(set) var phase: GamePhase
    public private(set) var currentPlayer: Int
    public private(set) var dealer: Int
    public private(set) var prevailingWind: Wind
    public private(set) var turn: Int
    public private(set) var lastDraw: Tile?
    public private(set) var lastDrawInstance: TileInstance?
    public private(set) var lastDrawKind: DrawKind?
    public private(set) var offer: PendingOffer?
    public private(set) var pendingReactions: [Int: Int]
    public private(set) var reactionEligible: [Int]
    public private(set) var events: [GameEventV2]
    public private(set) var replayActions: [ReplayActionV2]
    public private(set) var seed: UInt64
    public private(set) var terminal: TerminalResult?
    private var afterKong = false
    private var afterDoubleKong = false
    private var firstTurn = true
    private var eastDiscarded = false

    public var wallRemaining: Int { max(0, wallRear - wallFront) }
    public var isTerminal: Bool { phase == .terminal }
    public var terminalResult: TerminalResult? { terminal }

    public static func newGame(seed: UInt64 = 0, suppliedWall: [Int]? = nil, dealer: Int = 0, prevailingWind: Wind = .east) throws -> GameState {
        guard (0..<4).contains(dealer) else { throw MahjongGameError.invalidWall }
        let wall: [Int]
        if let suppliedWall { try TileInstance.validateWall(suppliedWall); wall = suppliedWall }
        else { wall = deterministicShuffledWall(seed: seed) }
        var players: [GamePlayer] = []
        for seat in 0..<4 { players.append(GamePlayer(id: seat, seatWind: Wind(rawValue: (seat - dealer + 4) % 4)!)) }
        var state = GameState(players: players, wallOrder: wall, wallFront: 0, wallRear: 144, river: Array(repeating: [], count: 4), discardHistory: [], phase: .deal, currentPlayer: dealer, dealer: dealer, prevailingWind: prevailingWind, turn: 0, lastDraw: nil, lastDrawInstance: nil, lastDrawKind: nil, offer: nil, pendingReactions: [:], reactionEligible: [], events: [], replayActions: [], seed: seed, terminal: nil)
        state.deal()
        try state.checkInvariants().throwIfFailed()
        return state
    }

    public static func replay(_ replay: GameReplayV2) throws -> GameState {
        guard replay.rulesProfileID == rulesProfileID, replay.rulesHash == rulesHash else { throw MahjongGameError.replayMismatch("rules identity") }
        var state = try newGame(seed: replay.seed, suppliedWall: replay.wallInstanceIDs, dealer: replay.initialDealer, prevailingWind: replay.prevailingWind)
        for (index, step) in replay.actions.enumerated() {
            guard state.currentActor == step.actor else { throw MahjongGameError.replayMismatch("actor at \(index)") }
            try state.apply(actionID: step.actionID)
        }
        guard state.terminal == replay.terminal else { throw MahjongGameError.replayMismatch("terminal") }
        guard state.events.map(EventSignature.init) == replay.events.map(EventSignature.init) else { throw MahjongGameError.replayMismatch("events") }
        return state
    }

    public var currentActor: Int? {
        switch phase {
        case .selfAction: return currentPlayer
        case .reaction: return reactionEligible.first(where: { pendingReactions[$0] == nil })
        default: return nil
        }
    }

    public func legalActions(for seat: Int) -> [GameAction] { legalMask(for: seat).enumerated().compactMap { $0.element ? try? GameAction(id: $0.offset) : nil } }

    public func legalMask(for seat: Int) -> [Bool] {
        var mask = Array(repeating: false, count: 127)
        guard !isTerminal, (0..<4).contains(seat) else { return mask }
        if phase == .selfAction, seat == currentPlayer {
            if canSelfWin(seat) { mask[1] = true }
            for tile in Tile.allBase where count(tile, in: players[seat].concealed) > 0 { mask[tile.classIndex + 2] = true }
            for tile in Tile.allBase {
                if count(tile, in: players[seat].concealed) == 4 { mask[59 + tile.classIndex] = true }
                if count(tile, in: players[seat].concealed) > 0, players[seat].melds.contains(where: { $0.kind == .pung && $0.tiles.first?.tile == tile }) { mask[93 + tile.classIndex] = true }
            }
        } else if phase == .reaction, reactionEligible.contains(seat), let offer {
            mask[0] = true
            if canClaimWin(seat) { mask[1] = true }
            guard !offer.isRobKong else { return mask }
            let held = count(offer.tile, in: players[seat].concealed)
            if held >= 2 { mask[57] = true }
            if held >= 3 { mask[58] = true }
            if seat == (offer.fromSeat + 1) % 4 {
                for (index, pattern) in chowPatterns.enumerated() where pattern.contains(offer.tile) && canChow(seat, pattern: pattern, offer: offer.tile) { mask[36 + index] = true }
            }
        }
        return mask
    }

    public mutating func apply(actionID: Int) throws {
        guard !isTerminal else { throw MahjongGameError.terminal }
        guard let actor = currentActor else { throw MahjongGameError.noCurrentActor }
        guard (0..<127).contains(actionID), legalMask(for: actor)[actionID] else { throw MahjongGameError.illegalAction(actionID, actor) }
        let action = try GameAction(id: actionID)
        if phase == .selfAction { try applySelf(actor, action) }
        else { submitReaction(actor, actionID: actionID) }
        replayActions.append(ReplayActionV2(actor: actor, actionID: actionID))
        try checkInvariants().throwIfFailed()
    }

    public func observation(for seat: Int) -> PublicObservationV3 {
        precondition((0..<4).contains(seat))
        let publicCounts = physicalPublicCounts()
        let mine = histogram(players[seat].concealed)
        let relSeats = (1...3).map { (seat + $0) % 4 }
        return PublicObservationV3(
            concealed: mine, melds: players[seat].melds, flowers: players[seat].flowers.map(\.tile),
            opponentMelds: relSeats.map { players[$0].melds }, opponentFlowers: relSeats.map { players[$0].flowers.map(\.tile) }, opponentDiscards: relSeats.map { river[$0].map(\.tile) }, ownDiscards: river[seat].map(\.tile),
            physicalPublic: publicCounts, remainingBelief: (0..<34).map { max(0, 4 - mine[$0] - publicCounts[$0]) },
            seatWind: players[seat].seatWind, prevailingWind: prevailingWind, dealerRelative: (dealer - seat + 4) % 4, dealerAbsolute: dealer,
            wallRemaining: wallRemaining, turn: turn, phase: phase, lastDraw: seat == currentPlayer ? lastDraw : nil, lastDrawKind: seat == currentPlayer ? lastDrawKind : nil,
            offerTile: offer?.tile, offerFromRelative: offer.map { ($0.fromSeat - seat + 4) % 4 }, offerFromAbsolute: offer?.fromSeat,
            legalMask: legalMask(for: seat), isTerminal: isTerminal)
    }

    public func serializeReplay() -> GameReplayV2 { GameReplayV2(seed: seed, wallInstanceIDs: wallOrder, initialDealer: dealer, prevailingWind: prevailingWind, actions: replayActions, events: events, terminal: terminal) }

    public func checkInvariants() -> InvariantReport {
        var messages: [String] = []
        var locations: [Int: String] = [:]
        func add(_ instance: TileInstance, _ label: String) { if locations[instance.id] != nil { messages.append("duplicate instance \(instance.id)") }; locations[instance.id] = label }
        if wallFront <= wallRear, wallFront >= 0, wallRear <= 144 { for i in wallFront..<wallRear { add(TileInstance.standard[wallOrder[i]], "wall") } } else { messages.append("bad wall cursors") }
        for seat in 0..<4 { for t in players[seat].concealed { add(t, "concealed") }; for meld in players[seat].melds { for t in meld.tiles { add(t, "meld") } }; for t in players[seat].flowers { add(t, "flower") }; for t in river[seat] { add(t, "river") } }
        if locations.count != 144 { messages.append("instance conservation \(locations.count)/144") }
        if let terminal, terminal.payments.count != 4 || terminal.payments.reduce(0, +) != 0 { messages.append("payments not zero sum") }
        for player in players { if player.concealed.contains(where: \.isBonus) { messages.append("bonus concealed") } }
        return InvariantReport(ok: messages.isEmpty, messages: messages)
    }

    // MARK: - State transitions

    private mutating func deal() {
        for _ in 0..<13 { for offset in 0..<4 { give((dealer + offset) % 4, drawFront(), kind: .ordinary, emitDraw: false) } }
        replaceFlowersForIncompleteHands()
        guard !isTerminal else { return }
        emit(.deal, dealer)
        phase = .draw; currentPlayer = dealer; drawForCurrent(.ordinary)
    }

    private mutating func drawForCurrent(_ kind: DrawKind) {
        var drawKind = kind
        while !isTerminal {
            guard wallRemaining > 0 else { exhaustive(); return }
            let instance = drawKind == .ordinary ? drawFront() : drawRear()
            if instance.isBonus {
                give(currentPlayer, instance, kind: drawKind, emitDraw: true)
                // Every bonus requires its replacement from the rear, including
                // a flower revealed by an ordinary front-wall draw.
                drawKind = .flowerReplacement
                continue
            }
            give(currentPlayer, instance, kind: drawKind, emitDraw: true)
            phase = .selfAction
            return
        }
    }

    private mutating func give(_ seat: Int, _ instance: TileInstance, kind: DrawKind, emitDraw: Bool) {
        if instance.isBonus {
            players[seat].flowers.append(instance)
            emit(.flower, seat, tile: instance.tile, instance: instance, drawKind: kind)
            if players[seat].flowers.count >= 8 { finishFlowerWin(seat, .flowerEight) }
            else if players[seat].flowers.count >= 7 { finishFlowerWin(seat, .flowerSeven) }
        } else {
            players[seat].concealed.append(instance); players[seat].concealed.sort { $0.tile == $1.tile ? $0.id < $1.id : $0.tile < $1.tile }
            if emitDraw { lastDraw = instance.tile; lastDrawInstance = instance; lastDrawKind = kind; emit(.draw, seat, tile: instance.tile, instance: instance, drawKind: kind) }
        }
    }

    private mutating func replaceFlowersForIncompleteHands() {
        // Match simulator-v2 exactly: each pass gives every incomplete seat one
        // regular replacement, while a flower chain continues from the rear for
        // that seat before play advances. Repeat passes until all hands have 13.
        var changed = true
        while changed && !isTerminal {
            changed = false
            for seat in 0..<4 {
                while !isTerminal && players[seat].concealed.count < 13 && wallRemaining > 0 {
                    let flowerCount = players[seat].flowers.count
                    give(seat, drawRear(), kind: .flowerReplacement, emitDraw: false)
                    changed = true
                    if isTerminal { return }
                    if players[seat].flowers.count == flowerCount {
                        break
                    }
                }
            }
        }
    }

    private mutating func applySelf(_ seat: Int, _ action: GameAction) throws {
        switch action.kind {
        case .win: finishWin(seat, source: .selfDraw, discarder: nil, winningTile: lastDraw)
        case .discard:
            guard let tile = action.tile, let instance = take(tile, from: seat, count: 1).first else { throw MahjongGameError.illegalAction(action.id, seat) }
            river[seat].append(instance); discardHistory.append((seat, tile)); emit(.discard, seat, tile: tile, instance: instance)
            lastDraw = nil; lastDrawInstance = nil; lastDrawKind = nil; afterKong = false; afterDoubleKong = false
            if seat == dealer && firstTurn { eastDiscarded = true }; turn += 1
            offer = PendingOffer(tile: tile, fromSeat: seat, instance: instance); openReactions(excluding: seat)
        case .concealedKong:
            guard let tile = action.tile else { return }; let tiles = take(tile, from: seat, count: 4)
            players[seat].melds.append(GameMeld(kind: .concealedKong, tiles: tiles)); emit(.concealedKong, seat, tile: tile); declareKongAndDraw(seat)
        case .addedKong:
            guard let tile = action.tile else { return }; let upgrade = take(tile, from: seat, count: 1)
            guard let index = players[seat].melds.firstIndex(where: { $0.kind == .pung && $0.tiles.first?.tile == tile }) else { throw MahjongGameError.illegalAction(action.id, seat) }
            players[seat].melds[index].kind = .addedKong; players[seat].melds[index].tiles += upgrade
            emit(.addedKong, seat, tile: tile); offer = PendingOffer(tile: tile, fromSeat: seat, instance: upgrade.first, isRobKong: true); openReactions(excluding: seat)
        default: throw MahjongGameError.illegalAction(action.id, seat)
        }
    }

    private mutating func submitReaction(_ seat: Int, actionID: Int) {
        pendingReactions[seat] = actionID
        if actionID == 0 { emit(.pass, seat) }
        if pendingReactions.count == reactionEligible.count { resolveReactions() }
    }

    private mutating func openReactions(excluding excluded: Int) {
        phase = .reaction; pendingReactions = [:]; reactionEligible = []
        // Temporarily expose each candidate to legal-mask evaluation, then install
        // the complete eligibility list atomically.
        var eligible: [Int] = []
        for seat in 0..<4 where seat != excluded {
            reactionEligible = [seat]
            if legalMask(for: seat).dropFirst().contains(true) { eligible.append(seat) }
        }
        reactionEligible = eligible
        if eligible.isEmpty { resolveReactions() }
    }

    private mutating func resolveReactions() {
        guard let offer else { return }
        let sorted = pendingReactions.sorted { distance($0.key, from: offer.fromSeat) < distance($1.key, from: offer.fromSeat) }
        if let win = sorted.first(where: { $0.value == 1 }) { finishWin(win.key, source: offer.isRobKong ? .robKong : .discard, discarder: offer.fromSeat, winningTile: offer.tile); return }
        if offer.isRobKong { clearReaction(); currentPlayer = offer.fromSeat; declareKongAndDraw(currentPlayer); return }
        if let claim = sorted.first(where: { $0.value == 57 || $0.value == 58 }) { applyClaim(seat: claim.key, actionID: claim.value, offer: offer); return }
        if let claim = sorted.first(where: { (36...56).contains($0.value) }) { applyClaim(seat: claim.key, actionID: claim.value, offer: offer); return }
        clearReaction(); firstTurn = false; currentPlayer = (offer.fromSeat + 1) % 4; phase = .draw; drawForCurrent(.ordinary)
    }

    private mutating func applyClaim(seat: Int, actionID: Int, offer: PendingOffer) {
        guard let claimed = removeOfferedPhysicalTile(offer) else { return }
        let action = try! GameAction(id: actionID)
        switch action.kind {
        case .pung:
            let tiles = take(offer.tile, from: seat, count: 2) + [claimed]; players[seat].melds.append(GameMeld(kind: .pung, tiles: tiles, fromSeat: offer.fromSeat, claimedTile: offer.tile)); emit(.pung, seat, tile: offer.tile, instance: claimed)
        case .exposedKong:
            let tiles = take(offer.tile, from: seat, count: 3) + [claimed]; players[seat].melds.append(GameMeld(kind: .exposedKong, tiles: tiles, fromSeat: offer.fromSeat, claimedTile: offer.tile)); emit(.kong, seat, tile: offer.tile, instance: claimed); clearReaction(); currentPlayer = seat; declareKongAndDraw(seat); return
        case .chow:
            let pattern = chowPatterns[action.chowIndex!]; var tiles = [claimed]
            for tile in pattern where tile != offer.tile { tiles += take(tile, from: seat, count: 1) }
            players[seat].melds.append(GameMeld(kind: .chow, tiles: tiles, fromSeat: offer.fromSeat, claimedTile: offer.tile)); emit(.chow, seat, tile: offer.tile, instance: claimed, data: [action.chowIndex!])
        default: return
        }
        clearReaction(); currentPlayer = seat; lastDraw = nil; lastDrawInstance = nil; lastDrawKind = nil; phase = .selfAction
    }

    private mutating func declareKongAndDraw(_ seat: Int) { let wasAfter = afterKong; afterKong = true; afterDoubleKong = wasAfter; currentPlayer = seat; phase = .draw; drawForCurrent(.kongReplacement) }
    private mutating func clearReaction() { offer = nil; pendingReactions = [:]; reactionEligible = [] }

    private mutating func finishWin(_ seat: Int, source: WinSource, discarder: Int?, winningTile: Tile?) {
        if (source == .discard || source == .robKong), let offered = offer {
            if !offered.isRobKong, let inst = removeOfferedPhysicalTile(offered) {
                players[seat].concealed.append(inst)
            } else if offered.isRobKong, let inst = offered.instance {
                // Move, don't copy, the promoted tile out of the declarer's meld.
                if let meld = players[offered.fromSeat].melds.firstIndex(where: { $0.kind == .addedKong && $0.tiles.contains(inst) }) {
                    players[offered.fromSeat].melds[meld].tiles.removeAll { $0.id == inst.id }
                    players[offered.fromSeat].melds[meld].kind = .pung
                }
                players[seat].concealed.append(inst)
            }
        }
        let result = score(for: seat, selfDraw: source == .selfDraw, robKong: source == .robKong)
        let faan = min(13, result.totalFaan)
        let patterns = result.components.map { PatternLine(name: $0.englishName, faan: $0.faan) }
        let payments = paymentVector(faan: faan, winner: seat, source: source, discarder: discarder)
        for index in 0..<4 { players[index].score += payments[index] }
        emit(.win, seat, tile: winningTile)
        terminal = TerminalResult(cause: "win", winner: seat, discarder: discarder, winSource: source, patternBreakdown: patterns, faan: faan, payments: payments)
        phase = .terminal; clearReaction()
    }

    private mutating func finishFlowerWin(_ seat: Int, _ source: WinSource) {
        let faan = source == .flowerEight ? 13 : 3
        let payments = paymentVector(faan: faan, winner: seat, source: source, discarder: nil)
        for i in 0..<4 { players[i].score += payments[i] }; emit(.win, seat)
        terminal = TerminalResult(cause: "win", winner: seat, winSource: source, patternBreakdown: [PatternLine(name: source == .flowerEight ? "Eight flowers" : "Seven flowers", faan: faan)], faan: faan, payments: payments); phase = .terminal
    }

    private mutating func exhaustive() { emit(.exhaustive, currentPlayer); terminal = TerminalResult(cause: "exhaustive"); phase = .terminal; clearReaction() }

    // MARK: - Rules helpers

    private func canSelfWin(_ seat: Int) -> Bool {
        guard standardWinningShape(for: seat) else { return false }
        let result = score(for: seat, selfDraw: true, robKong: false)
        return result.isWin && result.meetsMinimum
    }
    private func canClaimWin(_ seat: Int) -> Bool {
        guard let offer else { return false }; var copy = self; if !offer.isRobKong, let inst = offer.instance { copy.players[seat].concealed.append(inst) } else if offer.isRobKong, let inst = offer.instance { copy.players[seat].concealed.append(inst) }
        guard copy.standardWinningShape(for: seat) else { return false }
        let result = copy.score(for: seat, selfDraw: false, robKong: offer.isRobKong)
        return result.isWin && result.meetsMinimum
    }
    private func score(for seat: Int, selfDraw: Bool, robKong: Bool) -> ScoreResult {
        let player = players[seat]
        let melds: [Meld] = player.melds.map { meld in
            let kind: MeldKind = meld.kind == .chow ? .chow : (meld.kind == .pung ? .pung : .kong)
            return Meld(kind: kind, tiles: meld.tiles.map(\.tile), isConcealed: meld.isConcealed)
        }
        let rules = HouseRules(minimumFaan: 3, faanLimit: 13, scoreFlowers: true)
        let context = GameContext(seatWind: player.seatWind, prevailingWind: prevailingWind, houseRules: rules, isLastTile: wallRemaining == 0, isReplacement: afterKong, isRobbingKong: robKong)
        return ScoringEngine.score(hand: Hand(concealedTiles: player.concealed.map(\.tile), melds: melds, bonusTiles: player.flowers.map(\.tile), winningTile: selfDraw ? lastDraw : offer?.tile, isSelfDraw: selfDraw), context: context, table: hk3FaanV2Table)
    }
    private func standardWinningShape(for seat: Int) -> Bool {
        let player = players[seat]
        let melds: [Meld] = player.melds.map { Meld(kind: $0.kind == .chow ? .chow : ($0.kind == .pung ? .pung : .kong), tiles: $0.tiles.map(\.tile), isConcealed: $0.isConcealed) }
        return !HandParser.standardDecompositions(concealed: player.concealed.map(\.tile), fixedMelds: melds).isEmpty
    }
    private func canChow(_ seat: Int, pattern: [Tile], offer: Tile) -> Bool { pattern.filter { $0 != offer }.allSatisfy { count($0, in: players[seat].concealed) > 0 } }
    private func paymentVector(faan: Int, winner: Int, source: WinSource, discarder: Int?) -> [Int] {
        let table = [1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384]; let base = table[max(0, min(13, faan))]; var out = Array(repeating: 0, count: 4)
        if source == .selfDraw || source == .flowerSeven || source == .flowerEight {
            let total = base * 3 / 2; let each = total / 3; var remainder = total % 3
            for seat in 0..<4 where seat != winner { out[seat] -= each }
            var cursor = (winner + 1) % 4; while remainder > 0 { if cursor != winner { out[cursor] -= 1; remainder -= 1 }; cursor = (cursor + 1) % 4 }
            out[winner] = -out.reduce(0, +)
        } else if let discarder { out[discarder] = -base; out[winner] = base }
        return out
    }

    private mutating func take(_ tile: Tile, from seat: Int, count: Int) -> [TileInstance] { var selected: [TileInstance] = []; players[seat].concealed.removeAll { instance in if instance.tile == tile && selected.count < count { selected.append(instance); return true }; return false }; return selected }
    private mutating func removeOfferedPhysicalTile(_ offer: PendingOffer) -> TileInstance? { guard let index = river[offer.fromSeat].lastIndex(where: { $0.id == offer.instance?.id }) else { return nil }; return river[offer.fromSeat].remove(at: index) }
    private mutating func drawFront() -> TileInstance { let item = TileInstance.standard[wallOrder[wallFront]]; wallFront += 1; return item }
    private mutating func drawRear() -> TileInstance { wallRear -= 1; return TileInstance.standard[wallOrder[wallRear]] }
    private mutating func emit(_ kind: GameEventKind, _ seat: Int, tile: Tile? = nil, instance: TileInstance? = nil, drawKind: DrawKind? = nil, data: [Int] = []) { events.append(GameEventV2(id: deterministicEventUUID(events.count), kind: kind, seat: seat, tile: tile, instanceID: instance?.id, drawKind: drawKind, data: data)) }
    private func histogram(_ tiles: [TileInstance]) -> [Int] { var counts = Array(repeating: 0, count: 34); for tile in tiles where !tile.isBonus { counts[tile.tile.classIndex] += 1 }; return counts }
    private func physicalPublicCounts() -> [Int] { var counts = Array(repeating: 0, count: 34); for seat in 0..<4 { for tile in river[seat] where !tile.isBonus { counts[tile.tile.classIndex] += 1 }; for meld in players[seat].melds { for tile in meld.tiles where !tile.isBonus { counts[tile.tile.classIndex] += 1 } } }; return counts }
    private func count(_ tile: Tile, in tiles: [TileInstance]) -> Int { tiles.filter { $0.tile == tile }.count }
    private func distance(_ seat: Int, from discarder: Int) -> Int { (seat - discarder + 4) % 4 }
}

public struct InvariantReport: Sendable, Hashable { public var ok: Bool; public var messages: [String]; public init(ok: Bool, messages: [String] = []) { self.ok = ok; self.messages = messages }; public func throwIfFailed() throws { if !ok { throw MahjongGameError.invariantFailure(messages) } } }

private struct EventSignature: Equatable { let kind: GameEventKind; let seat: Int; let tile: Tile?; let instanceID: Int?; let drawKind: DrawKind?; let data: [Int]; init(_ event: GameEventV2) { kind = event.kind; seat = event.seat; tile = event.tile; instanceID = event.instanceID; drawKind = event.drawKind; data = event.data } }

private let hk3FaanV2Table = FaanTable(values: {
    var values = FaanTable.standard.values
    values[.chickenHand] = 1
    values[.fullFlush] = 7
    values[.sevenPairs] = 0
    return values
}())

private func deterministicEventUUID(_ index: Int) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, UInt8((index >> 24) & 0xFF), UInt8((index >> 16) & 0xFF), UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF), 0, 0, 0, 2))
}

/// Small stable PRNG, deliberately independent of Swift's randomized APIs.
private struct SplitMix64 { var state: UInt64; mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
private func deterministicShuffledWall(seed: UInt64) -> [Int] { var wall = Array(0..<144); var rng = SplitMix64(state: seed); for i in stride(from: wall.count - 1, through: 1, by: -1) { wall.swapAt(i, Int(rng.next() % UInt64(i + 1))) }; return wall }
