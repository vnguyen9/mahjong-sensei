import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData

/// The primer content of the merged Tiles screen (`TilesView`) — a friendly,
/// bilingual walk through the three suits, the honors, the bonus flowers/seasons,
/// and how a winning hand is built (4 sets + 1 pair). Every tile is tappable
/// (`onTapTile` → the shared detail sheet) and each meld type is tappable
/// (`onTapMeld` → an example sheet). Content only; the parent supplies chrome/scroll.
struct TilesBasics: View {
    let onTapTile: (Tile) -> Void
    let onTapMeld: (MeldKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A Hong Kong set has 144 tiles. Learn these families and you can read any hand at the table.")
                .font(MJFont.ui(13))
                .foregroundStyle(MJColor.cream(0.65))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            suitsCard
            honorsCard
            bonusCard
            buildingCard
        }
    }

    /// A horizontal row of tappable tile glyphs (each → `onTapTile`).
    private func tappableRow(_ tiles: [Tile], width: CGFloat = 40) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, t in
                Button { onTapTile(t) } label: {
                    MahjongTileView(t, theme: .jade, width: width)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(MahjongData.name(for: t).english))
                .accessibilityHint(Text("Shows tile details"))
            }
        }
    }

    // MARK: Three suits

    private var suitsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Three suits · 三門").eyebrowStyle()
            Text("Numbers 1–9, three suits, four of each. Runs and triplets are built from these.")
                .font(MJFont.ui(11.5))
                .foregroundStyle(MJColor.cream(0.6))
                .fixedSize(horizontal: false, vertical: true)

            suitBlock(name: "Dots", zh: "筒", jyut: "tùhng",
                      note: "Circles of coins — the easiest suit to count.",
                      tiles: (1...9).map { .p($0) })
            suitBlock(name: "Bamboo", zh: "索", jyut: "sok",
                      note: "Sticks of cash — but the 1 is drawn as a bird.",
                      tiles: (1...9).map { .s($0) })
            suitBlock(name: "Characters", zh: "萬", jyut: "maahn",
                      note: "“Ten-thousands” — each carries the 萬 character.",
                      tiles: (1...9).map { .m($0) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mjCard()
    }

    private func suitBlock(name: String, zh: String, jyut: String, note: String, tiles: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(name)
                    .font(MJFont.ui(13, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                Text("\(zh) · \(jyut)")
                    .font(MJFont.serif(12, weight: .regular))
                    .foregroundStyle(MJColor.gold(0.8))
            }
            Text(note)
                .font(MJFont.ui(11))
                .foregroundStyle(MJColor.cream(0.55))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                tappableRow(tiles, width: 40)
                    .padding(.vertical, 2)
            }
        }
    }

    // MARK: Honors

    private var honorsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The honors · 字牌").eyebrowStyle()
            Text("No numbers, no runs — honors only ever score as triplets.")
                .font(MJFont.ui(11.5))
                .foregroundStyle(MJColor.cream(0.6))
                .fixedSize(horizontal: false, vertical: true)

            honorBlock(title: "Winds", zh: "風 · 東南西北",
                       note: "East, South, West, North. One is your seat; one rules the round.",
                       tiles: [.east, .south, .west, .north])
            honorBlock(title: "Dragons", zh: "箭 · 中發白",
                       note: "Red 中, Green 發, White 白. A triplet of any always scores.",
                       tiles: [.redDragon, .greenDragon, .whiteDragon])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mjCard()
    }

    private func honorBlock(title: String, zh: String, note: String, tiles: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(MJFont.ui(13, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                Text(zh)
                    .font(MJFont.serif(12, weight: .regular))
                    .foregroundStyle(MJColor.gold(0.8))
            }
            Text(note)
                .font(MJFont.ui(11))
                .foregroundStyle(MJColor.cream(0.55))
                .fixedSize(horizontal: false, vertical: true)
            tappableRow(tiles, width: 40)
        }
    }

    // MARK: Bonus

    private var bonusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bonus tiles · 花牌").eyebrowStyle()
            Text("Flowers 梅蘭菊竹 and seasons 春夏秋冬. They're never part of a set — you set them aside and each one can add faan on its own.")
                .font(MJFont.ui(11.5))
                .foregroundStyle(MJColor.cream(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            tappableRow([.flower(.plum), .flower(.orchid), .flower(.chrysanthemum), .flower(.bamboo)], width: 40)
            tappableRow([.season(.spring), .season(.summer), .season(.autumn), .season(.winter)], width: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mjCard()
    }

    // MARK: Building a hand

    private var buildingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Building a hand · 食糊").eyebrowStyle()
            Text("A win is 14 tiles: four sets and one pair. A set is a chow, a pung, or a kong. Tap one to see examples.")
                .font(MJFont.ui(11.5))
                .foregroundStyle(MJColor.cream(0.6))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    meldChip(.chow, [.p(2), .p(3), .p(4)], "Chow", "順子", "A run of three")
                    meldChip(.pung, [.s(5), .s(5), .s(5)], "Pung", "刻子", "Three the same")
                    meldChip(.kong, [.east, .east, .east, .east], "Kong", "槓", "Four the same")
                    meldChip(.pair, [.whiteDragon, .whiteDragon], "Pair", "對子", "The “eyes”")
                }
                .padding(.vertical, 2)
            }

            Text("4 sets + 1 pair = a winning shape. What those sets are made of is what earns your faan.")
                .font(MJFont.ui(11.5))
                .foregroundStyle(MJColor.gold(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mjCard()
    }

    private func meldChip(_ kind: MeldKind, _ tiles: [Tile], _ label: String, _ zh: String, _ note: String) -> some View {
        Button { onTapMeld(kind) } label: {
            VStack(spacing: 6) {
                TileRow(tiles, theme: .jade, width: 24, spacing: 2)
                    .frame(height: 34)
                VStack(spacing: 1) {
                    Text("\(label) \(zh)")
                        .font(MJFont.ui(9.5, weight: .semibold))
                        .foregroundStyle(MJColor.creamHeading)
                    Text(note)
                        .font(MJFont.ui(8.5))
                        .foregroundStyle(MJColor.cream(0.55))
                }
            }
            .padding(8)
            .background(MJColor.meldGroupBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows example \(label)s"))
    }
}
