import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData

/// Lane 4 · Learn — the merged "Tiles" screen. One entry replacing the old,
/// redundant "The tiles" primer and "Tile dictionary". A search bar sits at the
/// top: empty shows the friendly primer (every tile tappable → detail sheet, meld
/// types tappable → example sheet); typing shows a grid of matching tiles.
struct TilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: TileSelection?
    @State private var meld: MeldSelection?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "Tiles") { dismiss() }
                searchField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                ScrollView {
                    if query.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Tap any tile to learn more — names, sounds, draw odds, and the hands it feeds.")
                                .font(MJFont.ui(11.5))
                                .foregroundStyle(MJColor.gold(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                            TilesBasics(onTapTile: { selected = TileSelection($0) },
                                        onTapMeld: { meld = MeldSelection($0) })
                        }
                        .padding(20)
                        .padding(.bottom, 100)
                    } else {
                        resultsGrid
                            .padding(20)
                            .padding(.bottom, 100)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selected) { TileDetailSheet(tile: $0.tile) }
        .sheet(item: $meld) { MeldExampleSheet(kind: $0.kind) }
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

    // MARK: Search results

    private var results: [Tile] {
        let q = query.lowercased()
        return Tile.allCanonical.filter { tile in
            let n = MahjongData.name(for: tile)
            return n.english.lowercased().contains(q)
                || n.traditional.contains(query)
                || n.jyutping.lowercased().contains(q)
                || tile.code.lowercased().contains(q)
        }
    }

    @ViewBuilder private var resultsGrid: some View {
        if results.isEmpty {
            Text("No tiles match “\(query)”.")
                .font(MJFont.ui(12))
                .foregroundStyle(MJColor.cream(0.5))
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, tile in
                    Button { selected = TileSelection(tile) } label: {
                        tileCell(tile)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

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
