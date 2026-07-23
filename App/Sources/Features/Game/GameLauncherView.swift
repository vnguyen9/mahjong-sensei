import SwiftUI
import DesignSystem
import MahjongCore
import MahjongGameEngine

/// Hidden debug entry point for a complete four-wind local match.
struct GameLauncherView: View {
    @State private var seedText = ""
    @State private var seat = 0
    @State private var launchSeed = UInt64.random(in: 1...UInt64.max)
    @State private var difficulty: BotDifficulty = .normal
    @State private var showsAdvanced = false
    @State private var savedMatch: PersistedMahjongMatchV1?
    @State private var launch: GameLaunch?
    @State private var confirmsReplacement = false
    @State private var launchError: String?
    private let loadsPersistence: Bool

    init(debugSavedMatch: PersistedMahjongMatchV1? = nil) {
        _savedMatch = State(initialValue: debugSavedMatch)
        loadsPersistence = debugSavedMatch == nil
    }

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Mahjong game")
                        .font(MJFont.screenTitle)
                        .foregroundStyle(MJColor.creamHeading)
                        Text("EXPERIMENTAL · LOCAL MATCH")
                        .eyebrowStyle()

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Play a complete four-wind Hong Kong Mahjong match against local opponents. Your seat stays fixed while dealer and winds rotate around the table.")
                            .font(MJFont.body)
                            .foregroundStyle(MJColor.cream(0.70))
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Opponent difficulty")
                            .font(MJFont.label).foregroundStyle(MJColor.creamHeading)
                        Picker("Opponent difficulty", selection: $difficulty) {
                            Text("Easy").tag(BotDifficulty.easy); Text("Normal").tag(BotDifficulty.normal); Text("Hard").tag(BotDifficulty.hard)
                        }
                        .pickerStyle(.segmented).tint(MJColor.gold)
                        Text("Difficulty is stored with the match and ready for the policy tier selected for each opponent.")
                            .font(MJFont.caption).foregroundStyle(MJColor.cream(0.54))

                        Text("Your seat")
                            .font(MJFont.label)
                            .foregroundStyle(MJColor.creamHeading)
                        Picker("Your seat", selection: $seat) {
                            Text("East").tag(0); Text("South").tag(1); Text("West").tag(2); Text("North").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .tint(MJColor.gold)

                        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                            TextField("Match seed", text: $seedText)
                                .keyboardType(.numberPad)
                                .font(MJFont.ui(16, weight: .medium))
                                .foregroundStyle(MJColor.creamHeading)
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                                .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(MJColor.gold(0.22)) }
                                .accessibilityLabel("Optional match seed")
                                .padding(.top, 8)
                        }
                        .font(MJFont.label).foregroundStyle(MJColor.gold)
                    }
                    .mjCard()

                    if let savedMatch {
                        resumeCard(savedMatch)
                    }

                    GoldButton("New match", withShadow: true) {
                        if savedMatch == nil {
                            startNewMatch()
                        } else {
                            confirmsReplacement = true
                        }
                    }
                    .accessibilityHint("Starts a new four-wind experimental Mahjong match")

                    Text("Hands stay on this device. There is no account or online play.")
                        .font(MJFont.caption)
                        .foregroundStyle(MJColor.cream(0.50))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(20)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Mahjong game")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $launch) { launch in
            GameView(session: launch.session)
        }
        .task { if loadsPersistence { await refreshSavedMatch() } }
        .confirmationDialog(
            "Replace saved match?",
            isPresented: $confirmsReplacement,
            titleVisibility: .visible
        ) {
            Button("Replace saved match", role: .destructive) { startNewMatch(replacingSavedMatch: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your current local match will be replaced by the new match.")
        }
        .alert("Unable to resume match", isPresented: Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    @ViewBuilder
    private func resumeCard(_ persisted: PersistedMahjongMatchV1) -> some View {
        let replay = persisted.replay
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resume match")
                        .font(MJFont.sheetTitle)
                        .foregroundStyle(MJColor.creamHeading)
                    Text("\(roundName(replay.prevailingWind)) ROUND · HAND \(replay.currentHandIndex + 1) · YOU: \(seatName(replay.configuration.humanSeat))")
                        .font(MJFont.eyebrow)
                        .foregroundStyle(MJColor.gold(0.82))
                }
                Spacer()
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(MJColor.gold)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                ForEach(Array(replay.totals.enumerated()), id: \.offset) { seat, total in
                    VStack(spacing: 2) {
                        Text(seat == replay.configuration.humanSeat ? "YOU" : String(seatName(seat).prefix(1)))
                            .font(MJFont.eyebrow)
                            .foregroundStyle(seat == replay.configuration.humanSeat ? MJColor.gold : MJColor.cream(0.52))
                        Text("\(total >= 0 ? "+" : "")\(total)")
                            .font(MJFont.ui(15, weight: .bold))
                            .foregroundStyle(MJColor.creamHeading)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 7)
            .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Text("Saved \(persisted.savedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(MJFont.caption)
                .foregroundStyle(MJColor.cream(0.56))

            GoldButton("Resume match") { resume(persisted) }
                .accessibilityHint("Resumes your saved local Mahjong match")
        }
        .mjCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved match. \(roundName(replay.prevailingWind)) round, hand \(replay.currentHandIndex + 1). Your seat is \(seatName(replay.configuration.humanSeat)).")
    }

    private func startNewMatch(replacingSavedMatch: Bool = false) {
        let seed = UInt64(seedText) ?? UInt64.random(in: 1...UInt64.max)
        launchSeed = seed
        if replacingSavedMatch {
            Task {
                await MahjongMatchStore.shared.clear()
                savedMatch = nil
                launchNewMatch(seed: seed)
            }
            return
        }
        launchNewMatch(seed: seed)
    }

    private func launchNewMatch(seed: UInt64) {
        launch = GameLaunch(session: GameSession(
            seed: seed,
            humanSeat: seat,
            difficulty: difficulty,
            persistence: .shared
        ))
    }

    private func resume(_ persisted: PersistedMahjongMatchV1) {
        do {
            launch = GameLaunch(session: try GameSession(replay: persisted.replay, persistence: .shared))
        } catch {
            launchError = error.localizedDescription
            Task {
                await MahjongMatchStore.shared.clear()
                await MainActor.run { savedMatch = nil }
            }
        }
    }

    private func refreshSavedMatch() async {
        let archive = await MahjongMatchStore.shared.load()
        savedMatch = archive
    }

    private func roundName(_ wind: Wind) -> String {
        ["East", "South", "West", "North"][wind.rawValue]
    }

    private func seatName(_ seat: Int) -> String {
        ["East", "South", "West", "North"][safe: seat] ?? "Unknown"
    }
}

private struct GameLaunch: Identifiable, Hashable {
    let id = UUID()
    let session: GameSession

    static func == (lhs: GameLaunch, rhs: GameLaunch) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Centralizes deterministic screenshot scenes so RootView only needs one route hook.
@MainActor
enum MahjongGameDebugScene {
    static func view(for route: String) -> AnyView? {
        let seed: UInt64 = 20_260_720
        switch route {
        case "game":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0)) })
        case "game-turn-human", "game-wall-draw":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .humanTurn) })
        case "game-turn-opponent":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .opponentTurn) })
        case "game-newest-discard":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .newestDiscard) })
        case "game-inline-claim":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .claimPung) })
        case "game-complex-claim":
            return AnyView(NavigationStack { GameRobKongDebugView(session: GameSession(seed: seed, humanSeat: 0)) })
        case "game-post-claim-discard":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .postClaimDiscard) })
        case "game-reaction":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 1, humanSeat: 0), debugDestination: .reaction) })
        case "game-result":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 2, humanSeat: 0), debugDestination: .result) })
        case "game-scoreboard":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 3, humanSeat: 1), debugDestination: .scoreboard) })
        case "game-match-end":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 4, humanSeat: 2), debugDestination: .matchEnd) })
        case "game-inspector":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), forceInspector: true) })
        case "game-learning":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 5, humanSeat: 0), debugDestination: .learning) })
        case "game-dice":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 6, humanSeat: 0), debugDestination: .dice) })
        case "game-dealing":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 7, humanSeat: 0), debugDestination: .dealing) })
        case "game-dragging":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 8, humanSeat: 0), debugDestination: .dragging) })
        case "game-claim-win":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .claimWin) })
        case "game-claim-pung":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .claimPung) })
        case "game-claim-kong":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .claimKong) })
        case "game-claim-chow":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .claimChow) })
        case "game-rob-kong":
            return AnyView(NavigationStack { GameRobKongDebugView(session: GameSession(seed: seed, humanSeat: 0)) })
        case "game-replacement-draw":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed, humanSeat: 0), debugDestination: .replacementDraw) })
        case "game-resume":
            let state = try! MatchState(configuration: MatchConfiguration(seed: seed + 15, humanSeat: 1))
            let saved = PersistedMahjongMatchV1(
                replay: state.serializeReplay(),
                savedAt: Date(timeIntervalSince1970: 1_774_173_600)
            )
            return AnyView(NavigationStack { GameLauncherView(debugSavedMatch: saved) })
        case "game-table-large":
            return AnyView(NavigationStack { GameView(session: GameSession(seed: seed + 16, humanSeat: 2)) })
        default:
            return nil
        }
    }
}
