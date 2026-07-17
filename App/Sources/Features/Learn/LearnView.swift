import SwiftUI
import DesignSystem
import MahjongCore

/// Lane 4 · Learn — first cut of the Tile Dictionary (spec screen 19).
/// The wind explainer + tile-detail sheet attach here next.
struct LearnView: View {
    private enum SuitFilter: String, CaseIterable {
        case dots = "Dots", bamboo = "Bamboo", chars = "Chars", honors = "字"
    }
    @State private var filter: SuitFilter = .dots

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Dictionary 字典")
                        .font(MJFont.serif(24, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)
                        .padding(.top, 8)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(MJColor.cream(0.5))
                        Text("Search 42 tiles").foregroundStyle(MJColor.cream(0.5))
                        Spacer()
                    }
                    .font(MJFont.ui(13))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 8) {
                        ForEach(SuitFilter.allCases, id: \.self) { f in
                            FilterChip(f.rawValue, active: f == filter) { filter = f }
                        }
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                            tileCell(tile)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
        }
    }

    private var tiles: [Tile] {
        switch filter {
        case .dots:   return (1...9).map { .p($0) }
        case .bamboo: return (1...9).map { .s($0) }
        case .chars:  return (1...9).map { .m($0) }
        case .honors: return [.east, .south, .west, .north, .redDragon, .greenDragon, .whiteDragon]
        }
    }

    private func tileCell(_ tile: Tile) -> some View {
        VStack(spacing: 8) {
            MahjongTileView(tile, theme: .jade, width: 46)
            Text(shortLabel(tile))
                .font(MJFont.ui(11, weight: .medium))
                .foregroundStyle(MJColor.cream(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .mjCard(cornerRadius: 14, padding: 0)
    }

    private func shortLabel(_ tile: Tile) -> String {
        switch tile {
        case let .suited(.dots, r):   return "\(r) Dot"
        case let .suited(.bamboo, r): return "\(r) Bam"
        case let .suited(.characters, r): return "\(r) Char"
        case .wind(.east): return "East"
        case .wind(.south): return "South"
        case .wind(.west): return "West"
        case .wind(.north): return "North"
        case .dragon(.red): return "Red"
        case .dragon(.green): return "Green"
        case .dragon(.white): return "White"
        default: return tile.code
        }
    }
}
