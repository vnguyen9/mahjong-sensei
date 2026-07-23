import SwiftUI
import DesignSystem
import MahjongCore
import MahjongGameEngine

struct ChowChoiceSheet: View {
    let actions: [GameAction]
    let session: GameSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground(.content)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choose chow")
                        .font(MJFont.sheetTitle).foregroundStyle(MJColor.creamHeading)
                    Text("Choose the sequence you want to expose.")
                        .font(MJFont.body).foregroundStyle(MJColor.cream(0.66))
                    ForEach(actions, id: \.id) { action in
                        let pattern = chowPatterns[action.chowIndex ?? 0]
                        Button {
                            session.apply(action); dismiss()
                        } label: {
                            HStack {
                                HStack(spacing: 3) { ForEach(pattern, id: \.classIndex) { MahjongTileView($0, width: 28, showsBadge: false) } }
                                Spacer(); Image(systemName: "chevron.right")
                            }
                                .font(MJFont.label).foregroundStyle(MJColor.creamHeading).padding(14).frame(minHeight: 48)
                                .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                        .accessibilityLabel("Chow \(pattern.map { $0.code }.joined(separator: ", "))")
                    }
                    Spacer()
                }.padding(20)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.tint(MJColor.gold) } }
        }
        .presentationDetents([.medium])
    }
}

struct GameResultSheet: View {
    let session: GameSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground(.content)
                ScrollView {
                    VStack(spacing: 18) {
                        Image(systemName: "trophy.fill").font(.system(size: 38)).foregroundStyle(MJColor.gold)
                        Text(resultTitle).font(MJFont.serif(28, weight: .bold)).foregroundStyle(MJColor.creamHeading)
                        if let result = session.state.terminal {
                            if let resultSource {
                                Text(resultSource)
                                    .font(MJFont.body)
                                    .foregroundStyle(MJColor.cream(0.68))
                                    .multilineTextAlignment(.center)
                            }
                            Text("\(result.faan) FAAN").font(MJFont.bigFaan).foregroundStyle(MJColor.lightGold)
                            Text(result.patternBreakdown.map { "\($0.name) · \($0.faan) faan" }.joined(separator: "\n"))
                                .font(MJFont.caption).foregroundStyle(MJColor.cream(0.70)).multilineTextAlignment(.center)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Payments").font(MJFont.label).foregroundStyle(MJColor.creamHeading)
                                ForEach(Array(result.payments.enumerated()), id: \.offset) { index, payment in
                                    HStack {
                                        Text("\(playerName(index, humanSeat: session.humanSeat)) · \(seatName(session.state.players[index].seatWind))")
                                        Spacer()
                                        Text("\(payment >= 0 ? "+" : "")\(payment)")
                                    }
                                        .font(MJFont.body).foregroundStyle(payment >= 0 ? MJColor.lightGold : MJColor.cream(0.65))
                                }
                            }.mjCard().frame(maxWidth: 380)
                            MatchScoreboard(session: session, lastPayments: result.payments)
                        }
                        if session.state.terminal != nil {
                            GoldButton("Next hand") { session.advanceToNextHand(); dismiss() }
                            SecondaryButton("Replay seed") { session.restart(seed: session.seed); dismiss() }
                        }
                        ShareLink(item: session.replayText, subject: Text("Mahjong Sensei replay"), message: Text("Replay seed \(session.seed)")) {
                            Label("Share replay", systemImage: "square.and.arrow.up")
                                .font(MJFont.label).foregroundStyle(MJColor.gold).frame(minHeight: 44)
                        }
                    }.padding(24)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.tint(MJColor.gold) } }
        }
    }
    private var resultTitle: String {
        guard let terminal = session.state.terminal else { return "Hand complete" }
        guard let winner = terminal.winner else { return "Draw game" }
        return winner == session.humanSeat
            ? "You win"
            : "\(playerName(winner, humanSeat: session.humanSeat)) wins · \(seatName(session.state.players[winner].seatWind))"
    }

    private var resultSource: String? {
        guard let result = session.state.terminal, let source = result.winSource else { return nil }
        switch source {
        case .selfDraw:
            return "Self-drawn win"
        case .discard:
            guard let discarder = result.discarder else { return "Won from a discard" }
            return "Won from \(playerName(discarder, humanSeat: session.humanSeat)) · \(seatName(session.state.players[discarder].seatWind))"
        case .robKong:
            guard let discarder = result.discarder else { return "Won by robbing a kong" }
            return "Robbed \(playerName(discarder, humanSeat: session.humanSeat))'s kong"
        case .flowerSeven:
            return "Instant win · seven flowers"
        case .flowerEight:
            return "Instant win · eight flowers"
        }
    }
}

struct MatchEndSheet: View {
    let session: GameSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground(.content)
                ScrollView {
                    VStack(spacing: 18) {
                        Image(systemName: "crown.fill").font(.system(size: 38)).foregroundStyle(MJColor.gold)
                        Text("Match complete").font(MJFont.serif(28, weight: .bold)).foregroundStyle(MJColor.creamHeading)
                        Text("\(session.match.summary.handsPlayed) hands · four wind rounds").font(MJFont.caption).foregroundStyle(MJColor.cream(0.62))
                        VStack(spacing: 0) {
                            ForEach(Array(session.standings.enumerated()), id: \.element) { rank, seat in
                                let stats = session.seatStats[seat]
                                HStack {
                                    Text("#\(rank + 1)").font(MJFont.serif(20, weight: .bold)).foregroundStyle(rank == 0 ? MJColor.lightGold : MJColor.cream(0.55)).frame(width: 35, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playerName(seat, humanSeat: session.humanSeat)).font(MJFont.label).foregroundStyle(MJColor.creamHeading)
                                        Text("Finished as \(seatName(session.state.players[seat].seatWind))")
                                            .font(MJFont.ui(9)).foregroundStyle(MJColor.cream(0.46))
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        Text("\(session.totals[seat] >= 0 ? "+" : "")\(session.totals[seat])").font(MJFont.label).foregroundStyle(session.totals[seat] >= 0 ? MJColor.lightGold : MJColor.cream(0.60))
                                        Text("\(stats.wins) wins · best \(stats.biggestFaan) faan").font(MJFont.ui(10)).foregroundStyle(MJColor.cream(0.48))
                                    }
                                }
                                .padding(.vertical, 11)
                                if rank < 3 { Divider().overlay(MJColor.gold(0.12)) }
                            }
                        }.mjCard().frame(maxWidth: 420)
                        GoldButton("New match") { session.restart(); dismiss() }
                        ShareLink(item: session.replayText) { Label("Share match replay", systemImage: "square.and.arrow.up").font(MJFont.label).foregroundStyle(MJColor.gold).frame(minHeight: 44) }
                    }.padding(24)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.tint(MJColor.gold) } }
        }
    }
}

private struct MatchScoreboard: View {
    let session: GameSession
    let lastPayments: [Int]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Match score").font(MJFont.label).foregroundStyle(MJColor.creamHeading)
                Spacer()
                Text("Next dealer: \(playerName(session.match.currentDealer, humanSeat: session.humanSeat))")
                    .font(MJFont.ui(10)).foregroundStyle(MJColor.gold)
            }
            ForEach(0..<4, id: \.self) { seat in
                HStack {
                    Text("\(playerName(seat, humanSeat: session.humanSeat)) · \(seatName(session.state.players[seat].seatWind))")
                        .font(MJFont.caption).foregroundStyle(MJColor.cream(0.70))
                    Spacer()
                    Text("\(lastPayments[seat] >= 0 ? "+" : "")\(lastPayments[seat])").font(MJFont.caption).foregroundStyle(lastPayments[seat] >= 0 ? MJColor.lightGold : MJColor.cream(0.55)).frame(width: 42, alignment: .trailing)
                    Text("\(session.totals[seat])").font(MJFont.label).foregroundStyle(MJColor.creamHeading).frame(width: 48, alignment: .trailing)
                }
            }
        }.mjCard().frame(maxWidth: 380)
    }
}

struct GameInspectorView: View {
    let session: GameSession
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "State"
    private let tabs = ["State", "Observation", "Events", "Replay"]
    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground(.content)
                VStack(spacing: 12) {
                    Picker("Inspector section", selection: $tab) { ForEach(tabs, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).padding(.horizontal, 16)
                    ScrollView {
                        Group {
                            switch tab {
                            case "State": statePanel
                            case "Observation": codePanel(session.observationText())
                            case "Events": codePanel(session.state.events.map { String(describing: $0) }.joined(separator: "\n\n"))
                            default: codePanel(session.replayText)
                            }
                        }.padding(16)
                    }
                }.padding(.top, 10)
            }
            .navigationTitle("Game inspector").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() }.tint(MJColor.gold) }
                ToolbarItem(placement: .topBarTrailing) { ShareLink(item: tab == "Replay" ? session.replayText : session.observationText()) { Image(systemName: "square.and.arrow.up") }.tint(MJColor.gold).accessibilityLabel("Share inspector export") }
            }
        }
    }
    private var statePanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Seed \(session.seed)").font(MJFont.sheetTitle).foregroundStyle(MJColor.creamHeading)
            InfoRow(name: "Phase", value: String(describing: session.state.phase))
            InfoRow(name: "Current player", value: "\(playerName(session.state.currentPlayer, humanSeat: session.humanSeat)) · \(seatName(session.state.players[session.state.currentPlayer].seatWind))")
            InfoRow(name: "Wall remaining", value: "\(session.state.wallRemaining)")
            InfoRow(name: "Legal mask · true IDs", value: session.legalActions.map { String($0.id) }.joined(separator: ", "))
            if let diagnostic = session.latestBotDiagnostic { InfoRow(name: "Bot", value: diagnostic) }
            Toggle("Reveal opponent hands", isOn: Binding(get: { session.revealOpponents }, set: { session.revealOpponents = $0 }))
                .tint(MJColor.gold).font(MJFont.label).foregroundStyle(MJColor.creamHeading).frame(minHeight: 44)
            SecondaryButton("Restart same seed") { session.restart(seed: session.seed) }
        }.mjCard()
    }
    private func codePanel(_ text: String) -> some View {
        Text(text.isEmpty ? "No data yet." : text).font(.system(.caption, design: .monospaced)).foregroundStyle(MJColor.cream(0.78)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct InfoRow: View {
    let name: String; let value: String
    var body: some View { HStack(alignment: .top) { Text(name).font(MJFont.caption).foregroundStyle(MJColor.cream(0.55)); Spacer(); Text(value).font(MJFont.caption).foregroundStyle(MJColor.creamHeading).multilineTextAlignment(.trailing) }.frame(minHeight: 28) }
}

private func seatName(_ wind: Wind) -> String { ["East", "South", "West", "North"][wind.rawValue] }
private func playerName(_ seat: Int, humanSeat: Int) -> String {
    guard seat != humanSeat else { return "You" }
    return "Bot \((seat - humanSeat + 4) % 4)"
}
