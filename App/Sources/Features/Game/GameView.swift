import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData
import MahjongGameEngine

/// The table deliberately renders from the public game state.  It never moves a
/// tile between zones itself: every choice is returned to `GameSession`, which
/// remains the only bridge to the deterministic engine.
struct GameView: View {
    @State var session: GameSession
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var chowSheet = false
    @State private var forceInspector = false
    @State private var humanRiverFrame = CGRect.zero
    @State private var motionAnchors: [GameMotionAnchor: CGRect] = [:]
    @State private var isDraggingOverRiver = false
    @State private var showCoachMark = !GameLearningPreferences.hasShownTileCoachMark
    private let debugDestination: GameDebugDestination?

    init(session: GameSession, forceInspector: Bool = false, debugDestination: GameDebugDestination? = nil) {
        _session = State(initialValue: session)
        _forceInspector = State(initialValue: forceInspector)
        self.debugDestination = debugDestination
    }

    var body: some View {
        @Bindable var session = session
        ZStack {
            ScreenBackground(.live)
            GeometryReader { proxy in
                let layout = GameLayoutProfile(size: proxy.size)
                VStack(spacing: layout.spacing) {
                    gameHeader(compact: layout.isPhone)
                    MahjongLearningTable(
                        session: session,
                        compact: layout.isPhone,
                        isDraggingOverHumanRiver: isDraggingOverRiver || session.debugDraggingTileID != nil,
                        inspect: inspect
                    )
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: layout.minimumTableHeight)
                    .allowsHitTesting(!session.isPresentationBlocking)
                    HumanRack(
                        session: session,
                        compact: layout.isPhone,
                        maximumTileWidth: layout.humanTileWidth,
                        riverDropFrame: humanRiverFrame,
                        isDraggingOverRiver: $isDraggingOverRiver,
                        inspect: inspect
                    )
                    .reportsGameMotionAnchor(.rack(session.humanSeat))
                    .allowsHitTesting(!session.isPresentationBlocking)
                    if session.isReaction, session.shouldUseInlineReaction, let offer = session.state.offer {
                        InlineClaimBar(
                            offer: offer,
                            sourceName: gamePlayerName(seat: offer.fromSeat, humanSeat: session.humanSeat),
                            actions: session.legalActions,
                            label: session.label(for:),
                            seconds: session.reactionTimerSeconds,
                            compact: layout.isPhone,
                            onAction: session.apply,
                            onPass: session.pass,
                            inspect: { inspect(offer.tile, .offered(ownerSeat: offer.fromSeat, isRobKong: false)) }
                        )
                    }
                    actionDock(compact: layout.isPhone)
                        .allowsHitTesting(!session.isPresentationBlocking)
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.vertical, layout.verticalPadding)
            }

            if session.isReaction && !session.shouldUseInlineReaction { reactionOverlay }
            if let motion = session.activeMotion {
                TableMotionCue(
                    motion: motion,
                    humanSeat: session.humanSeat,
                    anchors: motionAnchors,
                    reduceMotion: reduceMotion
                )
            }
            if let announcement = session.attention.announcement {
                GameTableAnnouncementView(announcement: announcement, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
            if session.presentationPhase.openingStage != nil { openingPresentation }
            if showCoachMark && session.tileInsightsEnabled && !voiceOverEnabled && session.presentationPhase == .playing && !session.isReaction { insightCoachMark }
        }
        .coordinateSpace(name: "mahjong-game-root")
        .onPreferenceChange(HumanRiverFramePreference.self) { humanRiverFrame = $0 }
        .onPreferenceChange(GameMotionAnchorPreference.self) { motionAnchors = $0 }
        .navigationTitle("Practice table")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Exit") {
                    if session.isMatchComplete { dismiss() }
                    else { session.requestExit() }
                }
                    .frame(minHeight: 44)
                    .accessibilityHint("Saves this unfinished match, then returns to the launcher")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { session.isTableOptionsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Table options")
                Button { session.isInspectorPresented = true } label: { Image(systemName: "wrench.and.screwdriver") }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Open game developer inspector")
            }
        }
        .sheet(isPresented: $session.isTableOptionsPresented) {
            GameTableOptionsView(
                tileInsightsEnabled: $session.tileInsightsEnabled,
                stepThroughEnabled: $session.stepThroughEnabled,
                claimTimer: $session.claimTimerSetting,
                highlightNewestDiscard: $session.highlightNewestDiscard,
                coachHintsEnabled: $session.coachHintsEnabled
            )
        }
        .sheet(item: $session.selectedInsight, onDismiss: { session.closeTileInsight() }) { context in
            GameTileLearningSheet(context: context)
        }
        .sheet(isPresented: $session.isInspectorPresented) { GameInspectorView(session: session) }
        .sheet(isPresented: $chowSheet) { ChowChoiceSheet(actions: session.chowActions(), session: session) }
        .sheet(isPresented: $session.isResultPresented) { GameResultSheet(session: session) }
        .sheet(isPresented: $session.isMatchEndPresented) { MatchEndSheet(session: session) }
        .confirmationDialog("Leave this match?", isPresented: $session.exitRequested, titleVisibility: .visible) {
            if !session.isMatchComplete {
                Button("Save & Exit") {
                    Task { await session.flushForExit(); dismiss() }
                }
            } else {
                Button("Exit") { dismiss() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(session.isMatchComplete ? "This match is complete." : "Your current match will be saved so you can resume it from the launcher.")
        }
        .alert("Game error", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .onAppear {
            if forceInspector { session.isInspectorPresented = true }
            if let debugDestination { session.prepareDebugPresentation(destination: debugDestination) }
        }
        .onChange(of: reduceMotion) { _, value in session.instantBots = value || session.instantBots }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: session.sceneDidEnterBackground()
            case .active: session.sceneDidBecomeActive()
            default: break
            }
        }
        .environment(\.tileTheme, (app.tileTheme ?? .ivory).theme)
    }

    private func inspect(_ tile: Tile, _ origin: GameTileInsightOrigin) {
        guard session.tileInsightsEnabled else { return }
        session.openTileInsight(tile: tile, origin: origin)
        if showCoachMark {
            showCoachMark = false
            GameLearningPreferences.hasShownTileCoachMark = true
        }
    }

    private func gameHeader(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 10) {
                Text("\(windName(session.match.prevailingWind)) ROUND · HAND \(session.handNumber) · 連\(session.match.dealerRepeatCount)")
                    .font(compact ? .caption2.weight(.bold) : MJFont.eyebrow)
                    .tracking(compact ? 0.7 : 1.1).foregroundStyle(MJColor.gold(0.86))
                Spacer()
                HStack(spacing: 7) {
                    Text("WALL").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(MJColor.gold(0.82))
                    Text("\(session.state.wallRemaining)")
                        .font(compact ? .title3.weight(.bold) : .title2.weight(.bold))
                        .foregroundStyle(MJColor.creamHeading)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(session.isHumanTurn && session.state.lastDrawInstance != nil ? GameCueColor.wallDraw : MJColor.gold)
                    .frame(width: 7, height: 7)
                Text(session.tableStatusText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MJColor.creamHeading)
                    .lineLimit(compact ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let hint = session.coachHintText {
                HStack(spacing: 7) {
                    Image(systemName: "lightbulb.max.fill")
                        .foregroundStyle(MJColor.gold)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(MJColor.cream(0.68))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button {
                        session.coachHintsEnabled = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MJColor.cream(0.62))
                    .accessibilityLabel("Hide coach hints")
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 13).padding(.vertical, compact ? 6 : 7)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MJColor.gold(0.16)) }
        .accessibilityElement(children: .combine)
    }

    private func actionDock(compact: Bool) -> some View {
        TableDecisionDock(
            prompt: decisionPrompt,
            compact: compact,
            isSuggesting: session.isSuggesting,
            canSuggest: session.canSuggest,
            canDiscard: session.selectedTileID != nil && session.isHumanTurn && !session.isReaction,
            canUndo: session.canUndo,
            canProceed: session.canProceed,
            suggest: session.suggestDiscard,
            discard: session.discardSelected,
            undo: session.undoLastHumanDecision,
            proceed: session.proceedLearningStep
        )
    }

    private var decisionPrompt: String {
        if let step = session.stepMessage { return step }
        if let suggestion = session.latestSuggestion {
            return "Suggested: \(tileVoiceOverName(suggestion.tile).capitalized) · \(suggestion.shanten) shanten · \(suggestion.outs) live outs"
        }
        if let id = session.selectedTileID,
           let selected = session.player.concealed.first(where: { $0.id == id }) {
            return "Selected: \(MahjongData.name(for: selected.tile).english)"
        }
        return ""
    }

    private var reactionOverlay: some View {
        Group {
            if let offer = session.state.offer {
                ReactionOverlay(
                    offer: offer,
                    sourceName: gamePlayerName(seat: offer.fromSeat, humanSeat: session.humanSeat),
                    actions: session.legalActions,
                    label: session.label(for:),
                    seconds: session.reactionTimerSeconds,
                    onAction: { action in
                        if action.kind == .chow, session.chowActions().count > 1 { chowSheet = true }
                        else { session.apply(action) }
                    },
                    onPass: session.pass,
                    inspect: { inspect(offer.tile, .offered(ownerSeat: offer.fromSeat, isRobKong: offer.isRobKong)) }
                )
                .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
    }

    private var insightCoachMark: some View {
        VStack {
            Spacer()
            Text("Hold hand tiles, or tap face-up tiles, to learn.")
                .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 340)
                .padding(.horizontal, 18)
                .padding(.bottom, 220)
                .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
    }

    private var openingPresentation: some View {
        OpeningPresentationOverlay(
            phase: session.presentationPhase,
            dice: session.presentationDice,
            breakStack: session.wallBreakStack,
            dealCounts: session.openingDealCounts,
            reduceMotion: reduceMotion,
            skip: session.skipPresentation
        )
    }
}

enum GameDebugDestination: Equatable {
    case humanTurn
    case opponentTurn
    case newestDiscard
    case postClaimDiscard
    case reaction
    case result
    case scoreboard
    case matchEnd
    case learning
    case dice
    case dealing
    case dragging
    case claimWin
    case claimPung
    case claimKong
    case claimChow
    case robKong
    case replacementDraw

    var isClaimScene: Bool {
        switch self {
        case .reaction, .claimWin, .claimPung, .claimKong, .claimChow, .robKong, .postClaimDiscard: true
        default: false
        }
    }

    func matchesReaction(legalActions: [GameAction], offer: PendingOffer?) -> Bool {
        switch self {
        case .reaction: true
        case .claimWin: legalActions.contains { $0.kind == .win } && offer?.isRobKong == false
        case .claimPung: legalActions.contains { $0.kind == .pung }
        case .claimKong: legalActions.contains { $0.kind == .exposedKong }
        case .claimChow: legalActions.contains { $0.kind == .chow }
        case .robKong: legalActions.contains { $0.kind == .win } && offer?.isRobKong == true
        default: false
        }
    }
}

private struct MahjongLearningTable: View {
    let session: GameSession
    let compact: Bool
    let isDraggingOverHumanRiver: Bool
    let inspect: (Tile, GameTileInsightOrigin) -> Void

    var body: some View {
        GeometryReader { geo in
            let metrics = GameTableMetrics(size: geo.size, compact: compact)
            ZStack {
                tableFelt
                if let actor = session.displayedActor, actor != session.humanSeat {
                    ActiveSeatSpotlight(
                        seat: actor,
                        humanSeat: session.humanSeat,
                        metrics: metrics
                    )
                }
                PhysicalWall(
                    front: session.presentedWallFront,
                    rear: session.presentedWallRear,
                    size: geo.size,
                    horizontalInset: metrics.horizontalWallInset,
                    verticalInset: metrics.verticalWallInset,
                    stackWidth: metrics.wallStackWidth,
                    breakStack: session.wallBreakStack
                )
                playerZone(seat: (session.humanSeat + 2) % 4, position: metrics.topRackPoint, orientation: .top, metrics: metrics)
                playerZone(seat: (session.humanSeat + 3) % 4, position: metrics.leftRackPoint, orientation: .left, metrics: metrics)
                playerZone(seat: (session.humanSeat + 1) % 4, position: metrics.rightRackPoint, orientation: .right, metrics: metrics)

                spatialRiver(seat: (session.humanSeat + 2) % 4, position: metrics.topRiverPoint, metrics: metrics, rotation: 180)
                spatialRiver(seat: (session.humanSeat + 3) % 4, position: metrics.leftRiverPoint, metrics: metrics, rotation: 90)
                spatialRiver(seat: (session.humanSeat + 1) % 4, position: metrics.rightRiverPoint, metrics: metrics, rotation: -90)
                spatialRiver(seat: session.humanSeat, position: metrics.humanRiverPoint, metrics: metrics, isHuman: true, rotation: 0)

                TableRoundCompass(
                    round: session.match.prevailingWind,
                    dealer: session.state.dealer,
                    actor: session.displayedActor,
                    humanSeat: session.humanSeat,
                    compact: compact
                )
                .position(metrics.centerPoint)
                .zIndex(3)

                PlayerMeldAndFlowerTray(
                    player: session.player,
                    width: metrics.meldTileWidth,
                    highlightedInstanceID: session.attention.lastClaimedInstanceID,
                    inspect: inspect
                )
                    .reportsGameMotionAnchor(.meld(session.humanSeat))
                    .position(metrics.humanTrayPoint)
                PlayerBadge(name: "You", player: session.player, total: session.totals[session.humanSeat], active: session.displayedActor == session.humanSeat)
                    .position(metrics.humanBadgePoint)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mahjong table. \(session.state.wallRemaining) tiles remain in the wall.")
    }

    @ViewBuilder
    private var tableFelt: some View {
        FeltTableSurface(cornerRadius: compact ? 22 : 30)
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 22 : 30, style: .continuous)
                    .strokeBorder(MJColor.gold(0.42), lineWidth: 1.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 18 : 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.035), lineWidth: 1)
                    .padding(5)
            }
            .shadow(color: .black.opacity(0.38), radius: 16, y: 8)
    }

    @ViewBuilder
    private func playerZone(seat: Int, position: CGPoint, orientation: RackOrientation, metrics: GameTableMetrics) -> some View {
        let player = session.state.players[seat]
        if orientation == .top {
            VStack(spacing: 3) {
                PlayerBadge(name: gamePlayerName(seat: seat, humanSeat: session.humanSeat), player: player, total: session.totals[seat], active: session.displayedActor == seat)
                OpponentRack(vertical: false, reveal: session.revealOpponents, tiles: player.concealed, width: metrics.opponentTileWidth, availableLength: metrics.topRackLength, faceRotation: 180)
                    .reportsGameMotionAnchor(.rack(seat))
                PlayerMeldAndFlowerTray(
                    player: player,
                    width: metrics.meldTileWidth,
                    highlightedInstanceID: session.attention.lastClaimedInstanceID,
                    inspect: inspect
                )
                    .reportsGameMotionAnchor(.meld(seat))
            }
            .position(position)
        } else {
            ZStack {
                OpponentRack(vertical: true, reveal: session.revealOpponents, tiles: player.concealed, width: metrics.opponentTileWidth, availableLength: metrics.sideRackLength, faceRotation: orientation == .left ? 90 : -90)
                    .reportsGameMotionAnchor(.rack(seat))
                SidePlayerBadge(
                    name: gamePlayerName(seat: seat, humanSeat: session.humanSeat),
                    player: player,
                    total: session.totals[seat],
                    active: session.displayedActor == seat
                )
                .offset(x: orientation == .left ? -(metrics.opponentTileWidth + 17) : metrics.opponentTileWidth + 17)

                PlayerMeldAndFlowerTray(
                    player: player,
                    width: metrics.sideMeldTileWidth,
                    vertical: true,
                    highlightedInstanceID: session.attention.lastClaimedInstanceID,
                    inspect: inspect
                )
                    .reportsGameMotionAnchor(.meld(seat))
                    .offset(x: orientation == .left ? metrics.opponentTileWidth + 14 : -(metrics.opponentTileWidth + 14))
            }
            .position(position)
        }
    }

    private func spatialRiver(
        seat: Int,
        position: CGPoint,
        metrics: GameTableMetrics,
        isHuman: Bool = false,
        rotation: Double
    ) -> some View {
        let river = session.state.river[seat]
        return RiverGrid(
            seat: seat,
            wind: session.state.players[seat].seatWind,
            tiles: river,
            tileWidth: metrics.riverTileWidth,
            isHuman: isHuman,
            isDropTarget: isHuman && isDraggingOverHumanRiver,
            newestDiscardID: session.highlightNewestDiscard ? session.attention.lastDiscardInstanceID : nil,
            inspect: inspect
        )
        .frame(width: metrics.riverWidth)
        .rotationEffect(.degrees(rotation))
        .position(position)
        .reportsGameMotionAnchor(.river(seat))
    }
}

/// Real photographic felt used only as table decoration. The cleaned square
/// source is aspect-filled so its fibers keep their natural proportions while
/// the code-drawn ornament remains sharp at every table size.
private struct FeltTableSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(hex: 0x073F2F))
            .overlay { PhotographicFeltTexture() }
            .overlay { FeltMahjongOrnament() }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct PhotographicFeltTexture: View {
    var body: some View {
        GeometryReader { proxy in
            Image("MahjongFeltTexture")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.02), .clear, .black.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Responsive gold inlay inspired by traditional mahjong table surrounds.
/// It is drawn as decoration so it never enters the accessibility hierarchy
/// and stays sharp instead of stretching at different aspect ratios.
private struct FeltMahjongOrnament: View {
    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            let shortSide = min(size.width, size.height)
            let edgeInset = max(9, shortSide * 0.025)
            let bandDepth = min(15, max(9, shortSide * 0.035))
            let requestedUnit = min(27, max(15, shortSide * 0.065))
            let gold = Color(hex: 0xC0A34D, alpha: 0.48)
            let quietGold = Color(hex: 0xC0A34D, alpha: 0.32)

            var meander = Path()
            addHorizontalMeander(
                to: &meander,
                from: edgeInset,
                to: size.width - edgeInset,
                edge: edgeInset,
                depth: bandDepth,
                requestedUnit: requestedUnit,
                inwardSign: 1
            )
            addHorizontalMeander(
                to: &meander,
                from: edgeInset,
                to: size.width - edgeInset,
                edge: size.height - edgeInset,
                depth: bandDepth,
                requestedUnit: requestedUnit,
                inwardSign: -1
            )
            addVerticalMeander(
                to: &meander,
                from: edgeInset,
                to: size.height - edgeInset,
                edge: edgeInset,
                depth: bandDepth,
                requestedUnit: requestedUnit,
                inwardSign: 1
            )
            addVerticalMeander(
                to: &meander,
                from: edgeInset,
                to: size.height - edgeInset,
                edge: size.width - edgeInset,
                depth: bandDepth,
                requestedUnit: requestedUnit,
                inwardSign: -1
            )
            context.stroke(meander, with: .color(gold), lineWidth: max(0.65, shortSide * 0.0018))

            let ruleInset = edgeInset + bandDepth + max(5, shortSide * 0.014)
            let ruleRect = CGRect(
                x: ruleInset,
                y: ruleInset,
                width: max(0, size.width - ruleInset * 2),
                height: max(0, size.height - ruleInset * 2)
            )
            context.stroke(
                Path(roundedRect: ruleRect, cornerRadius: max(2, shortSide * 0.008)),
                with: .color(quietGold),
                lineWidth: max(0.6, shortSide * 0.0014)
            )

            drawStuds(in: &context, size: size, inset: ruleInset + max(12, shortSide * 0.035), gold: gold)
            drawMedallion(in: &context, size: size, shortSide: shortSide, gold: quietGold)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func addHorizontalMeander(
        to path: inout Path,
        from start: CGFloat,
        to end: CGFloat,
        edge: CGFloat,
        depth: CGFloat,
        requestedUnit: CGFloat,
        inwardSign: CGFloat
    ) {
        let count = max(1, Int((end - start) / requestedUnit))
        let unit = (end - start) / CGFloat(count)
        for index in 0..<count {
            let x = start + CGFloat(index) * unit
            appendMeanderUnit(to: &path) { point in
                CGPoint(x: x + point.x * unit, y: edge + point.y * depth * inwardSign)
            }
        }
    }

    private func addVerticalMeander(
        to path: inout Path,
        from start: CGFloat,
        to end: CGFloat,
        edge: CGFloat,
        depth: CGFloat,
        requestedUnit: CGFloat,
        inwardSign: CGFloat
    ) {
        let count = max(1, Int((end - start) / requestedUnit))
        let unit = (end - start) / CGFloat(count)
        for index in 0..<count {
            let y = start + CGFloat(index) * unit
            appendMeanderUnit(to: &path) { point in
                CGPoint(x: edge + point.y * depth * inwardSign, y: y + point.x * unit)
            }
        }
    }

    private func appendMeanderUnit(to path: inout Path, transform: (CGPoint) -> CGPoint) {
        let points = [
            CGPoint(x: 0.05, y: 0.92), CGPoint(x: 0.05, y: 0.08),
            CGPoint(x: 0.93, y: 0.08), CGPoint(x: 0.93, y: 0.82),
            CGPoint(x: 0.30, y: 0.82), CGPoint(x: 0.30, y: 0.38),
            CGPoint(x: 0.68, y: 0.38), CGPoint(x: 0.68, y: 0.61),
            CGPoint(x: 0.50, y: 0.61)
        ]
        guard let first = points.first else { return }
        path.move(to: transform(first))
        for point in points.dropFirst() { path.addLine(to: transform(point)) }
    }

    private func drawStuds(in context: inout GraphicsContext, size: CGSize, inset: CGFloat, gold: Color) {
        let radius = min(7, max(4, min(size.width, size.height) * 0.014))
        let centers = [
            CGPoint(x: inset, y: inset), CGPoint(x: size.width - inset, y: inset),
            CGPoint(x: inset, y: size.height - inset), CGPoint(x: size.width - inset, y: size.height - inset)
        ]
        for center in centers {
            let outer = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let innerRadius = radius * 0.32
            let inner = CGRect(
                x: center.x - innerRadius,
                y: center.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            )
            context.fill(Path(ellipseIn: outer), with: .color(.black.opacity(0.16)))
            context.stroke(Path(ellipseIn: outer), with: .color(gold), lineWidth: 0.8)
            context.fill(Path(ellipseIn: inner), with: .color(gold.opacity(0.76)))
        }
    }

    private func drawMedallion(
        in context: inout GraphicsContext,
        size: CGSize,
        shortSide: CGFloat,
        gold: Color
    ) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.51)
        let radius = min(88, max(48, shortSide * 0.145))
        for scale in [1.0, 0.87] {
            let ringRadius = radius * scale
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - ringRadius,
                    y: center.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                )),
                with: .color(gold),
                lineWidth: 0.85
            )
        }

        let pipOrbit = radius * 0.57
        let pipRadius = radius * 0.12
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4 - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * pipOrbit,
                y: center.y + sin(angle) * pipOrbit
            )
            let pipRect = CGRect(
                x: point.x - pipRadius,
                y: point.y - pipRadius,
                width: pipRadius * 2,
                height: pipRadius * 2
            )
            context.fill(Path(ellipseIn: pipRect), with: .color(.black.opacity(0.08)))
            context.stroke(Path(ellipseIn: pipRect), with: .color(gold), lineWidth: 0.75)
            let centerRadius = pipRadius * 0.26
            context.fill(
                Path(ellipseIn: CGRect(
                    x: point.x - centerRadius,
                    y: point.y - centerRadius,
                    width: centerRadius * 2,
                    height: centerRadius * 2
                )),
                with: .color(gold.opacity(0.68))
            )
        }

        let hubRadius = radius * 0.22
        let hub = CGRect(
            x: center.x - hubRadius,
            y: center.y - hubRadius,
            width: hubRadius * 2,
            height: hubRadius * 2
        )
        context.fill(Path(ellipseIn: hub), with: .color(.black.opacity(0.09)))
        context.stroke(Path(ellipseIn: hub), with: .color(gold), lineWidth: 0.9)
        let centerDot = hubRadius * 0.42
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - centerDot,
                y: center.y - centerDot,
                width: centerDot * 2,
                height: centerDot * 2
            )),
            with: .color(gold.opacity(0.52))
        )
    }
}

private struct GameTableMetrics {
    let size: CGSize
    let compact: Bool

    private var shortSide: CGFloat { min(size.width, size.height) }
    private var portrait: Bool { size.height > size.width }
    var opponentTileWidth: CGFloat { compact ? min(24, max(20, shortSide * 0.058)) : min(36, max(27, shortSide * 0.052)) }
    var meldTileWidth: CGFloat { compact ? min(18, max(14, shortSide * 0.040)) : min(24, max(18, shortSide * 0.034)) }
    var sideMeldTileWidth: CGFloat { max(13, meldTileWidth - 2) }
    var riverTileWidth: CGFloat { compact ? min(18, max(13, shortSide * 0.038)) : min(24, max(17, shortSide * 0.034)) }
    var riverWidth: CGFloat { riverTileWidth * 6 + 15 }
    var wallStackWidth: CGFloat { min(compact ? 10 : 15, max(6, size.width * (portrait ? 0.024 : 0.012))) }
    var topRackLength: CGFloat { min(size.width * (portrait ? 0.55 : 0.48), compact ? 270 : 520) }
    var sideRackLength: CGFloat { min(size.height * (portrait ? 0.36 : 0.44), compact ? 245 : 390) }
    var horizontalWallInset: CGFloat { portrait ? max(72, size.height * 0.15) : max(78, size.height * 0.16) }
    var verticalWallInset: CGFloat { portrait ? max(82, size.width * 0.23) : max(105, size.width * 0.14) }

    var topRackPoint: CGPoint { CGPoint(x: size.width * 0.5, y: compact ? 31 : 39) }
    var leftRackPoint: CGPoint { CGPoint(x: compact ? 60 : 70, y: size.height * 0.48) }
    var rightRackPoint: CGPoint { CGPoint(x: size.width - (compact ? 60 : 70), y: size.height * 0.48) }
    var topRiverPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * (portrait ? 0.34 : 0.36)) }
    var leftRiverPoint: CGPoint { CGPoint(x: size.width * (portrait ? 0.30 : 0.31), y: size.height * 0.51) }
    var rightRiverPoint: CGPoint { CGPoint(x: size.width * (portrait ? 0.70 : 0.69), y: size.height * 0.51) }
    var humanRiverPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * (portrait ? 0.68 : 0.67)) }
    var centerPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.51) }
    var humanTrayPoint: CGPoint { CGPoint(x: max(58, size.width * 0.20), y: size.height - (compact ? 20 : 24)) }
    var humanBadgePoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height - (compact ? 17 : 21)) }
}

private struct ActiveSeatSpotlight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let seat: Int
    let humanSeat: Int
    let metrics: GameTableMetrics
    @State private var breathing = false

    var body: some View {
        let relative = (seat - humanSeat + 4) % 4
        let vertical = relative == 1 || relative == 3
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [MJColor.gold(0.26), MJColor.gold(0.09), .clear],
                    center: .center,
                    startRadius: 2,
                    endRadius: vertical ? 72 : 118
                )
            )
            .frame(
                width: vertical ? (metrics.compact ? 92 : 126) : (metrics.compact ? 230 : 310),
                height: vertical ? (metrics.compact ? 220 : 300) : (metrics.compact ? 84 : 110)
            )
            .scaleEffect(reduceMotion ? 1 : (breathing ? 1.05 : 0.96))
            .opacity(reduceMotion ? 0.9 : (breathing ? 1 : 0.72))
            .position(position(relative))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func position(_ relative: Int) -> CGPoint {
        switch relative {
        case 1: metrics.rightRackPoint
        case 2: metrics.topRackPoint
        case 3: metrics.leftRackPoint
        default: metrics.humanBadgePoint
        }
    }
}

private enum RackOrientation: Equatable { case top, left, right }

private struct GameLayoutProfile {
    let size: CGSize
    var isPhone: Bool { min(size.width, size.height) < 600 }
    private var portrait: Bool { size.height >= size.width }
    var spacing: CGFloat { isPhone ? 5 : 8 }
    var horizontalPadding: CGFloat { isPhone ? 6 : 12 }
    var verticalPadding: CGFloat { isPhone ? 4 : 7 }
    var minimumTableHeight: CGFloat { isPhone ? (portrait ? 260 : 220) : 380 }
    var humanTileWidth: CGFloat {
        if isPhone { return portrait ? 31 : 29 }
        return portrait ? 38 : 42
    }
}

private struct PlayerBadge: View {
    let name: String
    let player: GamePlayer
    let total: Int
    let active: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(active ? MJColor.inkOnGold : MJColor.cream(0.30)).frame(width: 7, height: 7)
            Text("\(name.uppercased()) · \(windName(player.seatWind)) · \(total >= 0 ? "+" : "")\(total)")
                .font(MJFont.ui(10, weight: .bold)).foregroundStyle(active ? MJColor.inkOnGold : MJColor.cream(0.60))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            active
                ? AnyShapeStyle(LinearGradient(colors: [MJColor.lightGold, MJColor.gold], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(.black.opacity(0.28)),
            in: Capsule()
        )
        .shadow(color: active ? MJColor.gold(0.56) : .clear, radius: 9)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct SidePlayerBadge: View {
    let name: String
    let player: GamePlayer
    let total: Int
    let active: Bool
    var body: some View {
        VStack(spacing: 2) {
            Circle().fill(active ? MJColor.inkOnGold : MJColor.cream(0.28)).frame(width: 6, height: 6)
            Text(shortWind(player.seatWind)).font(.caption2.weight(.bold))
            Text("\(total >= 0 ? "+" : "")\(total)").font(.system(.caption2, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(active ? MJColor.inkOnGold : MJColor.cream(0.60))
        .frame(width: 34)
        .frame(minHeight: 48)
        .background(
            active
                ? AnyShapeStyle(LinearGradient(colors: [MJColor.lightGold, MJColor.gold], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(.black.opacity(0.30)),
            in: Capsule()
        )
        .shadow(color: active ? MJColor.gold(0.56) : .clear, radius: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(windName(player.seatWind).capitalized), score \(total)")
    }
}

private struct TableRoundCompass: View {
    let round: Wind
    let dealer: Int
    let actor: Int?
    let humanSeat: Int
    let compact: Bool

    var body: some View {
        let side: CGFloat = compact ? 54 : 68
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 13 : 17, style: .continuous)
                .fill(.black.opacity(0.38))
                .overlay { RoundedRectangle(cornerRadius: compact ? 13 : 17).strokeBorder(MJColor.gold(0.52)) }
            Text(shortWind(round))
                .font(compact ? .headline.weight(.bold) : .title3.weight(.bold))
                .foregroundStyle(MJColor.lightGold)
            compassLetter("N", x: 0, y: -side * 0.31)
            compassLetter("E", x: side * 0.31, y: 0)
            compassLetter("S", x: 0, y: side * 0.31)
            compassLetter("W", x: -side * 0.31, y: 0)
            if let actor {
                Circle()
                    .fill(MJColor.gold)
                    .frame(width: compact ? 5 : 7, height: compact ? 5 : 7)
                    .offset(actorOffset(actor, side: side))
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(windName(round).capitalized) round. \(actorDescription). Dealer seat \(dealer + 1).")
    }

    private func compassLetter(_ value: String, x: CGFloat, y: CGFloat) -> some View {
        Text(value).font(.system(size: compact ? 7 : 9, weight: .bold)).foregroundStyle(MJColor.cream(0.55)).offset(x: x, y: y)
    }

    private func actorOffset(_ seat: Int, side: CGFloat) -> CGSize {
        switch (seat - humanSeat + 4) % 4 {
        case 0: CGSize(width: 0, height: side * 0.39)
        case 1: CGSize(width: side * 0.39, height: 0)
        case 2: CGSize(width: 0, height: -side * 0.39)
        default: CGSize(width: -side * 0.39, height: 0)
        }
    }

    private var actorDescription: String {
        guard let actor else { return "No active player" }
        return actor == humanSeat ? "Your turn" : "Seat \(actor + 1) is playing"
    }
}

private struct PhysicalWall: View {
    let front: Int
    let rear: Int
    let size: CGSize
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let stackWidth: CGFloat
    let breakStack: Int
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { segment in
                WallSegment(stackWidth: stackWidth, segment: segment, front: front, rear: rear, breakStack: breakStack)
                    .rotationEffect(.degrees(segment == 0 ? 180 : segment == 1 ? -90 : segment == 2 ? 0 : 90))
                    .position(wallPoint(segment))
            }
            Color.clear
                .frame(width: 2, height: 2)
                .position(stackPoint(min(71, max(0, front / 2))))
                .reportsGameMotionAnchor(.frontWall)
            Color.clear
                .frame(width: 2, height: 2)
                .position(stackPoint(min(71, max(0, (rear - 1) / 2))))
                .reportsGameMotionAnchor(.rearWall)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
    private func wallPoint(_ segment: Int) -> CGPoint {
        switch segment {
        case 0: CGPoint(x: size.width * 0.5, y: horizontalInset)
        case 1: CGPoint(x: size.width - verticalInset, y: size.height * 0.49)
        case 2: CGPoint(x: size.width * 0.5, y: size.height - horizontalInset * 0.58)
        default: CGPoint(x: verticalInset, y: size.height * 0.49)
        }
    }

    private func stackPoint(_ stack: Int) -> CGPoint {
        let segment = stack / 18
        let local = CGFloat(stack % 18) - 8.5
        let offset = local * (stackWidth + 1)
        let center = wallPoint(segment)
        switch segment {
        case 0, 2: return CGPoint(x: center.x + offset, y: center.y)
        case 1, 3: return CGPoint(x: center.x, y: center.y + offset)
        default: return center
        }
    }
}

private struct WallSegment: View {
    let stackWidth: CGFloat
    let segment: Int
    let front: Int
    let rear: Int
    let breakStack: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<18, id: \.self) { localIndex in
                let stack = segment * 18 + localIndex
                let lowerTileIndex = stack * 2
                let isRemaining = lowerTileIndex + 1 >= front && lowerTileIndex < rear
                WallStack(width: stackWidth)
                    .opacity(isRemaining ? 1 : 0.07)
                    .overlay {
                        if stack == breakStack {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(MJColor.gold, lineWidth: 2)
                        }
                    }
            }
        }
    }
}

private struct WallStack: View {
    let width: CGFloat
    var body: some View {
        ZStack {
            MahjongTileBackView(width: width, seed: 1).offset(y: max(2, width * 0.18))
            MahjongTileBackView(width: width, seed: 2)
        }
        .frame(width: width, height: width * 1.68)
    }
}

private struct OpponentRack: View {
    let vertical: Bool
    let reveal: Bool
    let tiles: [TileInstance]
    let width: CGFloat
    let availableLength: CGFloat
    let faceRotation: Double
    private let spacing: CGFloat = 2
    var body: some View {
        Group {
            if vertical { VStack(spacing: spacing) { backs } }
            else { HStack(spacing: spacing) { backs } }
        }
    }
    /// Effective tile width that fits `tiles.prefix(14)` along `availableLength` with no overlap.
    private var fit: CGFloat {
        let count = CGFloat(max(1, min(14, tiles.count)))
        let computed = (availableLength - (count - 1) * spacing) / count
        return min(width, computed)
    }
    @ViewBuilder private var backs: some View {
        ForEach(Array(tiles.prefix(14).enumerated()), id: \.element.id) { _, tile in
            if reveal {
                MahjongTileView(tile.tile, width: fit, showsBadge: false)
                    .rotationEffect(.degrees(faceRotation))
                    .frame(width: vertical ? fit * 1.35 : nil, height: vertical ? fit : nil)
            }
            else {
                MahjongTileBackView(width: fit, seed: UInt64(bitPattern: Int64(tile.id)))
                    .rotationEffect(.degrees(faceRotation))
                    .frame(width: vertical ? fit * 1.45 : nil, height: vertical ? fit : nil)
            }
        }
    }
}

private struct PlayerMeldAndFlowerTray: View {
    let player: GamePlayer
    let width: CGFloat
    var vertical = false
    var highlightedInstanceID: Int?
    let inspect: (Tile, GameTileInsightOrigin) -> Void
    var body: some View {
        if !player.melds.isEmpty || !player.flowers.isEmpty {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
            layout {
                ForEach(player.melds) { meld in
                    HStack(spacing: 1) {
                        ForEach(meld.tiles, id: \.id) { tile in
                            if meld.isConcealed && (tile.id == meld.tiles.first?.id || tile.id == meld.tiles.last?.id) {
                                MahjongTileBackView(width: width, seed: UInt64(bitPattern: Int64(tile.id)))
                            } else {
                                MahjongTileView(tile.tile, width: width, showsBadge: false)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: max(3, width * 0.16), style: .continuous)
                                            .strokeBorder(
                                                tile.id == highlightedInstanceID ? MJColor.gold : .clear,
                                                lineWidth: 2
                                            )
                                            .shadow(
                                                color: tile.id == highlightedInstanceID ? MJColor.gold(0.72) : .clear,
                                                radius: 7
                                            )
                                    }
                                    .rotationEffect(.degrees(
                                        isClaimedInstance(tile, in: meld) || tile.id == highlightedInstanceID ? 90 : 0
                                    ))
                                    .onTapGesture { inspect(tile.tile, .meld(ownerSeat: player.id)) }
                                    .accessibilityLabel(meldAccessibilityLabel(tile, meld: meld))
                                    .accessibilityValue(tile.id == highlightedInstanceID ? "Most recent claimed tile" : "")
                            }
                        }
                    }
                }
                if !player.flowers.isEmpty {
                    HStack(spacing: 1) {
                        ForEach(player.flowers, id: \.id) { tile in
                            MahjongTileView(tile.tile, width: width, showsBadge: false)
                                .onTapGesture { inspect(tile.tile, .flower(ownerSeat: player.id)) }
                        }
                    }
                    .padding(2).background(MJColor.gold(0.16), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(3).background(.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel("\(player.melds.count) exposed melds and \(player.flowers.count) flowers")
        }
    }

    private func isClaimedInstance(_ tile: TileInstance, in meld: GameMeld) -> Bool {
        guard let claimed = meld.claimedTile,
              let claimedInstance = meld.tiles.first(where: { $0.tile == claimed }) else { return false }
        return tile.id == claimedInstance.id
    }

    private func meldAccessibilityLabel(_ tile: TileInstance, meld: GameMeld) -> String {
        guard isClaimedInstance(tile, in: meld), let source = meld.fromSeat else {
            return tileVoiceOverName(tile.tile)
        }
        return "\(tileVoiceOverName(tile.tile)), claimed from seat \(source + 1)"
    }
}

private struct RiverGrid: View {
    let seat: Int
    let wind: Wind
    let tiles: [TileInstance]
    let tileWidth: CGFloat
    let isHuman: Bool
    let isDropTarget: Bool
    let newestDiscardID: Int?
    let inspect: (Tile, GameTileInsightOrigin) -> Void
    var body: some View {
        let showsZone = !tiles.isEmpty || isDropTarget || isHuman
        VStack(spacing: 3) {
            if showsZone {
                HStack(spacing: 3) {
                    Text(isHuman ? "YOUR RIVER" : "\(shortWind(wind)) RIVER")
                        .font(MJFont.ui(8, weight: .bold)).tracking(0.5).foregroundStyle(isDropTarget ? MJColor.inkOnGold : MJColor.gold(0.75))
                    Spacer(minLength: 0)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: 1), count: 6), spacing: 1) {
                    ForEach(tiles, id: \.id) { tile in
                        RecentRiverTile(
                            tile: tile,
                            width: tileWidth,
                            isNewest: tile.id == newestDiscardID
                        )
                            .onTapGesture { inspect(tile.tile, .river(ownerSeat: seat)) }
                            .accessibilityLabel(
                                "\(tileVoiceOverName(tile.tile)), \(tile.id == newestDiscardID ? "most recent " : "")discard by \(windName(wind).lowercased())"
                            )
                    }
                }
            }
        }
        .padding(4)
        .frame(minHeight: tileWidth * 4.8, alignment: .top)
        .background(
            isDropTarget ? AnyShapeStyle(MJColor.gold) : AnyShapeStyle(showsZone ? .black.opacity(0.17) : .clear),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isDropTarget ? MJColor.creamHeading : (showsZone ? MJColor.gold(0.18) : .clear),
                    lineWidth: isDropTarget ? 2 : 1
                )
        }
        .background {
            if isHuman { GeometryReader { proxy in Color.clear.preference(key: HumanRiverFramePreference.self, value: proxy.frame(in: .named("mahjong-game-root"))) } }
        }
    }
}

private struct RecentRiverTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tile: TileInstance
    let width: CGFloat
    let isNewest: Bool
    @State private var hasLanded = false

    var body: some View {
        MahjongTileView(tile.tile, width: width, showsBadge: false)
            .overlay {
                RoundedRectangle(cornerRadius: max(3, width * 0.16), style: .continuous)
                    .strokeBorder(isNewest ? MJColor.gold : .clear, lineWidth: 2)
                    .shadow(color: isNewest ? MJColor.gold(0.72) : .clear, radius: 7)
            }
            .scaleEffect(isNewest && !hasLanded && !reduceMotion ? 1.16 : 1)
            .onAppear { landIfNeeded() }
            .onChange(of: isNewest) { _, _ in
                hasLanded = false
                landIfNeeded()
            }
    }

    private func landIfNeeded() {
        guard isNewest else {
            hasLanded = true
            return
        }
        if reduceMotion {
            hasLanded = true
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
                hasLanded = true
            }
        }
    }
}


private struct HumanRack: View {
    let session: GameSession
    let compact: Bool
    let maximumTileWidth: CGFloat
    let riverDropFrame: CGRect
    @Binding var isDraggingOverRiver: Bool
    let inspect: (Tile, GameTileInsightOrigin) -> Void
    @State private var draggingTileID: Int?
    @State private var dragTranslation = CGSize.zero
    @State private var enteredTarget = false

    var body: some View {
        GeometryReader { geo in
            let tiles = session.humanTiles
            let spacing: CGFloat = compact ? 1 : 2
            let drawnGap: CGFloat = tiles.contains(where: { session.state.lastDrawInstance?.id == $0.id }) ? 12 : 0
            let available = geo.size.width - 16 - drawnGap - spacing * CGFloat(max(tiles.count - 1, 0))
            let tileWidth = min(maximumTileWidth, max(compact ? 20 : 24, available / CGFloat(max(tiles.count, 1))))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(tiles, id: \.id) { tile in
                    tileButton(tile, width: tileWidth, drawnGap: session.state.lastDrawInstance?.id == tile.id ? drawnGap : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
        }
        .frame(height: max(compact ? 60 : 74, maximumTileWidth * 1.35 + 17))
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.18))
                if session.displayedActor == session.humanSeat {
                    HumanRackSpotlight()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(MJColor.gold(0.20)) }
    }

    private func tileButton(_ tile: TileInstance, width: CGFloat, drawnGap: CGFloat) -> some View {
        let selected = session.selectedTileID == tile.id
        let isDrawn = session.state.lastDrawInstance?.id == tile.id
        let isReplacement = isDrawn && session.state.lastDrawKind != .ordinary
        let drawLabel = isReplacement ? "REPLACEMENT FROM WALL" : "FROM WALL"
        return MahjongTileView(tile.tile, width: width, showsBadge: width >= 28)
            .offset(y: selected ? -9 : 0)
            .padding(.leading, drawnGap)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isDrawn ? GameCueColor.wallDraw : .clear, lineWidth: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? MJColor.gold : .clear, lineWidth: 2)
            }
            .overlay(alignment: .top) {
                if isDrawn {
                    Text(drawLabel)
                        .font(.system(size: compact ? 6 : 8, weight: .black, design: .rounded))
                        .tracking(0.35)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(GameCueColor.wallDraw.opacity(0.94), in: Capsule())
                        .overlay {
                            if isReplacement {
                                Capsule().strokeBorder(MJColor.gold, lineWidth: 1)
                            }
                        }
                        .fixedSize()
                        .offset(x: compact && isReplacement ? -46 : (compact ? -18 : 0), y: compact ? -13 : -15)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: isDrawn ? GameCueColor.wallDraw.opacity(0.82) : .clear, radius: 7)
            .scaleEffect(draggingTileID == tile.id || session.debugDraggingTileID == tile.id ? 1.12 : 1)
            .offset(draggingTileID == tile.id ? dragTranslation : (session.debugDraggingTileID == tile.id ? CGSize(width: 0, height: -18) : .zero))
            .zIndex(draggingTileID == tile.id || session.debugDraggingTileID == tile.id ? 2 : 0)
            .contentShape(Rectangle())
            .onTapGesture { session.select(tile) }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in inspect(tile.tile, .humanHand) })
            .highPriorityGesture(dragGesture(for: tile))
            .accessibilityLabel(
                "\(tileVoiceOverName(tile.tile))\(isDrawn ? (isReplacement ? ", latest private replacement drawn from the rear wall" : ", latest private tile drawn from the wall") : "")\(selected ? ", selected" : "")"
            )
            .accessibilityHint("Double tap to select for discard. Use the Learn about action for tile details.")
            .accessibilityAction(named: "Learn about \(tileVoiceOverName(tile.tile))") { inspect(tile.tile, .humanHand) }
    }

    private func dragGesture(for tile: TileInstance) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("mahjong-game-root"))
            .onChanged { value in
                guard session.isHumanTurn else { return }
                draggingTileID = tile.id
                dragTranslation = value.translation
                let entered = riverDropFrame.contains(value.location)
                if entered && !enteredTarget { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                enteredTarget = entered
                isDraggingOverRiver = entered
            }
            .onEnded { value in
                let shouldDiscard = session.isHumanTurn && riverDropFrame.contains(value.location)
                if shouldDiscard {
                    session.discard(tile)
                }
                draggingTileID = nil
                dragTranslation = .zero
                enteredTarget = false
                isDraggingOverRiver = false
            }
    }
}

private struct HumanRackSpotlight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        RadialGradient(
            colors: [MJColor.gold(0.25), MJColor.gold(0.07), .clear],
            center: .center,
            startRadius: 4,
            endRadius: 190
        )
        .scaleEffect(reduceMotion ? 1 : (breathing ? 1.04 : 0.96))
        .opacity(reduceMotion ? 0.9 : (breathing ? 1 : 0.72))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct TableDecisionDock: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let prompt: String
    let compact: Bool
    let isSuggesting: Bool
    let canSuggest: Bool
    let canDiscard: Bool
    let canUndo: Bool
    let canProceed: Bool
    let suggest: () -> Void
    let discard: () -> Void
    let undo: () -> Void
    let proceed: () -> Void

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            Group {
                if prompt.isEmpty {
                    Color.clear
                        .accessibilityHidden(true)
                } else {
                    Text(prompt)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MJColor.cream(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .accessibilityLabel("Decision feedback: \(prompt)")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17)

            HStack(spacing: compact ? 6 : 9) {
                dockButton(
                    title: "Suggest",
                    symbol: isSuggesting ? nil : "lightbulb.max",
                    prominent: false,
                    enabled: canSuggest && !isSuggesting,
                    action: suggest
                )
                .overlay { if isSuggesting { ProgressView().tint(MJColor.gold) } }

                dockButton(
                    title: canProceed ? "Proceed" : "Discard",
                    symbol: canProceed ? "play.fill" : "arrow.up.square.fill",
                    prominent: true,
                    enabled: canProceed || canDiscard,
                    action: canProceed ? proceed : discard
                )

                dockButton(
                    title: "Undo",
                    symbol: "arrow.uturn.backward",
                    prominent: false,
                    enabled: canUndo,
                    action: undo
                )
            }
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 5 : 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(MJColor.gold(0.22)) }
    }

    private func dockButton(
        title: String,
        symbol: String?,
        prominent: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: compact ? 4 : 6) {
                if let symbol, !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: symbol).imageScale(.small)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.55 : 0.85)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? MJColor.inkOnGold : MJColor.gold)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                prominent ? AnyShapeStyle(LinearGradient(colors: [MJColor.lightGold, MJColor.gold], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(MJColor.deepJade.opacity(0.78)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(MJColor.gold(0.28))
                }
            }
            .opacity(enabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityHint(buttonHint(title))
    }

    private func buttonHint(_ title: String) -> String {
        switch title {
        case "Suggest": return "Highlights the strongest discard from public table information"
        case "Discard": return "Discards the selected tile"
        case "Proceed": return "Continues step-by-step play"
        default: return "Rewinds the last human decision and later opponent actions"
        }
    }
}

private struct InlineClaimBar: View {
    let offer: PendingOffer
    let sourceName: String
    let actions: [GameAction]
    let label: (GameAction) -> String
    let seconds: Int?
    let compact: Bool
    let onAction: (GameAction) -> Void
    let onPass: () -> Void
    let inspect: () -> Void

    private var nonPassActions: [GameAction] { actions.filter { $0.kind != .pass } }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            MahjongTileView(offer.tile, width: compact ? 36 : 43, showsBadge: false)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(MJColor.gold, lineWidth: 2)
                        .shadow(color: MJColor.gold(0.72), radius: 7)
                }
                .onTapGesture(perform: inspect)
                .accessibilityAction(named: "Learn about \(tileVoiceOverName(offer.tile))") { inspect() }

            VStack(alignment: .leading, spacing: 2) {
                Text(claimTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(MJColor.creamHeading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(MJColor.cream(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(nonPassActions, id: \.id) { action in
                    GameActionButton(
                        title: label(action),
                        prominent: action.kind == .win,
                        action: { onAction(action) }
                    )
                }
                GameActionButton(title: "Pass", prominent: false, action: onPass)
            }
        }
        .padding(.horizontal, compact ? 9 : 13)
        .padding(.vertical, 7)
        .background(MJColor.deepJade.opacity(0.96), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(MJColor.gold(0.46), lineWidth: 1.5) }
        .shadow(color: .black.opacity(0.34), radius: 10, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(sourceName) offered \(tileVoiceOverName(offer.tile))")
    }

    private var claimTitle: String {
        let tile = MahjongData.name(for: offer.tile).english
        if nonPassActions.count == 1, let action = nonPassActions.first {
            return "\(label(action)) \(tile)?"
        }
        return "Claim \(tile)?"
    }

    private var detailText: String {
        if let seconds { return "From \(sourceName) · auto-pass in \(seconds)s" }
        return "From \(sourceName) · choose or Pass"
    }
}

private struct GameTableAnnouncementView: View {
    let announcement: GameTableAnnouncement
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(announcement.title)
                .font(.title2.weight(.black))
                .tracking(1.1)
                .foregroundStyle(
                    announcement.style == .claim ? MJColor.gold : MJColor.creamHeading
                )
            Text(announcement.subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MJColor.gold(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(MJColor.gold(0.44)) }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 9)
        .padding(24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.24), value: announcement.id)
    }
}

private struct ReactionOverlay: View {
    let offer: PendingOffer
    let sourceName: String
    let actions: [GameAction]
    let label: (GameAction) -> String
    let seconds: Int?
    let onAction: (GameAction) -> Void
    let onPass: () -> Void
    let inspect: () -> Void
    var body: some View {
        Color.black.opacity(0.42).ignoresSafeArea()
            .overlay {
                VStack(spacing: 14) {
                    Text(offer.isRobKong ? "Rob the kong?" : "Claim this tile?")
                        .font(MJFont.sheetTitle).foregroundStyle(MJColor.creamHeading)
                    MahjongTileView(offer.tile, width: 58, showsBadge: false)
                        .onTapGesture(perform: inspect)
                        .accessibilityAction(named: "Learn about \(tileVoiceOverName(offer.tile))") { inspect() }
                    Text("Offered by \(sourceName)").font(MJFont.caption).foregroundStyle(MJColor.cream(0.68))
                    HStack(spacing: 8) {
                        ForEach(actions.filter { label($0) != "Pass" }, id: \.id) { action in
                            GameActionButton(title: action.kind == .win && offer.isRobKong ? "Win · Rob Kong" : label(action), prominent: action.kind == .win) { onAction(action) }
                        }
                        GameActionButton(title: "Pass", prominent: false, action: onPass)
                    }
                    if let seconds { Text("Passes in \(seconds) seconds").font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.58)) }
                }
                .padding(22).background(MJColor.deepJade.opacity(0.98), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(MJColor.gold(0.35)) }
                .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                .padding(24)
            }
            .accessibilityAddTraits(.isModal)
    }
}

/// Rob-kong is intentionally rare in natural seeded play. This deterministic
/// screenshot-only composition exercises the exact production prompt without
/// fabricating or mutating a simulator state.
struct GameRobKongDebugView: View {
    let session: GameSession

    var body: some View {
        GameView(session: session, debugDestination: .dragging)
            .overlay {
                ReactionOverlay(
                    offer: PendingOffer(tile: .m(5), fromSeat: 1, isRobKong: true),
                    sourceName: "Player 2",
                    actions: [try! GameAction(id: 1), try! GameAction(id: 0)],
                    label: { $0.kind == .win ? "Win" : "Pass" },
                    seconds: nil,
                    onAction: { _ in },
                    onPass: { },
                    inspect: { }
                )
            }
    }
}

/// A cancellable, cosmetic treatment of the hand opening. The simulator has
/// already dealt the tiles; this overlay merely makes the deterministic seed
/// visible without delaying or altering state transitions.
private struct OpeningPresentationOverlay: View {
    let phase: GamePresentationPhase
    let dice: [Int]
    let breakStack: Int
    let dealCounts: [Int]
    let reduceMotion: Bool
    let skip: () -> Void

    private var stage: GameOpeningStage? { phase.openingStage }
    var body: some View {
        Color.black.opacity(0.38).ignoresSafeArea()
            .overlay {
                VStack(spacing: 16) {
                    switch stage {
                    case .assemblingWalls:
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 42)).foregroundStyle(MJColor.gold)
                        Text("Building the wall")
                    case .rollingDice:
                        HStack(spacing: 10) {
                            ForEach(Array(dice.enumerated()), id: \.offset) { _, die in
                                Text("\(die)").font(.title.bold()).frame(width: 48, height: 48)
                                    .foregroundStyle(MJColor.inkOnGold).background(MJColor.gold, in: RoundedRectangle(cornerRadius: 11))
                                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(die * 17)))
                            }
                        }
                        Text("Rolling for the break")
                    case .highlightingBreak:
                        Image(systemName: "sparkle").font(.system(size: 42)).foregroundStyle(MJColor.gold)
                        Text("Breaking the wall at stack \(breakStack + 1)")
                    case .dealing:
                        OpeningDealMotion(reduceMotion: reduceMotion)
                        HStack(spacing: 9) {
                            ForEach(Array(dealCounts.enumerated()), id: \.offset) { seat, count in
                                VStack(spacing: 3) {
                                    Text("\(count)").font(.title3.bold()).foregroundStyle(MJColor.creamHeading)
                                    Text(shortWind(Wind(rawValue: seat) ?? .east)).font(.caption2).foregroundStyle(MJColor.gold)
                                }
                            }
                        }
                        Text("Dealing tiles")
                    case .revealingHand:
                        Image(systemName: "hand.draw.fill").font(.system(size: 40)).foregroundStyle(MJColor.gold)
                        Text("Your hand is ready")
                    case nil:
                        EmptyView()
                    }
                    Button("Skip", action: skip)
                        .font(.body.weight(.semibold)).foregroundStyle(MJColor.inkOnGold)
                        .frame(minWidth: 88, minHeight: 44).background(MJColor.gold, in: Capsule())
                }
                .font(MJFont.sheetTitle).foregroundStyle(MJColor.creamHeading)
                .padding(28).background(MJColor.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(MJColor.gold(0.35)) }
                .padding(24)
            }
            .accessibilityAddTraits(.isModal)
    }
}

private struct OpeningDealMotion: View {
    let reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { seat in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(colors: [MJColor.gold(0.82), MJColor.jade], startPoint: .top, endPoint: .bottom))
                    .frame(width: 19, height: 27)
                    .offset(expanded ? destination(for: seat) : .zero)
                    .opacity(expanded ? 0.45 : 1)
            }
        }
        .frame(width: 150, height: 72)
        .onAppear {
            if reduceMotion { expanded = true }
            else {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func destination(for seat: Int) -> CGSize {
        switch seat {
        case 0: .init(width: 0, height: 28)
        case 1: .init(width: 58, height: 0)
        case 2: .init(width: 0, height: -28)
        default: .init(width: -58, height: 0)
        }
    }
}

private struct TableMotionCue: View {
    let motion: GameTableMotion
    let humanSeat: Int
    let anchors: [GameMotionAnchor: CGRect]
    let reduceMotion: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let from = point(for: motion.source, in: proxy.size)
            let to = point(for: motion.destination, in: proxy.size)
            Group {
                if let tile = motion.tile {
                    MahjongTileView(tile, width: motion.kind == .discard ? 30 : 31, showsBadge: false)
                } else {
                    Image(systemName: motion.kind == .win ? "sparkles" : "circle.fill")
                        .font(.title2)
                        .foregroundStyle(MJColor.gold)
                }
            }
            .shadow(color: motion.usesGoldCue ? MJColor.gold(0.72) : .black.opacity(0.35), radius: 9)
            .rotationEffect(.degrees(motion.rotatesAtDestination ? 90 * progress : 0))
            .scaleEffect(motion.kind == .discard ? 1 + (1 - progress) * 0.10 : 1)
            .position(
                x: from.x + (to.x - from.x) * progress,
                y: from.y + (to.y - from.y) * progress
            )
            .opacity(progress < 0.96 ? 1 : 0.35)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion { progress = 1 }
            else {
                withAnimation(.easeOut(duration: Double(motion.durationMilliseconds) / 1_000)) {
                    progress = 1
                }
            }
        }
    }

    private func point(for source: GameTableMotion.Source, in size: CGSize) -> CGPoint {
        switch source {
        case .frontWall: anchorPoint(.frontWall) ?? CGPoint(x: size.width * 0.50, y: size.height * 0.25)
        case .rearWall: anchorPoint(.rearWall) ?? CGPoint(x: size.width * 0.24, y: size.height * 0.42)
        case let .rack(seat): anchorPoint(.rack(seat)) ?? rackPoint(seat: seat, in: size)
        case let .river(seat): anchorPoint(.river(seat)) ?? riverPoint(seat: seat, in: size)
        case .table: CGPoint(x: size.width * 0.50, y: size.height * 0.48)
        }
    }

    private func point(for destination: GameTableMotion.Destination, in size: CGSize) -> CGPoint {
        switch destination {
        case let .rack(seat): anchorPoint(.rack(seat)) ?? rackPoint(seat: seat, in: size)
        case let .river(seat): anchorPoint(.river(seat)) ?? riverPoint(seat: seat, in: size)
        case let .meldTray(seat):
            anchorPoint(.meld(seat)) ?? anchorPoint(.rack(seat)) ?? rackPoint(seat: seat, in: size)
        case let .bonusTray(seat):
            anchorPoint(.meld(seat)) ?? anchorPoint(.rack(seat)) ?? rackPoint(seat: seat, in: size)
        case .result, .table: CGPoint(x: size.width * 0.50, y: size.height * 0.48)
        }
    }

    private func anchorPoint(_ anchor: GameMotionAnchor) -> CGPoint? {
        guard let frame = anchors[anchor], !frame.isNull, !frame.isEmpty else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func rackPoint(seat: Int, in size: CGSize) -> CGPoint {
        switch relativeSeat(seat) {
        case 0: CGPoint(x: size.width * 0.50, y: size.height * 0.89)
        case 1: CGPoint(x: size.width * 0.86, y: size.height * 0.46)
        case 2: CGPoint(x: size.width * 0.50, y: size.height * 0.17)
        default: CGPoint(x: size.width * 0.14, y: size.height * 0.46)
        }
    }

    private func riverPoint(seat: Int, in size: CGSize) -> CGPoint {
        switch relativeSeat(seat) {
        case 0: CGPoint(x: size.width * 0.50, y: size.height * 0.70)
        case 1: CGPoint(x: size.width * 0.70, y: size.height * 0.48)
        case 2: CGPoint(x: size.width * 0.50, y: size.height * 0.33)
        default: CGPoint(x: size.width * 0.30, y: size.height * 0.48)
        }
    }

    private func relativeSeat(_ seat: Int) -> Int { (seat - humanSeat + 4) % 4 }
}

struct GameActionButton: View {
    let title: String; let prominent: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(MJFont.ui(13, weight: .bold)).foregroundStyle(prominent ? MJColor.inkOnGold : MJColor.gold).frame(minWidth: 50).frame(minHeight: 44).padding(.horizontal, 3).background(prominent ? AnyShapeStyle(MJColor.gold) : AnyShapeStyle(MJColor.gold(0.12)), in: RoundedRectangle(cornerRadius: 12)) }
            .buttonStyle(.plain).accessibilityLabel(title)
    }
}

private enum GameMotionAnchor: Hashable {
    case frontWall
    case rearWall
    case rack(Int)
    case river(Int)
    case meld(Int)
}

private struct GameMotionAnchorPreference: PreferenceKey {
    static var defaultValue: [GameMotionAnchor: CGRect] = [:]

    static func reduce(
        value: inout [GameMotionAnchor: CGRect],
        nextValue: () -> [GameMotionAnchor: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

private extension View {
    func reportsGameMotionAnchor(_ anchor: GameMotionAnchor) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: GameMotionAnchorPreference.self,
                    value: [anchor: proxy.frame(in: .named("mahjong-game-root"))]
                )
            }
        }
    }
}

private enum GameCueColor {
    static let wallDraw = Color(red: 0.37, green: 0.69, blue: 1.0)
}

private struct HumanRiverFramePreference: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private func windName(_ wind: Wind) -> String { ["EAST", "SOUTH", "WEST", "NORTH"][wind.rawValue] }
private func shortWind(_ wind: Wind) -> String { ["E", "S", "W", "N"][wind.rawValue] }
private func gamePlayerName(seat: Int, humanSeat: Int) -> String { seat == humanSeat ? "You" : "Bot \((seat - humanSeat + 4) % 4)" }
private func tileVoiceOverName(_ tile: Tile) -> String {
    switch tile {
    case let .suited(suit, rank): return "\(["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"][rank - 1]) \(suit == .characters ? "character" : suit == .dots ? "dot" : "bamboo")"
    case let .wind(wind): return "\(windName(wind).lowercased()) wind"
    case let .dragon(dragon): return ["red dragon", "green dragon", "white dragon"][dragon.rawValue]
    case let .flower(flower): return ["plum flower", "orchid flower", "chrysanthemum flower", "bamboo flower"][flower.rawValue - 1]
    case let .season(season): return ["spring season", "summer season", "autumn season", "winter season"][season.rawValue - 1]
    }
}
