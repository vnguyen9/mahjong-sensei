import Foundation
import XCTest
@testable import Mahjong_Sensei
import MahjongCore
import MahjongGameEngine

final class MahjongLearningGameTests: XCTestCase {
    func testPersistedMatchRoundTripsThroughStrictReplay() async throws {
        let url = temporaryArchiveURL()
        let store = MahjongMatchStore(archiveURL: url)
        let state = try MatchState(configuration: MatchConfiguration(seed: 42, humanSeat: 0))
        let expected = state.serializeReplay()

        await store.save(PersistedMahjongMatchV1(replay: expected, savedAt: Date(timeIntervalSince1970: 123)))
        let loaded = await store.load()

        XCTAssertEqual(loaded?.replay, expected)
        XCTAssertEqual(loaded?.savedAt, Date(timeIntervalSince1970: 123))
        _ = try MatchState.replay(XCTUnwrap(loaded?.replay))
        try? FileManager.default.removeItem(at: url)
    }

    func testCorruptArchiveIsRejectedAndRemoved() async throws {
        let url = temporaryArchiveURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a replay".utf8).write(to: url, options: .atomic)
        let store = MahjongMatchStore(archiveURL: url)

        let loaded = await store.load()

        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testResumedSessionRestoresExactEngineState() throws {
        var state = try MatchState(configuration: MatchConfiguration(seed: 8_181, humanSeat: 0))
        let actor = try XCTUnwrap(state.currentActor)
        let action = try XCTUnwrap(state.legalActions(for: actor).first)
        try state.apply(actionID: action.id)
        let replay = state.serializeReplay()
        let store = MahjongMatchStore(archiveURL: temporaryArchiveURL())

        let session = try GameSession(replay: replay, persistence: store)

        XCTAssertEqual(session.match.serializeReplay(), replay)
        XCTAssertEqual(session.state.wallFront, state.currentHand.wallFront)
        XCTAssertEqual(session.state.wallRear, state.currentHand.wallRear)
        XCTAssertEqual(session.state.events, state.currentHand.events)
        XCTAssertEqual(session.match.currentActor, state.currentActor)
    }

    func testDiceAndWallBreakAreDeterministicAndCosmetic() throws {
        let state = try MatchState(configuration: MatchConfiguration(seed: 9_999, humanSeat: 0))
        let replayBefore = state.serializeReplay()

        let first = GameOpeningLayout(handSeed: state.currentHand.seed, dealer: state.currentHand.dealer)
        let second = GameOpeningLayout(handSeed: state.currentHand.seed, dealer: state.currentHand.dealer)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.dice.count, 3)
        XCTAssertTrue(first.dice.allSatisfy { (1...6).contains($0) })
        XCTAssertTrue((0..<72).contains(first.wallBreakStack))
        XCTAssertEqual(state.serializeReplay(), replayBefore)
    }

    func testAttentionStateTracksPhysicalDiscardAndClaimInstances() {
        let firstDiscard = GameEventV2(kind: .discard, seat: 1, tile: .s(5), instanceID: 47)
        let acceptedPung = GameEventV2(kind: .pung, seat: 3, tile: .s(5), instanceID: 47)
        let claimantDiscard = GameEventV2(kind: .discard, seat: 3, tile: .redDragon, instanceID: 91)

        var attention = GameTableAttentionState.reconstructing(events: [firstDiscard, acceptedPung])
        XCTAssertEqual(attention.lastDiscardInstanceID, 47)
        XCTAssertEqual(attention.lastClaimedInstanceID, 47)

        attention.consume([claimantDiscard])
        XCTAssertEqual(attention.lastDiscardInstanceID, 91)
        XCTAssertNil(attention.lastClaimedInstanceID)
    }

    @MainActor
    func testResumeReconstructsAttentionWithoutChangingReplay() throws {
        var state = try MatchState(configuration: MatchConfiguration(seed: 8_282, humanSeat: 0))
        let actor = try XCTUnwrap(state.currentActor)
        let discard = try XCTUnwrap(state.legalActions(for: actor).first(where: { $0.kind == .discard }))
        try state.apply(actionID: discard.id)
        let replay = state.serializeReplay()

        let session = try GameSession(
            replay: replay,
            persistence: MahjongMatchStore(archiveURL: temporaryArchiveURL())
        )

        XCTAssertEqual(session.attention, GameTableAttentionState.reconstructing(events: session.state.events))
        XCTAssertEqual(session.match.serializeReplay(), replay)
        XCTAssertEqual(
            session.attention.lastDiscardInstanceID,
            session.state.events.last(where: { $0.kind == .discard })?.instanceID
        )
    }

    @MainActor
    func testStructuralClarityPreferencesDoNotMutateReplay() {
        let oldHighlight = GameLearningPreferences.highlightNewestDiscard
        let oldHints = GameLearningPreferences.coachHintsEnabled
        defer {
            GameLearningPreferences.highlightNewestDiscard = oldHighlight
            GameLearningPreferences.coachHintsEnabled = oldHints
        }
        let session = GameSession(
            seed: 8_383,
            humanSeat: 0,
            persistence: MahjongMatchStore(archiveURL: temporaryArchiveURL())
        )
        let replay = session.match.serializeReplay()

        session.highlightNewestDiscard.toggle()
        session.coachHintsEnabled.toggle()

        XCTAssertEqual(session.match.serializeReplay(), replay)
    }

    func testLearningContextNeverAttributesUnseenTilesToAHiddenLocation() throws {
        let state = try MatchState(configuration: MatchConfiguration(seed: 202_607_22, humanSeat: 0))
        let observation = state.observation(for: 0)
        let tile = try XCTUnwrap(Tile(classIndex: observation.concealed.firstIndex(where: { $0 > 0 }) ?? -1))

        let context = GameTileInsightContext(tile: tile, origin: .humanHand, observation: observation)

        XCTAssertGreaterThanOrEqual(context.remainingUnseenCopies, 0)
        XCTAssertLessThanOrEqual(context.remainingUnseenCopies, 4)
        if let frequency = context.estimatedUnseenFrequency {
            XCTAssertTrue((0...1).contains(frequency))
        }
        XCTAssertNil(context.offeredFromSeat)
    }

    @MainActor
    func testSuggestionSelectsALegalDiscardWithoutChangingTheReplay() async throws {
        let store = MahjongMatchStore(archiveURL: temporaryArchiveURL())
        let session = GameSession(seed: 7_721, humanSeat: 0, persistence: store)
        let replayBefore = session.match.serializeReplay()

        XCTAssertTrue(session.canSuggest)
        session.suggestDiscard()
        for _ in 0..<300 where session.isSuggesting {
            try await Task.sleep(for: .milliseconds(10))
        }

        let suggestion = try XCTUnwrap(session.latestSuggestion)
        let selectedID = try XCTUnwrap(session.selectedTileID)
        let selected = try XCTUnwrap(session.player.concealed.first(where: { $0.id == selectedID }))
        XCTAssertEqual(selected.tile, suggestion.tile)
        XCTAssertTrue(session.legalActions.contains { $0.kind == .discard && $0.tile == suggestion.tile })
        XCTAssertEqual(session.match.serializeReplay(), replayBefore)
    }

    @MainActor
    func testUndoStrictlyRestoresTheStateBeforeTheHumanDecision() throws {
        let store = MahjongMatchStore(archiveURL: temporaryArchiveURL())
        let session = GameSession(seed: 7_722, humanSeat: 0, persistence: store)
        let checkpoint = session.match.serializeReplay()
        let discard = try XCTUnwrap(session.legalActions.first(where: { $0.kind == .discard }))

        session.apply(discard)

        XCTAssertTrue(session.canUndo)
        XCTAssertNotEqual(session.match.serializeReplay(), checkpoint)
        session.undoLastHumanDecision()
        XCTAssertEqual(session.match.serializeReplay(), checkpoint)
        XCTAssertFalse(session.canUndo)
    }

    @MainActor
    func testStepThroughPacingWaitsForProceedAfterAVisibleAction() throws {
        let previousPreference = GameLearningPreferences.stepThroughEnabled
        defer { GameLearningPreferences.stepThroughEnabled = previousPreference }
        let store = MahjongMatchStore(archiveURL: temporaryArchiveURL())
        let session = GameSession(seed: 7_723, humanSeat: 0, persistence: store)
        session.stepThroughEnabled = true
        let discard = try XCTUnwrap(session.legalActions.first(where: { $0.kind == .discard }))

        session.apply(discard)

        XCTAssertTrue(session.isAwaitingProceed)
        XCTAssertTrue(session.canProceed)
        XCTAssertNotNil(session.stepMessage)
        session.proceedLearningStep()
        XCTAssertFalse(session.isAwaitingProceed)
        XCTAssertNil(session.stepMessage)
    }

    private func temporaryArchiveURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MahjongLearningGameTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("match.json")
    }
}
