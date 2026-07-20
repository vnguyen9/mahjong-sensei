import SwiftUI
import DesignSystem
import MahjongCore
import MahjongGameEngine

struct GameView: View {
    @State var session: GameSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chowSheet = false
    @State private var forceReactionSheet = false
    @State private var forceResultSheet = false
    @State private var forceInspector = false

    init(session: GameSession, forceReactionSheet: Bool = false, forceResultSheet: Bool = false, forceInspector: Bool = false) {
        _session = State(initialValue: session)
        _forceReactionSheet = State(initialValue: forceReactionSheet)
        _forceResultSheet = State(initialValue: forceResultSheet)
        _forceInspector = State(initialValue: forceInspector)
    }

    var body: some View {
        ZStack {
            ScreenBackground(.live)
            GeometryReader { proxy in
                let compact = proxy.size.width < 390
                VStack(spacing: compact ? 7 : 12) {
                    gameHeader
                    MahjongTableView(session: session, compact: compact)
                        .frame(maxWidth: 760)
                        .frame(maxHeight: .infinity)
                    HumanRack(session: session, compact: compact)
                    actionBar
                }
                .padding(.horizontal, compact ? 10 : 16)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Practice table")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { session.isInspectorPresented = true } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .accessibilityLabel("Open game developer inspector")
            }
        }
        .sheet(isPresented: $session.isInspectorPresented) { GameInspectorView(session: session) }
        .sheet(isPresented: $chowSheet) { ChowChoiceSheet(actions: session.chowActions(), session: session) }
        .sheet(isPresented: Binding(get: { session.isResultPresented || forceResultSheet }, set: { value in session.isResultPresented = value; forceResultSheet = value })) {
            GameResultSheet(session: session)
        }
        .sheet(isPresented: $forceReactionSheet) { ReactionPreviewSheet(session: session) }
        .alert("Game error", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .onAppear { if forceInspector { session.isInspectorPresented = true } }
        .onChange(of: reduceMotion) { _, value in session.instantBots = value || session.instantBots }
    }

    private var gameHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EAST ROUND")
                    .font(MJFont.eyebrow).tracking(1.1)
                    .foregroundStyle(MJColor.gold(0.8))
                Text(session.isBotThinking ? "Opponents are thinking…" : eventText)
                    .font(MJFont.caption)
                    .foregroundStyle(MJColor.cream(0.7))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("WALL")
                    .font(MJFont.eyebrow).tracking(1.1).foregroundStyle(MJColor.gold(0.8))
                Text("\(session.state.wallRemaining)")
                    .font(MJFont.serif(24, weight: .bold)).foregroundStyle(MJColor.creamHeading)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(MJColor.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MJColor.gold(0.18)) }
    }

    private var eventText: String {
        guard let event = session.state.events.last else { return "Your hand is ready" }
        let seat = ["East", "South", "West", "North"][event.seat % 4]
        switch event.kind {
        case .deal:
            return "Tiles dealt"
        case .draw:
            return event.drawKind == .flowerReplacement ? "\(seat) draws a flower replacement" : "\(seat) draws"
        case .flower:
            return "\(seat) reveals a flower"
        case .discard:
            return event.tile.map { "\(seat) discards \($0.code)" } ?? "\(seat) discards"
        case .chow:
            return "\(seat) calls Chow"
        case .pung:
            return "\(seat) calls Pung"
        case .kong, .addedKong, .concealedKong:
            return "\(seat) declares Kong"
        case .pass:
            return "\(seat) passes"
        case .win:
            return "\(seat) wins"
        case .exhaustive:
            return "The wall is exhausted"
        }
    }

    @ViewBuilder private var actionBar: some View {
        let labels = ["Win", "Chow", "Pung", "Kong", "Pass"]
        HStack(spacing: 7) {
            if session.selectedTileID != nil {
                GameActionButton(title: "Discard", prominent: true) { session.discardSelected() }
            }
            ForEach(labels, id: \.self) { title in
                let actions = title == "Chow" ? session.chowActions() : (session.action(named: title).map { [$0] } ?? [])
                if !actions.isEmpty {
                    GameActionButton(title: title, prominent: title == "Win") {
                        if title == "Chow", actions.count > 1 { chowSheet = true }
                        else if let action = actions.first { session.apply(action) }
                    }
                }
            }
            if session.isHumanTurn && session.selectedTileID == nil && session.legalActions.contains(where: { session.label(for: $0) == "Discard" }) {
                Text("Select a tile to discard")
                    .font(MJFont.caption).foregroundStyle(MJColor.cream(0.52))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(minHeight: 46)
    }
}

private struct MahjongTableView: View {
    let session: GameSession
    let compact: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(LinearGradient(colors: [MJColor.jade, MJColor.deepJade], startPoint: .top, endPoint: .bottom))
                    .overlay { RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(MJColor.gold(0.38), lineWidth: 1.5) }
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)

                // Table geometry is relative to the selected human seat, not to
                // absolute East, so every launcher seat keeps the player at bottom.
                opponent(seat: (session.humanSeat + 2) % 4, vertical: false).position(x: side / 2, y: side * 0.115)
                opponent(seat: (session.humanSeat + 3) % 4, vertical: true).position(x: side * 0.11, y: side * 0.46)
                opponent(seat: (session.humanSeat + 1) % 4, vertical: true).position(x: side * 0.89, y: side * 0.46)
                centerRivers(side: side)
                PlayerBadge(player: session.state.players[session.humanSeat], active: session.state.currentActor == session.humanSeat)
                    .position(x: side / 2, y: side * 0.86)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mahjong table. \(session.state.wallRemaining) tiles remain in the wall.")
    }

    private func opponent(seat: Int, vertical: Bool) -> some View {
        let p = session.state.players[seat]
        return VStack(spacing: 4) {
            PlayerBadge(player: p, active: session.state.currentActor == seat)
            OpponentRack(count: p.concealed.count, vertical: vertical, reveal: session.revealOpponents, tiles: p.concealed)
            MeldSummary(player: p)
        }
    }

    private func centerRivers(side: CGFloat) -> some View {
        VStack(spacing: 7) {
            Text("EAST · \(session.state.wallRemaining) LEFT")
                .font(MJFont.ui(10, weight: .bold)).foregroundStyle(MJColor.gold(0.85))
            VStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { seat in
                    HStack(spacing: 2) {
                        Text(["E", "S", "W", "N"][seat]).font(MJFont.ui(8, weight: .bold)).foregroundStyle(MJColor.gold(0.70)).frame(width: 9)
                        ForEach(session.state.river[seat].suffix(5), id: \.id) { tile in
                            MahjongTileView(tile.tile, theme: .ivory, width: max(16, side * 0.060), showsBadge: false)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(7)
            .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !session.state.players.flatMap(\.melds).isEmpty {
                HStack(spacing: 3) {
                    ForEach(session.state.players.flatMap(\.melds).flatMap(\.tiles).prefix(12), id: \.id) { tile in
                        MahjongTileView(tile.tile, theme: .ivory, width: max(15, side * 0.058), showsBadge: false)
                    }
                }
                .padding(5)
                .background(.black.opacity(0.16), in: Capsule())
                .accessibilityLabel("Exposed melds")
            }
        }
        .frame(width: side * 0.52)
    }
}

private struct PlayerBadge: View {
    let player: GamePlayer
    let active: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(active ? MJColor.gold : MJColor.cream(0.30)).frame(width: 7, height: 7)
            Text("\(windName(player.id)) · \(player.score)")
                .font(MJFont.ui(10, weight: .bold)).foregroundStyle(active ? MJColor.creamHeading : MJColor.cream(0.60))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.28), in: Capsule())
    }
    private func windName(_ seat: Int) -> String { ["EAST", "SOUTH", "WEST", "NORTH"][seat % 4] }
}

private struct OpponentRack: View {
    let count: Int; let vertical: Bool; let reveal: Bool; let tiles: [TileInstance]
    var body: some View {
        Group {
            if vertical { VStack(spacing: -5) { backs } }
            else { HStack(spacing: -5) { backs } }
        }
    }
    @ViewBuilder private var backs: some View {
        ForEach(Array(tiles.prefix(14).enumerated()), id: \.element.id) { _, tile in
            if reveal { MahjongTileView(tile.tile, theme: .ivory, width: 19, showsBadge: false) }
            else { TileBack(width: 19) }
        }
    }
}

private struct MeldSummary: View {
    let player: GamePlayer
    var body: some View {
        if !player.melds.isEmpty || !player.flowers.isEmpty {
            HStack(spacing: 2) {
                ForEach(player.melds.flatMap(\.tiles).prefix(6), id: \.id) { tile in
                    MahjongTileView(tile.tile, theme: .ivory, width: 14, showsBadge: false)
                }
                ForEach(player.flowers.prefix(3), id: \.id) { tile in
                    Image(systemName: "camera.macro").font(.system(size: 9, weight: .bold)).foregroundStyle(MJColor.gold)
                }
            }
            .padding(3).background(.black.opacity(0.20), in: Capsule())
            .accessibilityLabel("\(player.melds.count) exposed melds and \(player.flowers.count) flowers")
        }
    }
}

private struct TileBack: View {
    let width: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.18, style: .continuous)
            .fill(LinearGradient(colors: [MJColor.gold(0.72), MJColor.jade], startPoint: .top, endPoint: .bottom))
            .overlay { RoundedRectangle(cornerRadius: width * 0.18).strokeBorder(MJColor.cream(0.40)) }
            .frame(width: width, height: width * 1.35)
    }
}

private struct HumanRack: View {
    let session: GameSession; let compact: Bool
    var body: some View {
        GeometryReader { geo in
            let tiles = session.humanTiles
            let spacing: CGFloat = compact ? 1 : 2
            let drawnGap: CGFloat = tiles.contains(where: { session.state.lastDrawInstance?.id == $0.id }) ? 7 : 0
            let available = geo.size.width - 16 - drawnGap - spacing * CGFloat(max(tiles.count - 1, 0))
            let tileWidth = min(compact ? 28 : 32, max(22, available / CGFloat(max(tiles.count, 1))))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(tiles, id: \.id) { tile in
                    let selected = session.selectedTileID == tile.id
                    Button { session.select(tile) } label: {
                        MahjongTileView(tile.tile, theme: .ivory, width: tileWidth, showsBadge: tileWidth >= 28)
                            .offset(y: selected ? -9 : 0)
                            .padding(.leading, session.state.lastDrawInstance?.id == tile.id ? drawnGap : 0)
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(selected ? MJColor.gold : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.isHumanTurn)
                    .accessibilityLabel("\(tile.tile.code)\(selected ? ", selected" : "")")
                    .accessibilityHint("Double tap to select this tile for discard")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
        }
        .frame(height: compact ? 64 : 76)
        .background(MJColor.sheetGlass.opacity(0.75), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(MJColor.gold(0.24)) }
    }
}

struct GameActionButton: View {
    let title: String; let prominent: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(MJFont.ui(13, weight: .bold)).foregroundStyle(prominent ? MJColor.inkOnGold : MJColor.gold).frame(minWidth: 50).frame(height: 44).padding(.horizontal, 3).background(prominent ? AnyShapeStyle(MJColor.gold) : AnyShapeStyle(MJColor.gold(0.12)), in: RoundedRectangle(cornerRadius: 12)) }
            .buttonStyle(.plain).accessibilityLabel(title)
    }
}
