import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData

/// Lane 2 · Check & correct (spec screen 7). The reliability gate — nothing is
/// scored until it passes here. Tap a tile to open a suit-scoped picker.
struct CorrectView: View {
    @Environment(ScanCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?
    @State private var resolved: Set<Int> = []

    private var session: ScanSession { coordinator.session }

    private struct EditTarget: Identifiable { let index: Int; var id: Int { index } }

    private var flagged: Set<Int> {
        Set(session.recognized.tiles.enumerated().filter { $0.element.isLowConfidence }.map(\.offset))
            .subtracting(resolved)
    }

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                header
                Text("Tap any tile to correct it.")
                    .font(MJFont.ui(13))
                    .foregroundStyle(MJColor.cream(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 4)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(rows, id: \.self) { row in
                            HStack(spacing: 8) {
                                ForEach(row, id: \.self) { i in trayTile(i) }
                            }
                        }
                    }
                    .padding(20)
                }

                GoldButton("Looks right →") { coordinator.push(.context) }
                    .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editing) { target in
            CorrectionPicker(current: session.tiles[target.index]) { replacement in
                session.tiles[target.index] = replacement
                resolved.insert(target.index)
                editing = nil
            }
            .presentationDetents([.height(320)])
            .presentationBackground(.clear)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(MJFont.ui(14, weight: .medium)).foregroundStyle(MJColor.gold)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Check your hand").font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.creamHeading)
            Spacer()
            if flagged.isEmpty {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MJColor.jadeAccent).frame(width: 44, alignment: .trailing)
            } else {
                WarningPill("\(flagged.count) to fix")
            }
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    private var rows: [[Int]] {
        stride(from: 0, to: session.tiles.count, by: 7).map { Array($0..<min($0 + 7, session.tiles.count)) }
    }

    private func trayTile(_ i: Int) -> some View {
        Button { editing = EditTarget(index: i) } label: {
            MahjongTileView(session.tiles[i], theme: .jade, width: 30)
                .overlay {
                    if flagged.contains(i) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(MJColor.amberLowConf, lineWidth: 2).padding(-3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if flagged.contains(i) {
                        Text("?").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0x1A1A1A))
                            .frame(width: 15, height: 15).background(MJColor.amberLowConf, in: Circle())
                            .offset(x: 6, y: -6)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Suit-scoped tile picker sheet (spec screen 7 bottom sheet).
private struct CorrectionPicker: View {
    let current: Tile
    let onConfirm: (Tile) -> Void
    @State private var selection: Tile

    init(current: Tile, onConfirm: @escaping (Tile) -> Void) {
        self.current = current
        self.onConfirm = onConfirm
        _selection = State(initialValue: current)
    }

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            VStack(spacing: 16) {
                SheetGrabber().padding(.top, 10)
                Text("Replace — \(groupTitle)")
                    .font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.creamHeading)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: gridColumns), spacing: 10) {
                    ForEach(options, id: \.self) { tile in
                        Button { selection = tile } label: {
                            MahjongTileView(tile, theme: .jade, width: 34)
                                .overlay {
                                    if tile == selection {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(MJColor.gold, lineWidth: 2.5).padding(-3)
                                            .shadow(color: MJColor.gold(0.5), radius: 6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)

                GoldButton("Use \(MahjongData.name(for: selection).traditional) · Looks right →") { onConfirm(selection) }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }

    private var groupTitle: String {
        switch current {
        case .suited(.characters, _): return "Characters 萬"
        case .suited(.dots, _):       return "Dots 筒"
        case .suited(.bamboo, _):     return "Bamboo 索"
        case .wind, .dragon:          return "Honors 字"
        case .flower, .season:        return "Bonus 花"
        }
    }

    private var gridColumns: Int { options.count <= 7 ? options.count : (options.count + 1) / 2 }

    private var options: [Tile] {
        switch current {
        case let .suited(suit, _): return (1...9).map { .suited(suit, $0) }
        case .wind, .dragon:       return [.east, .south, .west, .north, .redDragon, .greenDragon, .whiteDragon]
        case .flower, .season:     return [.flower(.plum), .flower(.orchid), .flower(.chrysanthemum), .flower(.bamboo),
                                           .season(.spring), .season(.summer), .season(.autumn), .season(.winter)]
        }
    }
}
