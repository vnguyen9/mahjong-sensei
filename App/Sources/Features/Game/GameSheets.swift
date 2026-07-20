import SwiftUI
import DesignSystem
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
                        Button {
                            session.apply(action); dismiss()
                        } label: {
                            HStack { Text("Sequence \((action.chowIndex ?? 0) + 1)"); Spacer(); Image(systemName: "chevron.right") }
                                .font(MJFont.label).foregroundStyle(MJColor.creamHeading).padding(14).frame(minHeight: 48)
                                .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(20)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() }.tint(MJColor.gold) } }
        }
        .presentationDetents([.medium])
    }
}

/// Deterministic screenshot-only reaction treatment; regular play exposes only
/// actions that are actually legal in the engine state.
struct ReactionPreviewSheet: View {
    let session: GameSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill").font(.system(size: 34)).foregroundStyle(MJColor.gold)
            Text("Claim a discard?").font(MJFont.sheetTitle).foregroundStyle(MJColor.creamHeading)
            Text("Screenshot preview of the native reaction controls.").font(MJFont.caption).foregroundStyle(MJColor.cream(0.62))
            HStack { GameActionButton(title: "Pung", prominent: false) {}; GameActionButton(title: "Pass", prominent: false) { dismiss() } }
        }
        .padding(24).frame(maxWidth: .infinity).background(MJColor.sheetGlass)
        .presentationDetents([.height(250)])
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
                            Text("\(result.faan) FAAN").font(MJFont.bigFaan).foregroundStyle(MJColor.lightGold)
                            Text(result.patternBreakdown.map { "\($0.name) · \($0.faan) faan" }.joined(separator: "\n"))
                                .font(MJFont.caption).foregroundStyle(MJColor.cream(0.70)).multilineTextAlignment(.center)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Payments").font(MJFont.label).foregroundStyle(MJColor.creamHeading)
                                ForEach(Array(result.payments.enumerated()), id: \.offset) { index, payment in
                                    HStack { Text(["East", "South", "West", "North"][index]); Spacer(); Text("\(payment >= 0 ? "+" : "")\(payment)") }
                                        .font(MJFont.body).foregroundStyle(payment >= 0 ? MJColor.lightGold : MJColor.cream(0.65))
                                }
                            }.mjCard().frame(maxWidth: 380)
                        } else {
                            Text("4 FAAN").font(MJFont.bigFaan).foregroundStyle(MJColor.lightGold)
                            Text("All Simples · Self draw").font(MJFont.caption).foregroundStyle(MJColor.cream(0.65))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Preview payments").font(MJFont.label).foregroundStyle(MJColor.creamHeading)
                                InfoRow(name: "East", value: "+24")
                                InfoRow(name: "South", value: "−8")
                                InfoRow(name: "West", value: "−8")
                                InfoRow(name: "North", value: "−8")
                            }.mjCard().frame(maxWidth: 380)
                        }
                        GoldButton("New hand") { session.restart(); dismiss() }
                        SecondaryButton("Replay seed") { session.restart(seed: session.seed); dismiss() }
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
        return winner == session.humanSeat ? "You win" : "\(["East", "South", "West", "North"][winner]) wins"
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
            InfoRow(name: "Current player", value: ["East", "South", "West", "North"][session.state.currentPlayer])
            InfoRow(name: "Wall remaining", value: "\(session.state.wallRemaining)")
            InfoRow(name: "Legal action IDs", value: session.legalActions.map { String($0.id) }.joined(separator: ", "))
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
