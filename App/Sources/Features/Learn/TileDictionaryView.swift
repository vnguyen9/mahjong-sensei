import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData

/// Lane 4 · Learn — the searchable 42-tile dictionary (spec screen 19) and the
/// tap-through tile detail sheet (spec screen 20). Suit filter chips scope the
/// grid; typing searches names, sounds, and codes across every face.
struct TileDictionaryView: View {
    @Environment(\.dismiss) private var dismiss

    private enum SuitFilter: String, CaseIterable {
        case dots = "Dots", bamboo = "Bamboo", chars = "Chars", honors = "字"
    }
    @State private var filter: SuitFilter = .dots
    @State private var query = ""
    @State private var selected: SelectedTile?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "Dictionary 字典") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        searchField

                        if query.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(SuitFilter.allCases, id: \.self) { f in
                                    FilterChip(f.rawValue, active: f == filter) { filter = f }
                                }
                            }
                        }

                        if shownTiles.isEmpty {
                            Text("No tiles match “\(query)”.")
                                .font(MJFont.ui(12))
                                .foregroundStyle(MJColor.cream(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(Array(shownTiles.enumerated()), id: \.offset) { _, tile in
                                    Button { selected = SelectedTile(tile: tile) } label: {
                                        tileCell(tile)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selected) { sel in
            TileDetailSheet(tile: sel.tile)
                .presentationDetents([.medium])
                .presentationBackground(.clear)
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MJColor.cream(0.5))
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search 42 tiles")
                        .foregroundStyle(MJColor.cream(0.5))
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(MJColor.cream)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MJColor.cream(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(MJFont.ui(13))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Data

    private var shownTiles: [Tile] {
        if query.isEmpty {
            switch filter {
            case .dots:   return (1...9).map { .p($0) }
            case .bamboo: return (1...9).map { .s($0) }
            case .chars:  return (1...9).map { .m($0) }
            case .honors: return honorsAndBonus
            }
        }
        let q = query.lowercased()
        return Tile.allCanonical.filter { tile in
            let n = MahjongData.name(for: tile)
            return n.english.lowercased().contains(q)
                || n.traditional.contains(query)
                || n.jyutping.lowercased().contains(q)
                || tile.code.lowercased().contains(q)
        }
    }

    private var honorsAndBonus: [Tile] {
        [.east, .south, .west, .north, .redDragon, .greenDragon, .whiteDragon,
         .flower(.plum), .flower(.orchid), .flower(.chrysanthemum), .flower(.bamboo),
         .season(.spring), .season(.summer), .season(.autumn), .season(.winter)]
    }

    // MARK: Cell

    private func tileCell(_ tile: Tile) -> some View {
        VStack(spacing: 8) {
            MahjongTileView(tile, theme: .jade, width: 46)
            Text(shortLabel(tile))
                .font(MJFont.ui(10.5, weight: .medium))
                .foregroundStyle(MJColor.cream(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .mjCard(cornerRadius: 14, padding: 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(MahjongData.name(for: tile).english))
        .accessibilityHint(Text("Shows tile details"))
    }

    private func shortLabel(_ tile: Tile) -> String {
        switch tile {
        case let .suited(.dots, r):       return "\(r) Dot"
        case let .suited(.bamboo, r):     return "\(r) Bam"
        case let .suited(.characters, r): return "\(r) Char"
        case .wind(.east):    return "East"
        case .wind(.south):   return "South"
        case .wind(.west):    return "West"
        case .wind(.north):   return "North"
        case .dragon(.red):   return "Red"
        case .dragon(.green): return "Green"
        case .dragon(.white): return "White"
        case .flower(.plum):          return "Plum"
        case .flower(.orchid):        return "Orchid"
        case .flower(.chrysanthemum): return "Chrys."
        case .flower(.bamboo):        return "Bamboo"
        case .season(.spring): return "Spring"
        case .season(.summer): return "Summer"
        case .season(.autumn): return "Autumn"
        case .season(.winter): return "Winter"
        }
    }
}

/// Identifiable wrapper so a tapped `Tile` can drive `.sheet(item:)`.
private struct SelectedTile: Identifiable {
    let id = UUID()
    let tile: Tile
}

/// Spec screen 20 — bottom-sheet tile detail: hero tile, EN name, 繁中 · jyutping
/// (gold), the lore note, and category / terminal tags.
private struct TileDetailSheet: View {
    let tile: Tile

    var body: some View {
        let name = MahjongData.name(for: tile)
        return ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SheetGrabber()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)

                    HStack(alignment: .center, spacing: 16) {
                        MahjongTileView(tile, theme: .jade, width: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name.english)
                                .font(MJFont.serif(19, weight: .bold))
                                .foregroundStyle(MJColor.creamHeading)
                            Text("\(name.traditional) · \(name.jyutping)")
                                .font(MJFont.ui(13, weight: .medium))
                                .foregroundStyle(MJColor.gold)
                        }
                        Spacer(minLength: 0)
                    }

                    if !name.note.isEmpty {
                        Text(name.note)
                            .font(MJFont.ui(13))
                            .foregroundStyle(MJColor.cream(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }

                    HStack(spacing: 8) {
                        MJTag(name.category.rawValue, kind: .detail)
                        if tile.isTerminal {
                            MJTag("Terminal", kind: .detail)
                        }
                        Spacer()
                    }
                }
                .padding(20)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
    }
}
