import Foundation
import Observation
import UIKit
import SwiftUI
import MahjongCore
import MahjongGameEngine

/// UI-owned coordination around the deterministic game engine.  The engine is
/// deliberately the authority for legality; this object never edits a hand.
@MainActor @Observable
final class GameSession {
    let humanSeat: Int
    private(set) var state: GameState
    private(set) var seed: UInt64
    var selectedTileID: Int?
    var isBotThinking = false
    var isInspectorPresented = false
    var isResultPresented = false
    var errorMessage: String?
    var latestBotDiagnostic: String?
    var revealOpponents = false
    var instantBots = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @ObservationIgnored private var botTask: Task<Void, Never>?

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max), humanSeat: Int = 0) {
        self.seed = seed
        self.humanSeat = humanSeat
        // A failed deterministic setup is a programmer/data failure; retain a safe
        // empty seed fallback for the UI instead of crashing a debug launcher.
        self.state = try! GameState.newGame(seed: seed, dealer: humanSeat)
        startIfNeeded()
    }

    deinit { botTask?.cancel() }

    var isHumanTurn: Bool { state.currentActor == humanSeat && state.phase != .terminal }
    var isTerminal: Bool { state.phase == .terminal }
    var player: GamePlayer { state.players[humanSeat] }
    var legalActions: [GameAction] { state.legalActions(for: humanSeat) }
    var humanTiles: [TileInstance] { player.concealed.sorted { $0.tile < $1.tile } }
    var replayText: String {
        guard let data = try? JSONEncoder().encode(state.serializeReplay()) else { return "Replay unavailable" }
        return String(decoding: data, as: UTF8.self)
    }

    func restart(seed newSeed: UInt64? = nil) {
        botTask?.cancel()
        seed = newSeed ?? UInt64.random(in: 1...UInt64.max)
        do {
            state = try GameState.newGame(seed: seed, dealer: humanSeat)
            selectedTileID = nil
            errorMessage = nil
            latestBotDiagnostic = nil
            isResultPresented = false
            startIfNeeded()
        } catch { errorMessage = error.localizedDescription }
    }

    func select(_ tile: TileInstance) {
        guard isHumanTurn, actionForDiscard(tile) != nil else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.16)) { selectedTileID = tile.id }
        selectionFeedback()
    }

    func discardSelected() {
        guard let id = selectedTileID,
              let tile = player.concealed.first(where: { $0.id == id }),
              let action = actionForDiscard(tile) else { return }
        apply(action)
    }

    func apply(_ action: GameAction) {
        guard state.currentActor == humanSeat else { return }
        do {
            try state.apply(actionID: action.id)
            selectedTileID = nil
            successFeedback()
            afterMutation()
        } catch { errorMessage = error.localizedDescription }
    }

    func pass() {
        guard let action = legalActions.first(where: { label(for: $0) == "Pass" }) else { return }
        apply(action)
    }

    func action(named name: String) -> GameAction? {
        legalActions.first { label(for: $0) == name }
    }

    func chowActions() -> [GameAction] { legalActions.filter { label(for: $0) == "Chow" } }

    func label(for action: GameAction) -> String {
        switch String(describing: action.kind) {
        case "pass": return "Pass"
        case "win": return "Win"
        case "discard": return "Discard"
        case "chow": return "Chow"
        case "pung": return "Pung"
        case "exposedKong", "concealedKong", "addedKong": return "Kong"
        default: return String(describing: action.kind).capitalized
        }
    }

    func observationText() -> String {
        let observation = state.observation(for: humanSeat)
        guard let data = try? JSONEncoder().encode(observation) else { return "Observation unavailable" }
        return String(decoding: data, as: UTF8.self)
    }

    private var reduceMotion: Bool {
        // The environment value is read by views. This safe default keeps async
        // state changes functional when a session is driven by UI tests.
        UIAccessibility.isReduceMotionEnabled
    }

    private func actionForDiscard(_ tile: TileInstance) -> GameAction? {
        legalActions.first { action in
            label(for: action) == "Discard" && action.tile == tile.tile
        }
    }

    private func afterMutation() {
        if state.phase == .terminal {
            isResultPresented = true
            return
        }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !isTerminal, state.currentActor != humanSeat, state.currentActor != nil, botTask == nil else { return }
        botTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.isTerminal, self.state.currentActor != self.humanSeat {
                self.isBotThinking = true
                guard let actor = self.state.currentActor else { break }
                let observation = self.state.observation(for: actor)
                let mask = self.state.legalMask(for: actor)
                let policy = HeuristicMahjongPolicy()
                do {
                    let decision = try await policy.decision(for: observation, legalMask: mask)
                    guard !Task.isCancelled else { break }
                    if !self.instantBots { try? await Task.sleep(for: .milliseconds(420)) }
                    try self.state.apply(actionID: decision.actionID)
                    self.latestBotDiagnostic = decision.diagnostics ?? "Heuristic policy selected action \(decision.actionID)"
                    self.selectedTileID = nil
                    if self.state.phase == .terminal { self.isResultPresented = true; break }
                } catch {
                    self.errorMessage = "Bot decision failed: \(error.localizedDescription)"
                    break
                }
            }
            self.isBotThinking = false
            self.botTask = nil
        }
    }

    private func selectionFeedback() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    private func successFeedback() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
