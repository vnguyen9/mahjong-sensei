import XCTest
@testable import MahjongGameEngine
import MahjongCore

final class MahjongGameEngineTests: XCTestCase {
    func testActionsCoverStableContract() throws {
        XCTAssertEqual(GameAction.all.count, 127)
        XCTAssertEqual(try GameAction(id: 0).kind, .pass)
        XCTAssertEqual(try GameAction(id: 126).kind, .addedKong)
    }

    func testSeededWallAndConservationAreDeterministic() throws {
        let first = try GameState.newGame(seed: 42)
        let second = try GameState.newGame(seed: 42)
        XCTAssertEqual(first.wallOrder, second.wallOrder)
        XCTAssertTrue(first.checkInvariants().ok)
        XCTAssertEqual(first.players.map { $0.concealed.count }.reduce(0, +), 53)
    }

    func testSuppliedWallAndReplay() throws {
        var game = try GameState.newGame(seed: 0, suppliedWall: Array(0..<144))
        while !game.isTerminal, game.replayActions.count < 8 {
            guard let actor = game.currentActor else { XCTFail("missing actor"); return }
            let action = game.legalActions(for: actor).first { $0.kind == .discard } ?? game.legalActions(for: actor).first!
            try game.apply(actionID: action.id)
        }
        XCTAssertTrue(game.checkInvariants().ok)
        let restored = try GameState.replay(game.serializeReplay())
        XCTAssertEqual(restored.replayActions, game.replayActions)
    }

    func testObservationDoesNotContainOpponentConcealedTiles() throws {
        let game = try GameState.newGame(seed: 7)
        let observation = game.observation(for: 0)
        XCTAssertEqual(observation.concealed.count, 34)
        XCTAssertEqual(observation.opponentMelds.count, 3)
        XCTAssertEqual(observation.legalMask.count, 127)
    }

    func testFlowerReplacementUsesRearWall() throws {
        var wall = Array(0..<144)
        // Put plum at the next front draw and a base tile at the rear, while
        // preserving a full wall permutation.
        wall[52] = 136
        wall[136] = 143
        wall[143] = 52
        let game = try GameState.newGame(seed: 0, suppliedWall: wall)
        XCTAssertEqual(game.players[0].flowers.map(\.id), [136])
        XCTAssertTrue(game.events.contains { $0.kind == .flower && $0.instanceID == 136 })
        XCTAssertTrue(game.checkInvariants().ok)
    }

    func testAuthoritativePythonV2SuppliedWallFixtures() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "python_v2_supplied_wall",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let corpus = try JSONDecoder().decode(
            PythonParityCorpus.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(corpus.rulesProfileID, GameState.rulesProfileID)
        XCTAssertEqual(corpus.rulesHash, GameState.rulesHash)

        for fixture in corpus.cases {
            let wind = try XCTUnwrap(Wind(rawValue: fixture.prevailingWind))
            let game = try GameState.newGame(
                seed: UInt64(fixture.seed),
                suppliedWall: fixture.suppliedWall,
                dealer: fixture.dealer,
                prevailingWind: wind
            )

            XCTAssertEqual(game.currentActor, fixture.currentActor, fixture.id)
            XCTAssertEqual(game.wallFront, fixture.wallFront, fixture.id)
            XCTAssertEqual(game.wallRear, fixture.wallRear, fixture.id)
            XCTAssertEqual(game.wallRemaining, fixture.wallRemaining, fixture.id)
            XCTAssertEqual(pythonPhase(game.phase), fixture.phase, fixture.id)
            XCTAssertEqual(game.lastDraw?.classIndex, fixture.lastDraw, fixture.id)
            XCTAssertEqual(game.lastDrawInstance?.id, fixture.lastDrawInstance, fixture.id)
            XCTAssertEqual(pythonDrawKind(game.lastDrawKind), fixture.lastDrawKind, fixture.id)

            for seat in 0..<4 {
                let expectedPlayer = fixture.players[seat]
                XCTAssertEqual(game.players[seat].seatWind.rawValue, expectedPlayer.seatWind, fixture.id)
                XCTAssertEqual(histogram(game.players[seat].concealed), expectedPlayer.concealed, fixture.id)
                XCTAssertEqual(game.players[seat].flowers.map { $0.tile.classIndex - 34 }, expectedPlayer.flowers, fixture.id)

                let actual = game.observation(for: seat)
                let expected = fixture.observations[seat]
                XCTAssertEqual(actual.concealed, expected.concealed, fixture.id)
                XCTAssertEqual(actual.flowers.map { $0.classIndex - 34 }, expected.flowers, fixture.id)
                XCTAssertEqual(
                    actual.opponentFlowers.map { $0.map { $0.classIndex - 34 } },
                    expected.opponentFlowers,
                    fixture.id
                )
                XCTAssertEqual(actual.ownDiscards.map(\.classIndex), expected.ownDiscards, fixture.id)
                XCTAssertEqual(
                    actual.opponentDiscards.map { $0.map(\.classIndex) },
                    expected.opponentDiscards,
                    fixture.id
                )
                XCTAssertEqual(actual.physicalPublic, expected.physicalPublic, fixture.id)
                XCTAssertEqual(actual.remainingBelief, expected.remainingBelief, fixture.id)
                XCTAssertEqual(actual.seatWind.rawValue, expected.seatWind, fixture.id)
                XCTAssertEqual(actual.prevailingWind.rawValue, expected.prevailingWind, fixture.id)
                XCTAssertEqual(actual.dealerRelative, expected.dealerRelative, fixture.id)
                XCTAssertEqual(actual.dealerAbsolute, expected.dealerAbsolute, fixture.id)
                XCTAssertEqual(actual.wallRemaining, expected.wallRemaining, fixture.id)
                XCTAssertEqual(actual.turn, expected.turn, fixture.id)
                XCTAssertEqual(pythonPhase(actual.phase), expected.phase, fixture.id)
                XCTAssertEqual(actual.lastDraw?.classIndex, expected.lastDraw, fixture.id)
                XCTAssertEqual(pythonDrawKind(actual.lastDrawKind), expected.lastDrawKind, fixture.id)
                XCTAssertEqual(actual.offerTile?.classIndex, expected.offerTile, fixture.id)
                XCTAssertEqual(actual.offerFromRelative, expected.offerFromRelative, fixture.id)
                XCTAssertEqual(actual.offerFromAbsolute, expected.offerFromAbsolute, fixture.id)
                XCTAssertEqual(
                    actual.legalMask.enumerated().compactMap { $0.element ? $0.offset : nil },
                    expected.legalActions,
                    fixture.id
                )
                XCTAssertEqual(actual.isTerminal, expected.isTerminal, fixture.id)
            }

            XCTAssertEqual(game.events.count, fixture.events.count, fixture.id)
            for (actual, expected) in zip(game.events, fixture.events) {
                XCTAssertEqual(pythonEventKind(actual.kind), expected.kind, fixture.id)
                XCTAssertEqual(actual.seat, expected.seat, fixture.id)
                XCTAssertEqual(
                    actual.tile.map { actual.kind == .flower ? $0.classIndex - 34 : $0.classIndex },
                    expected.tileType,
                    fixture.id
                )
                XCTAssertEqual(actual.instanceID, expected.instanceID, fixture.id)
                XCTAssertEqual(pythonDrawKind(actual.drawKind), expected.drawKind, fixture.id)
                XCTAssertEqual(actual.data, expected.data, fixture.id)
            }
        }
    }

    func testOneThousandSeededHandsConserveEveryPhysicalTile() throws {
        // Keep normal package CI responsive; `MJ_FULL_SIM_STRESS=1 swift test`
        // executes the promised 1,000 full hands before a simulator release.
        let rounds = ProcessInfo.processInfo.environment["MJ_FULL_SIM_STRESS"] == "1" ? 1_000 : 24
        for seed in 0..<rounds {
            var game = try GameState.newGame(seed: UInt64(seed), dealer: seed % 4)
            var guardTurns = 0
            while !game.isTerminal {
                guardTurns += 1
                if guardTurns >= 300 {
                    XCTFail("seed \(seed) did not finish")
                    break
                }
                guard let actor = game.currentActor else { XCTFail("missing actor for seed \(seed)"); break }
                let actions = game.legalActions(for: actor)
                let action = actions.first(where: { $0.kind == .win })
                    ?? actions.first(where: { $0.kind == .discard })
                    ?? actions.first(where: { $0.kind == .pass })
                    ?? actions.first!
                try game.apply(actionID: action.id)
            }
            XCTAssertTrue(game.checkInvariants().ok, "seed \(seed)")
            XCTAssertEqual(game.terminal?.payments.reduce(0, +), 0)
        }
    }
}

private func histogram(_ tiles: [TileInstance]) -> [Int] {
    var counts = Array(repeating: 0, count: 34)
    for tile in tiles where !tile.isBonus {
        counts[tile.tile.classIndex] += 1
    }
    return counts
}

private func pythonPhase(_ phase: GamePhase) -> String {
    switch phase {
    case .deal: return "DEAL"
    case .draw: return "DRAW"
    case .selfAction: return "SELF_ACTION"
    case .reaction: return "REACTION"
    case .terminal: return "TERMINAL"
    }
}

private func pythonDrawKind(_ kind: DrawKind?) -> String? {
    switch kind {
    case .ordinary: return "ordinary"
    case .flowerReplacement: return "flower_replacement"
    case .kongReplacement: return "kong_replacement"
    case nil: return nil
    }
}

private func pythonEventKind(_ kind: GameEventKind) -> String {
    switch kind {
    case .pung: return "pong"
    case .addedKong: return "added_kong"
    case .concealedKong: return "concealed_kong"
    default: return kind.rawValue
    }
}

private struct PythonParityCorpus: Decodable {
    var rulesProfileID: String
    var rulesHash: String
    var cases: [PythonParityCase]

    enum CodingKeys: String, CodingKey {
        case rulesProfileID = "rules_profile_id"
        case rulesHash = "rules_hash"
        case cases
    }
}

private struct PythonParityCase: Decodable {
    var id: String
    var seed: Int
    var suppliedWall: [Int]
    var dealer: Int
    var prevailingWind: Int
    var currentActor: Int?
    var wallFront: Int
    var wallRear: Int
    var wallRemaining: Int
    var phase: String
    var lastDraw: Int?
    var lastDrawInstance: Int?
    var lastDrawKind: String?
    var players: [PythonPlayerSnapshot]
    var events: [PythonEventSnapshot]
    var observations: [PythonObservationSnapshot]

    enum CodingKeys: String, CodingKey {
        case id, seed, dealer, phase, players, events, observations
        case suppliedWall = "supplied_wall"
        case prevailingWind = "prevailing_wind"
        case currentActor = "current_actor"
        case wallFront = "wall_front"
        case wallRear = "wall_rear"
        case wallRemaining = "wall_remaining"
        case lastDraw = "last_draw"
        case lastDrawInstance = "last_draw_instance"
        case lastDrawKind = "last_draw_kind"
    }
}

private struct PythonPlayerSnapshot: Decodable {
    var seatWind: Int
    var concealed: [Int]
    var flowers: [Int]

    enum CodingKeys: String, CodingKey {
        case seatWind = "seat_wind"
        case concealed, flowers
    }
}

private struct PythonEventSnapshot: Decodable {
    var kind: String
    var seat: Int
    var tileType: Int?
    var instanceID: Int?
    var drawKind: String?
    var data: [Int]

    enum CodingKeys: String, CodingKey {
        case kind, seat, data
        case tileType = "tile_type"
        case instanceID = "instance_id"
        case drawKind = "draw_kind"
    }
}

private struct PythonObservationSnapshot: Decodable {
    var concealed: [Int]
    var flowers: [Int]
    var opponentFlowers: [[Int]]
    var ownDiscards: [Int]
    var opponentDiscards: [[Int]]
    var physicalPublic: [Int]
    var remainingBelief: [Int]
    var seatWind: Int
    var prevailingWind: Int
    var dealerRelative: Int
    var dealerAbsolute: Int
    var wallRemaining: Int
    var turn: Int
    var phase: String
    var lastDraw: Int?
    var lastDrawKind: String?
    var offerTile: Int?
    var offerFromRelative: Int?
    var offerFromAbsolute: Int?
    var legalActions: [Int]
    var isTerminal: Bool

    enum CodingKeys: String, CodingKey {
        case concealed, flowers, turn, phase
        case opponentFlowers = "opp_flowers"
        case ownDiscards = "own_discards"
        case opponentDiscards = "opp_discards"
        case physicalPublic = "physical_public"
        case remainingBelief = "remaining_belief"
        case seatWind = "seat_wind"
        case prevailingWind = "prevailing_wind"
        case dealerRelative = "dealer_rel"
        case dealerAbsolute = "dealer_abs"
        case wallRemaining = "wall_remaining"
        case lastDraw = "last_draw"
        case lastDrawKind = "last_draw_kind"
        case offerTile = "offer_tile"
        case offerFromRelative = "offer_from_rel"
        case offerFromAbsolute = "offer_from_abs"
        case legalActions = "legal_actions"
        case isTerminal = "is_terminal"
    }
}
