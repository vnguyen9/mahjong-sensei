import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData

/// The "AR" cue for What's-this mode: a gold outline drawn over the live preview
/// at the identified tile's on-screen position. `rect` is in global coordinates
/// (from `AspectFillMapping.previewRect(ofNormalized:…)`).
struct LookupHighlight: View {
    let rect: CGRect

    var body: some View {
        Color.clear
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MJColor.gold, lineWidth: 2.5)
                    .frame(width: rect.width, height: rect.height)
                    .shadow(color: MJColor.gold(0.6), radius: 6)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }
}

/// Bottom card for What's-this mode: shows the identified tile large with its
/// name / romanization / lore, or a "point at a tile" prompt while searching.
struct LookupCard: View {
    let tile: Tile?

    var body: some View {
        Group {
            if let tile {
                identified(tile)
            } else {
                searching
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x0F342B, alpha: 0.5))
        }
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(MJColor.gold(0.16), lineWidth: 1) }
    }

    private func identified(_ tile: Tile) -> some View {
        let name = MahjongData.name(for: tile)
        let insight = TileInsight(tile)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 14) {
                MahjongTileView(tile, theme: .ivory, width: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.english)
                        .font(MJFont.serif(18, weight: .bold)).foregroundStyle(MJColor.creamHeading)
                    HStack(spacing: 8) {
                        Text(name.traditional).font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.gold)
                        Text(name.jyutping).font(MJFont.ui(12)).foregroundStyle(MJColor.cream(0.6))
                    }
                    Text("×\(insight.copiesInSet) in set · \(TileInsight.percent(insight.drawChance)) draw")
                        .font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.55))
                }
                Spacer(minLength: 0)
                detailsCue
            }

            if !insight.groups.isEmpty {
                Divider().overlay(MJColor.gold(0.10))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(insight.groups) { LookupComboChip(group: $0) }
                }
            }
        }
    }

    /// The trailing "Details ›" affordance hinting the card opens the full sheet.
    private var detailsCue: some View {
        HStack(spacing: 3) {
            Text("Details").font(MJFont.ui(10, weight: .semibold))
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(MJColor.gold)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(MJColor.gold(0.12)))
    }

    private var searching: some View {
        HStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(MJColor.gold)
            Text("Point at a tile to identify it")
                .font(MJFont.ui(13, weight: .medium)).foregroundStyle(MJColor.cream(0.8))
            Spacer(minLength: 0)
        }
    }
}

/// A compact combination cell for the lookup card: the group's mini glyphs with a
/// "kind · odds" caption. Fuller detail (copies needed, notable hands) lives in the sheet.
private struct LookupComboChip: View {
    let group: TileGroup

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                ForEach(Array(group.tiles.enumerated()), id: \.offset) { _, t in
                    MahjongTileView(t, theme: .ivory, width: 16, showsBadge: false)
                }
            }
            Text("\(group.kind.rawValue) · \(TileInsight.percent(group.completionChance))")
                .font(MJFont.ui(9, weight: .medium))
                .foregroundStyle(MJColor.cream(0.6))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MJColor.cardRaised))
    }
}
