import Foundation
import Observation
import UIKit
import SwiftUI
import MahjongCore
import MahjongGameEngine

/// Main-actor bridge from the deterministic match state machine to SwiftUI.
/// Gameplay mutations still happen only through `MatchState`; persistence,
/// teaching, and animation are observers around that authority.
@MainActor @Observable
final class GameSession {
    let humanSeat: Int
    let difficulty: BotDifficulty
    let rules: MatchRulesConfiguration
    let persistence: MahjongMatchStore

    private(set) var match: MatchState
    private(set) var seed: UInt64
    var selectedTileID: Int?
    var isBotThinking = false
    var isInspectorPresented = false {
        didSet { overlayPresentationChanged(from: oldValue, to: isInspectorPresented) }
    }
    var isResultPresented = false
    var isMatchEndPresented = false
    var isTableOptionsPresented = false {
        didSet { overlayPresentationChanged(from: oldValue, to: isTableOptionsPresented) }
    }
    var exitRequested = false {
        didSet { overlayPresentationChanged(from: oldValue, to: exitRequested) }
    }
    var selectedInsight: GameTileInsightContext? {
        didSet { overlayPresentationChanged(from: oldValue != nil, to: selectedInsight != nil) }
    }
    var tileInsightsEnabled: Bool {
        didSet {
            GameLearningPreferences.tileInsightsEnabled = tileInsightsEnabled
            if !tileInsightsEnabled, selectedInsight != nil { selectedInsight = nil }
        }
    }
    var stepThroughEnabled: Bool {
        didSet {
            GameLearningPreferences.stepThroughEnabled = stepThroughEnabled
            if !stepThroughEnabled, isAwaitingProceed {
                isAwaitingProceed = false
                stepMessage = nil
                startIfNeeded()
            }
        }
    }
    var claimTimerSetting: GameClaimTimer {
        didSet {
            GameLearningPreferences.claimTimer = claimTimerSetting
            cancelReactionTask()
            activeReactionSignature = nil
            if !isPaused { beginReactionCountdown(reset: true) }
        }
    }
    var errorMessage: String?
    var latestBotDiagnostic: String?
    var revealOpponents = false
    var instantBots = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private(set) var reactionSecondsRemaining = 0
    private(set) var presentationPhase: GamePresentationPhase = .opening(.assemblingWalls)
    private(set) var presentationDice = [1, 1, 1]
    private(set) var wallBreakStack = 0
    private(set) var openingDealCounts = [0, 0, 0, 0]
    private(set) var activeMotion: GameTableMotion?
    private(set) var debugDraggingTileID: Int?
    private(set) var latestSuggestion: GameDiscardSuggestion?
    private(set) var isSuggesting = false
    private(set) var isAwaitingProceed = false
    private(set) var stepMessage: String?
    private var debugAutoplay = false
    private var pendingTerminalPresentation = false
    private var activeReactionSignature: String?
    private var motionQueue: [GameTableMotion] = []
    private var botTaskGeneration: UInt64 = 0
    private var reactionTaskGeneration: UInt64 = 0
    private var undoCheckpoint: MatchReplayV1?

    @ObservationIgnored private var botTask: Task<Void, Never>?
    @ObservationIgnored private var reactionTask: Task<Void, Never>?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var motionTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTail: Task<Void, Never>?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?

    init(
        seed: UInt64 = UInt64.random(in: 1...UInt64.max),
        humanSeat: Int = 0,
        difficulty: BotDifficulty = .normal,
        persistence: MahjongMatchStore = .shared
    ) {
        self.seed = seed
        self.humanSeat = humanSeat
        self.difficulty = difficulty
        self.persistence = persistence
        tileInsightsEnabled = GameLearningPreferences.tileInsightsEnabled
        stepThroughEnabled = GameLearningPreferences.stepThroughEnabled
        claimTimerSetting = GameLearningPreferences.claimTimer

        let prefs = GameRulesPrefs.snapshot
        let selectedRules = MatchRulesConfiguration(
            minimumFaan: prefs.minimumFaan,
            faanCap: prefs.faanLimit,
            scoreFlowers: prefs.scoreFlowers,
            settlementStyle: prefs.paymentStyle == .halfSpicy ? .halfSpicy : .fullSpicy
        )
        rules = selectedRules
        // The launcher constrains the seat to 0...3 and the settings screen
        // validates rules, so construction cannot fail here.
        let configuration = try! MatchConfiguration(
            seed: seed,
            humanSeat: humanSeat,
            rules: selectedRules,
            botDifficulty: difficulty
        )
        match = try! MatchState(configuration: configuration)
        configureOpeningLayout()
        enqueuePersistence()
        beginOpeningPresentation(full: true)
    }

    /// Strict reconstruction: `MatchState.replay` validates every action,
    /// event, cursor, result, and match-ledger field before the session exists.
    init(replay: MatchReplayV1, persistence: MahjongMatchStore = .shared) throws {
        let rebuilt = try MatchState.replay(replay)
        match = rebuilt
        seed = replay.configuration.seed
        humanSeat = replay.configuration.humanSeat
        difficulty = replay.configuration.botDifficulty
        rules = replay.configuration.rules
        self.persistence = persistence
        tileInsightsEnabled = GameLearningPreferences.tileInsightsEnabled
        stepThroughEnabled = GameLearningPreferences.stepThroughEnabled
        claimTimerSetting = GameLearningPreferences.claimTimer
        presentationPhase = .playing
        configureOpeningLayout()

        if rebuilt.currentHand.isTerminal {
            revealOpponents = true
            if rebuilt.isMatchComplete { isMatchEndPresented = true }
            else { isResultPresented = true }
        } else {
            startIfNeeded()
        }
    }

    deinit {
        botTask?.cancel()
        reactionTask?.cancel()
        presentationTask?.cancel()
        motionTask?.cancel()
        suggestionTask?.cancel()
    }

    var state: GameState { match.currentHand }
    var handNumber: Int { match.handIndex + 1 }
    var isHumanTurn: Bool {
        match.currentActor == humanSeat && !match.isMatchComplete && !state.isTerminal
    }
    var isTerminal: Bool { state.isTerminal }
    var isReaction: Bool { state.phase == .reaction && isHumanTurn }
    var isMatchComplete: Bool { match.isMatchComplete }
    var canAdvance: Bool { match.canAdvanceToNextHand }
    var canSuggest: Bool {
        isHumanTurn && !isReaction && !isPresentationBlocking && !hasOverlayPresented
            && legalActions.contains { $0.kind == .discard }
    }
    var canUndo: Bool {
        undoCheckpoint != nil && !isTerminal && !isReaction && !isPresentationBlocking
            && !hasOverlayPresented
    }
    var canProceed: Bool {
        isAwaitingProceed && activeMotion == nil && !hasOverlayPresented
    }
    var player: GamePlayer { state.players[humanSeat] }
    var legalActions: [GameAction] { match.legalActions(for: humanSeat) }
    var isPresentationBlocking: Bool { presentationPhase != .playing || activeMotion != nil }
    var presentedWallFront: Int {
        switch presentationPhase.openingStage {
        case .assemblingWalls, .rollingDice, .highlightingBreak: 0
        case .dealing: min(state.wallFront, openingDealCounts.reduce(0, +))
        case .revealingHand, nil: state.wallFront
        }
    }
    var presentedWallRear: Int {
        switch presentationPhase.openingStage {
        case .assemblingWalls, .rollingDice, .highlightingBreak, .dealing: 144
        case .revealingHand, nil: state.wallRear
        }
    }
    var reactionTimerSeconds: Int? {
        claimTimerSetting.seconds == nil ? nil : reactionSecondsRemaining
    }
    var humanTiles: [TileInstance] {
        guard let drawn = state.lastDrawInstance, player.concealed.contains(drawn) else {
            return player.concealed.sorted { $0.tile < $1.tile }
        }
        return player.concealed.filter { $0.id != drawn.id }.sorted { $0.tile < $1.tile } + [drawn]
    }
    var totals: [Int] { match.totals }
    var seatStats: [MatchSeatStats] { match.seatStats }
    var standings: [Int] { match.summary.standings }
    var replayText: String {
        guard let data = try? JSONEncoder().encode(match.serializeReplay()) else { return "Replay unavailable" }
        return String(decoding: data, as: UTF8.self)
    }

    func restart(seed newSeed: UInt64? = nil) {
        cancelInteractiveWork()
        cancelPresentationWork()
        seed = newSeed ?? UInt64.random(in: 1...UInt64.max)
        do {
            match = try MatchState(configuration: MatchConfiguration(
                seed: seed,
                humanSeat: humanSeat,
                rules: rules,
                botDifficulty: difficulty
            ))
            selectedTileID = nil
            latestSuggestion = nil
            undoCheckpoint = nil
            isAwaitingProceed = false
            stepMessage = nil
            selectedInsight = nil
            errorMessage = nil
            latestBotDiagnostic = nil
            isResultPresented = false
            isMatchEndPresented = false
            revealOpponents = false
            pendingTerminalPresentation = false
            configureOpeningLayout()
            enqueuePersistence()
            beginOpeningPresentation(full: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func advanceToNextHand() {
        guard canAdvance else { return }
        cancelInteractiveWork()
        cancelPresentationWork()
        do {
            try match.advanceToNextHand()
            selectedTileID = nil
            latestSuggestion = nil
            undoCheckpoint = nil
            isAwaitingProceed = false
            stepMessage = nil
            isResultPresented = false
            revealOpponents = false
            pendingTerminalPresentation = false
            configureOpeningLayout()
            enqueuePersistence()
            beginOpeningPresentation(full: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ tile: TileInstance) {
        guard !isPaused, isHumanTurn, actionForDiscard(tile) != nil else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.16)) {
            selectedTileID = tile.id
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        GameSounds.tileClick()
    }

    func discardSelected() {
        guard let id = selectedTileID,
              let tile = player.concealed.first(where: { $0.id == id }) else { return }
        discard(tile)
    }

    /// Dragging and the Discard button converge here, so duplicate tile faces
    /// receive exactly the same action validation from the engine.
    func discard(_ tile: TileInstance) {
        guard !isPaused, player.concealed.contains(where: { $0.id == tile.id }),
              let action = actionForDiscard(tile) else { return }
        apply(action)
    }

    func apply(_ action: GameAction) {
        guard !isPaused, match.currentActor == humanSeat else { return }
        cancelReactionTask()
        suggestionTask?.cancel()
        suggestionTask = nil
        isSuggesting = false
        let previousEventCount = state.events.count
        let offerBeforeAction = state.offer
        let checkpoint = match.serializeReplay()
        do {
            try match.apply(actionID: action.id)
            undoCheckpoint = checkpoint
            selectedTileID = nil
            latestSuggestion = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if action.kind == .chow || action.kind == .pung || action.kind == .exposedKong {
                GameSounds.claim()
            } else if action.kind == .discard {
                GameSounds.tileMove()
            }
            acceptedMutation(previousEventCount: previousEventCount, offerBeforeAction: offerBeforeAction)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pass() {
        if let action = legalActions.first(where: { label(for: $0) == "Pass" }) { apply(action) }
    }

    /// Highlights the strongest current discard without applying it. Advice is
    /// computed away from the main actor from the same public observation used
    /// by the learning drawer.
    func suggestDiscard() {
        guard canSuggest, !isSuggesting else { return }
        suggestionTask?.cancel()
        let observation = match.observation(for: humanSeat)
        let expectedTurn = state.turn
        let expectedEventCount = state.events.count
        isSuggesting = true

        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let suggestion = await GameLearningAdvisor.suggestedDiscard(observation: observation)
            guard !Task.isCancelled,
                  self.state.turn == expectedTurn,
                  self.state.events.count == expectedEventCount,
                  self.isHumanTurn else { return }
            self.isSuggesting = false
            self.suggestionTask = nil
            self.latestSuggestion = suggestion
            guard let suggestion,
                  let instance = self.humanTiles.first(where: { $0.tile == suggestion.tile }) else { return }
            withAnimation(self.reduceMotion ? nil : .snappy(duration: 0.2)) {
                self.selectedTileID = instance.id
            }
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// Reconstructs the exact state before the last accepted human decision.
    /// Any deterministic bot consequences after that decision disappear with
    /// it, leaving a fresh replay branch rather than mutating engine internals.
    func undoLastHumanDecision() {
        guard canUndo, let checkpoint = undoCheckpoint else { return }
        cancelInteractiveWork()
        cancelPresentationWork()
        do {
            match = try MatchState.replay(checkpoint)
            undoCheckpoint = nil
            selectedTileID = nil
            latestSuggestion = nil
            isAwaitingProceed = false
            stepMessage = nil
            pendingTerminalPresentation = false
            revealOpponents = false
            presentationPhase = .playing
            configureOpeningLayout()
            enqueuePersistence()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            startIfNeeded()
        } catch {
            errorMessage = "Could not undo that decision: \(error.localizedDescription)"
        }
    }

    func proceedLearningStep() {
        guard canProceed else { return }
        isAwaitingProceed = false
        stepMessage = nil
        UISelectionFeedbackGenerator().selectionChanged()
        startIfNeeded()
    }

    func action(named name: String) -> GameAction? {
        legalActions.first { label(for: $0) == name }
    }

    func chowActions() -> [GameAction] {
        legalActions.filter { label(for: $0) == "Chow" }
    }

    func label(for action: GameAction) -> String {
        switch action.kind {
        case .pass: "Pass"
        case .win: "Win"
        case .discard: "Discard"
        case .chow: "Chow"
        case .pung: "Pung"
        case .exposedKong, .concealedKong, .addedKong: "Kong"
        }
    }

    func openTileInsight(tile: Tile, origin: GameTileInsightOrigin) {
        guard tileInsightsEnabled else { return }
        selectedInsight = GameTileInsightContext(
            tile: tile,
            origin: origin,
            observation: match.observation(for: humanSeat)
        )
    }

    func closeTileInsight() {
        selectedInsight = nil
    }

    func requestExit() {
        if isMatchComplete {
            exitRequested = true
            return
        }
        exitRequested = true
    }

    /// Waits for earlier accepted-action saves, then writes the exact latest
    /// replay before the navigation stack dismisses the table.
    func flushForExit() async {
        cancelInteractiveWork()
        presentationTask?.cancel()
        if let pending = persistenceTail { await pending.value }
        if match.isMatchComplete {
            await persistence.clear()
        } else {
            await persistence.save(PersistedMahjongMatchV1(replay: match.serializeReplay()))
        }
    }

    func sceneDidEnterBackground() {
        cancelInteractiveWork()
        Task { [weak self] in await self?.flushCurrentReplay() }
    }

    func sceneDidBecomeActive() {
        guard !isPaused else { return }
        startIfNeeded()
    }

    func skipPresentation() {
        presentationTask?.cancel()
        presentationTask = nil
        openingDealCounts = state.players.map { $0.concealed.count }
        presentationPhase = .playing
        startIfNeeded()
    }

    func observationText() -> String {
        guard let data = try? JSONEncoder().encode(match.observation(for: humanSeat)) else {
            return "Observation unavailable"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Deterministic screenshot setup: plays only legal engine actions through
    /// the same match wrapper, never fabricating a result or ledger entry.
    func prepareDebugPresentation(destination: GameDebugDestination) {
        cancelInteractiveWork()
        cancelPresentationWork()
        presentationPhase = .playing
        instantBots = true
        debugAutoplay = true

        switch destination {
        case .dice:
            presentationPhase = .opening(.rollingDice)
            debugAutoplay = false
            return
        case .dealing:
            openingDealCounts = state.players.map { min($0.concealed.count, 8) }
            presentationPhase = .opening(.dealing)
            debugAutoplay = false
            return
        case .learning:
            if let tile = humanTiles.first?.tile {
                selectedInsight = GameTileInsightContext(
                    tile: tile,
                    origin: .humanHand,
                    observation: match.observation(for: humanSeat)
                )
            }
            debugAutoplay = false
            return
        case .dragging:
            debugDraggingTileID = humanTiles.first?.id
            selectedTileID = debugDraggingTileID
            debugAutoplay = false
            return
        default:
            break
        }

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.debugAutoplay = false
                self.enqueuePersistence()
            }
            var guardCount = 0
            while !Task.isCancelled && guardCount < 30_000 {
                guardCount += 1
                if self.state.isTerminal {
                    if destination == .matchEnd {
                        if self.match.isMatchComplete {
                            self.isMatchEndPresented = true
                            return
                        }
                        self.advanceToNextHandForDebug()
                        await Task.yield()
                        continue
                    }
                    if destination.isClaimScene || destination == .replacementDraw {
                        guard !self.match.isMatchComplete else { return }
                        self.advanceToNextHandForDebug()
                        await Task.yield()
                        continue
                    }
                    self.isResultPresented = true
                    return
                }
                guard let actor = self.match.currentActor,
                      let action = self.debugAction(for: actor) else { return }
                if actor == self.humanSeat, self.state.phase == .reaction {
                    let legal = self.match.legalActions(for: actor)
                    if destination.matchesReaction(legalActions: legal, offer: self.state.offer) { return }
                }
                let previousEventCount = self.state.events.count
                let offerBeforeAction = self.state.offer
                do {
                    try self.match.apply(actionID: action.id)
                } catch {
                    self.errorMessage = error.localizedDescription
                    return
                }
                if destination == .replacementDraw,
                   let replacement = self.state.events.dropFirst(previousEventCount).first(where: {
                       $0.kind == .draw && $0.drawKind != .ordinary
                   }) {
                    self.activeMotion = GameTableMotion(event: replacement, offerBeforeAction: offerBeforeAction)
                    return
                }
                await Task.yield()
            }
        }
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    private var hasOverlayPresented: Bool {
        selectedInsight != nil || isTableOptionsPresented || isInspectorPresented || exitRequested
    }
    private var isPaused: Bool {
        debugAutoplay || hasOverlayPresented || isPresentationBlocking || isResultPresented
            || isMatchEndPresented || isAwaitingProceed
    }

    private func actionForDiscard(_ tile: TileInstance) -> GameAction? {
        legalActions.first { $0.kind == .discard && $0.tile == tile.tile }
    }

    private func acceptedMutation(previousEventCount: Int, offerBeforeAction: PendingOffer?) {
        activeReactionSignature = nil
        reactionSecondsRemaining = 0
        let acceptedEvents = Array(state.events.dropFirst(previousEventCount))
        if stepThroughEnabled, !state.isTerminal,
           let teachingEvent = acceptedEvents.last(where: { $0.kind != .pass && $0.kind != .deal }) {
            isAwaitingProceed = true
            stepMessage = learningStepMessage(for: teachingEvent)
        }
        enqueuePersistence()
        enqueueMotions(
            for: acceptedEvents,
            offerBeforeAction: offerBeforeAction
        )

        if state.isTerminal {
            revealOpponents = true
            pendingTerminalPresentation = true
            if state.terminal?.winner != nil { GameSounds.win() }
            presentTerminalIfReady()
        } else if activeMotion == nil, motionQueue.isEmpty {
            startIfNeeded()
        }
    }

    private func presentTerminalIfReady() {
        guard pendingTerminalPresentation, activeMotion == nil, motionQueue.isEmpty else { return }
        pendingTerminalPresentation = false
        if match.isMatchComplete {
            isMatchEndPresented = true
            enqueuePersistence() // Completion clears the one saved match.
        } else {
            isResultPresented = true
        }
    }

    private func startIfNeeded() {
        guard !isPaused, !isMatchComplete, !state.isTerminal,
              let actor = match.currentActor else { return }

        if actor == humanSeat {
            if state.phase == .reaction { beginReactionCountdown(reset: false) }
            return
        }
        guard botTask == nil else { return }

        let expectedTurn = state.turn
        let expectedEventCount = state.events.count
        let observation = match.observation(for: actor)
        let mask = match.legalMask(for: actor)
        let fallbackActionID = mask.firstIndex(of: true)
        let difficulty = self.difficulty
        let decisionSeed = seed

        botTaskGeneration &+= 1
        let generation = botTaskGeneration
        botTask = Task { [weak self] in
            guard let self else { return }
            self.isBotThinking = true
            defer {
                if self.botTaskGeneration == generation {
                    self.isBotThinking = false
                    self.botTask = nil
                    self.startIfNeeded()
                }
            }

            let decision: PolicyDecision
            do {
                decision = try await Task.detached(priority: .userInitiated) {
                    try await DifficultyMahjongPolicy(difficulty: difficulty, seed: decisionSeed)
                        .decision(for: observation, legalMask: mask)
                }.value
            } catch {
                guard !Task.isCancelled, let fallbackActionID else { return }
                decision = PolicyDecision(
                    actionID: fallbackActionID,
                    diagnostics: "policy error; deterministic legal fallback \(fallbackActionID)"
                )
            }

            guard !Task.isCancelled, self.botTaskGeneration == generation else { return }
            if !self.instantBots { try? await Task.sleep(for: .milliseconds(420)) }
            guard !Task.isCancelled, self.botTaskGeneration == generation, !self.isPaused,
                  self.match.currentActor == actor,
                  self.state.turn == expectedTurn,
                  self.state.events.count == expectedEventCount else { return }

            guard let actionID = mask.indices.contains(decision.actionID) && mask[decision.actionID]
                ? decision.actionID
                : fallbackActionID else {
                self.errorMessage = "Bot policy returned no legal action."
                return
            }

            let previousEventCount = self.state.events.count
            let offerBeforeAction = self.state.offer
            do {
                try self.match.apply(actionID: actionID)
                self.latestBotDiagnostic = decision.diagnostics
                    ?? "\(self.difficulty.rawValue.capitalized) placeholder selected action \(actionID)"
                self.selectedTileID = nil
                self.acceptedMutation(
                    previousEventCount: previousEventCount,
                    offerBeforeAction: offerBeforeAction
                )
            } catch {
                self.errorMessage = "The game rejected bot action \(actionID): \(error.localizedDescription)"
            }
        }
    }

    private func beginReactionCountdown(reset: Bool) {
        guard isReaction, !isPaused, let seconds = claimTimerSetting.seconds else {
            cancelReactionTask()
            if claimTimerSetting == .off { reactionSecondsRemaining = 0 }
            return
        }

        let signature = reactionSignature
        if reset || activeReactionSignature != signature || reactionSecondsRemaining <= 0 {
            reactionSecondsRemaining = seconds
        }
        activeReactionSignature = signature
        guard reactionTask == nil else { return }

        reactionTaskGeneration &+= 1
        let generation = reactionTaskGeneration
        reactionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.reactionTaskGeneration == generation { self.reactionTask = nil }
            }
            while !Task.isCancelled, self.reactionTaskGeneration == generation,
                  self.isReaction, self.reactionSecondsRemaining > 0 {
                if !self.instantBots { try? await Task.sleep(for: .seconds(1)) }
                else { await Task.yield() }
                guard !Task.isCancelled, self.reactionTaskGeneration == generation,
                      self.isReaction, !self.hasOverlayPresented else { return }
                self.reactionSecondsRemaining -= 1
            }
            if !Task.isCancelled, self.reactionTaskGeneration == generation,
               self.isReaction, self.reactionSecondsRemaining == 0 {
                self.pass()
            }
        }
    }

    private var reactionSignature: String {
        guard let offer = state.offer else { return "none-\(state.turn)" }
        return "\(state.turn)-\(offer.fromSeat)-\(offer.tile.classIndex)-\(offer.isRobKong)"
    }

    private func overlayPresentationChanged(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else { return }
        if newValue {
            cancelInteractiveWork(preserveReactionTimer: true)
        } else if !hasOverlayPresented {
            startIfNeeded()
        }
    }

    private func cancelInteractiveWork(preserveReactionTimer: Bool = false) {
        botTaskGeneration &+= 1
        botTask?.cancel()
        botTask = nil
        isBotThinking = false
        suggestionTask?.cancel()
        suggestionTask = nil
        isSuggesting = false
        cancelReactionTask()
        if !preserveReactionTimer {
            activeReactionSignature = nil
            reactionSecondsRemaining = 0
        }
    }

    private func cancelReactionTask() {
        reactionTaskGeneration &+= 1
        reactionTask?.cancel()
        reactionTask = nil
    }

    private func configureOpeningLayout() {
        let layout = GameOpeningLayout(handSeed: state.seed, dealer: state.dealer)
        presentationDice = layout.dice
        wallBreakStack = layout.wallBreakStack
        openingDealCounts = [0, 0, 0, 0]
    }

    private func beginOpeningPresentation(full: Bool) {
        cancelInteractiveWork()
        presentationTask?.cancel()
        presentationPhase = .opening(.assemblingWalls)

        if instantBots {
            skipPresentation()
            return
        }

        let reduce = reduceMotion
        presentationTask = Task { [weak self] in
            guard let self else { return }
            let stageScale = reduce ? 0.15 : (full ? 1.0 : 0.25)

            guard await self.openingPause(milliseconds: Int(700 * stageScale)) else { return }
            self.presentationPhase = .opening(.rollingDice)
            GameSounds.dice()

            guard await self.openingPause(milliseconds: Int(1_100 * stageScale)) else { return }
            self.presentationPhase = .opening(.highlightingBreak)

            guard await self.openingPause(milliseconds: Int(650 * stageScale)) else { return }
            self.presentationPhase = .opening(.dealing)
            GameSounds.tileMove()

            let targetCounts = self.state.players.map { $0.concealed.count }
            let bursts = full ? [4, 8, 12, 13, 14] : [8, 13, 14]
            for burst in bursts {
                self.openingDealCounts = targetCounts.map { min($0, burst) }
                guard await self.openingPause(milliseconds: Int((full ? 480.0 : 210.0) * (reduce ? 0.35 : 1))) else { return }
            }
            self.openingDealCounts = targetCounts
            self.presentationPhase = .opening(.revealingHand)

            guard await self.openingPause(milliseconds: Int(650 * stageScale)) else { return }
            self.presentationPhase = .playing
            self.presentationTask = nil
            self.startIfNeeded()
        }
    }

    private func openingPause(milliseconds: Int) async -> Bool {
        if milliseconds > 0 { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        return !Task.isCancelled
    }

    private func cancelPresentationWork() {
        presentationTask?.cancel()
        presentationTask = nil
        motionTask?.cancel()
        motionTask = nil
        motionQueue.removeAll()
        activeMotion = nil
    }

    private func enqueueMotions(for events: [GameEventV2], offerBeforeAction: PendingOffer?) {
        let visualEvents = events.filter { $0.kind != .pass && $0.kind != .deal }
        guard !reduceMotion, !instantBots, !visualEvents.isEmpty else {
            activeMotion = nil
            motionQueue.removeAll()
            return
        }
        motionQueue.append(contentsOf: visualEvents.map {
            GameTableMotion(event: $0, offerBeforeAction: offerBeforeAction)
        })
        playNextMotionIfNeeded()
    }

    private func playNextMotionIfNeeded() {
        guard activeMotion == nil else { return }
        guard !motionQueue.isEmpty else {
            presentTerminalIfReady()
            guard !isAwaitingProceed else { return }
            startIfNeeded()
            return
        }
        activeMotion = motionQueue.removeFirst()
        motionTask?.cancel()
        motionTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.activeMotion = nil
            self.motionTask = nil
            self.playNextMotionIfNeeded()
        }
    }

    private func enqueuePersistence() {
        let snapshot = match.serializeReplay()
        let store = persistence
        let previous = persistenceTail
        persistenceTail = Task {
            if let previous { await previous.value }
            if snapshot.isMatchComplete { await store.clear() }
            else { await store.save(PersistedMahjongMatchV1(replay: snapshot)) }
        }
    }

    private func flushCurrentReplay() async {
        if let pending = persistenceTail { await pending.value }
        let snapshot = match.serializeReplay()
        if snapshot.isMatchComplete { await persistence.clear() }
        else { await persistence.save(PersistedMahjongMatchV1(replay: snapshot)) }
    }

    private func advanceToNextHandForDebug() {
        guard canAdvance else { return }
        do {
            try match.advanceToNextHand()
            selectedTileID = nil
            isResultPresented = false
            revealOpponents = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func learningStepMessage(for event: GameEventV2) -> String {
        let actor = windNameForLearning(state.players[event.seat].seatWind)
        switch event.kind {
        case .draw:
            return event.drawKind == .ordinary ? "\(actor) drew from the wall." : "\(actor) took a replacement tile from the rear wall."
        case .flower: return "\(actor) revealed a bonus tile."
        case .discard: return event.tile.map { "\(actor) discarded \($0.code)." } ?? "\(actor) discarded."
        case .chow: return "\(actor) formed a Chow."
        case .pung: return "\(actor) formed a Pung."
        case .kong, .addedKong, .concealedKong: return "\(actor) declared a Kong."
        case .win: return "\(actor) completed the hand."
        case .exhaustive: return "The live wall is exhausted."
        case .deal: return "The tiles were dealt."
        case .pass: return "\(actor) passed."
        }
    }

    /// Fast deterministic screenshot autoplay. It mirrors the placeholder bot's
    /// priorities without asking CoachAdvisor thousands of times.
    private func debugAction(for actor: Int) -> GameAction? {
        let actions = match.legalActions(for: actor)
        if let win = actions.first(where: { $0.kind == .win }) { return win }
        if state.phase == .reaction {
            return actions.first(where: { $0.kind == .exposedKong })
                ?? actions.first(where: { $0.kind == .pung })
                ?? actions.first(where: { $0.kind == .chow })
                ?? actions.first(where: { $0.kind == .pass })
        }
        if let kong = actions.first(where: { $0.kind == .concealedKong || $0.kind == .addedKong }) {
            return kong
        }
        let counts = match.observation(for: actor).concealed
        return actions.filter { $0.kind == .discard }.min { left, right in
            debugDiscardValue(left.tile, counts: counts) < debugDiscardValue(right.tile, counts: counts)
        } ?? actions.first
    }

    private func debugDiscardValue(_ tile: Tile?, counts: [Int]) -> Int {
        guard let tile else { return .max }
        var value = (tile.isHonor ? -8 : 0) + (tile.isTerminal ? -5 : 0)
        value += counts[tile.classIndex] * 8
        if let rank = tile.rank, let suit = tile.suit {
            for neighbour in [rank - 2, rank - 1, rank + 1, rank + 2] where (1...9).contains(neighbour) {
                value += counts[Tile.suited(suit, neighbour).classIndex] * 3
            }
        }
        return value
    }
}

private func windNameForLearning(_ wind: Wind) -> String {
    ["East", "South", "West", "North"][wind.rawValue]
}
