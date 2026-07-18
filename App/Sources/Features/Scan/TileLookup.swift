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
        return HStack(spacing: 14) {
            MahjongTileView(tile, theme: .ivory, width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(name.english)
                    .font(MJFont.serif(18, weight: .bold)).foregroundStyle(MJColor.creamHeading)
                HStack(spacing: 8) {
                    Text(name.traditional).font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.gold)
                    Text(name.jyutping).font(MJFont.ui(12)).foregroundStyle(MJColor.cream(0.6))
                }
                if !name.note.isEmpty {
                    Text(name.note)
                        .font(MJFont.ui(10.5)).foregroundStyle(MJColor.cream(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
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
