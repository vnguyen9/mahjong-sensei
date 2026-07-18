import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData
import ScoringEngine

/// Identifiable wrapper so a `Tile` can drive `.sheet(item:)`. Keyed on the tile's
/// canonical class index (unique per face).
struct TileSelection: Identifiable {
    let tile: Tile
    var id: Int { tile.classIndex }
    init(_ tile: Tile) { self.tile = tile }
}

/// Shared tile-detail sheet (spec screen 20), presented from both the Learn
/// dictionary and the Scan "What's this?" card. Shows the hero tile, its names and
/// lore, then educational `TileInsight` facts — how many copies are in a set, the
/// draw chance, the pair/run/triplet combinations it can form, and the HK scoring
/// patterns it feeds. A "Show all HK patterns" button expands the sheet (`.medium`
/// → `.large`) to reveal the full faan table.
struct TileDetailSheet: View {
    let tile: Tile

    @State private var detent: PresentationDetent = .medium
    @State private var showAllPatterns = false

    private var insight: TileInsight { TileInsight(tile) }

    var body: some View {
        let name = MahjongData.name(for: tile)
        return ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetGrabber()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(name)

                        if !name.note.isEmpty {
                            Text(name.note)
                                .font(MJFont.ui(13))
                                .foregroundStyle(MJColor.cream(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(3)
                        }

                        HStack(spacing: 8) {
                            MJTag(name.category.rawValue, kind: .detail)
                            if tile.isTerminal { MJTag("Terminal", kind: .detail) }
                            Spacer()
                        }

                        Divider().overlay(MJColor.gold(0.12))

                        setSection
                        combinationsSection
                        patternsSection
                    }
                    .padding(20)
                    .padding(.bottom, 28)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)   // the card draws its own SheetGrabber
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    private func header(_ name: TileName) -> some View {
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
    }

    // MARK: In a set

    private var setSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("In a set")
            HStack(spacing: 18) {
                stat("×\(insight.copiesInSet)", "copies in a set")
                Divider().frame(height: 34).overlay(MJColor.gold(0.15))
                stat(TileInsight.percent(insight.drawChance), "of a fresh draw")
                Spacer(minLength: 0)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(MJFont.serif(21, weight: .bold))
                .foregroundStyle(MJColor.lightGold)
            Text(label)
                .font(MJFont.ui(11))
                .foregroundStyle(MJColor.cream(0.55))
        }
    }

    // MARK: Combinations

    private var combinationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Combinations")
            if insight.groups.isEmpty {
                Text("Set aside — a bonus tile scores faan on its own and is never part of a run or triplet.")
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(insight.groups) { GroupRow(group: $0) }
                Text("% under each tile = chance to draw that copy from a fresh set (each extra copy is rarer). “finish” = chance to complete the set over a full hand (~17 draws).")
                    .font(MJFont.ui(10))
                    .foregroundStyle(MJColor.cream(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Patterns

    private var patternsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showAllPatterns {
                fullPatternList
            } else if !insight.notableFaan.isEmpty {
                sectionTitle("Notable hands")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(insight.notableFaan, id: \.self) { cat in
                        NotableHandRow(category: cat, example: insight.example(for: cat))
                    }
                }
                expandButton
            } else {
                // Bonus tiles feed no structural hands — still let you browse the table.
                expandButton
            }
        }
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showAllPatterns = true
                detent = .large
            }
        } label: {
            HStack(spacing: 5) {
                Text("Show all HK patterns")
                    .font(MJFont.ui(12, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(MJColor.gold)
            .padding(.top, 2)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Expands the sheet to list every Hong Kong scoring pattern")
    }

    private var fullPatternList: some View {
        VStack(alignment: .leading, spacing: 14) {
            patternGroup("Can appear in", categories(where: { insight.applies($0) }), dimmed: false)
            patternGroup("Situational (any hand)",
                         categories(where: { TileInsight.situational.contains($0) }), dimmed: true)
            patternGroup("Other patterns",
                         categories(where: { !insight.applies($0) && !TileInsight.situational.contains($0) }),
                         dimmed: true)
        }
    }

    private func categories(where predicate: (FaanCategory) -> Bool) -> [FaanCategory] {
        FaanCategory.allCases.filter(predicate)
    }

    @ViewBuilder
    private func patternGroup(_ title: String, _ cats: [FaanCategory], dimmed: Bool) -> some View {
        if !cats.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(title)
                ForEach(cats, id: \.self) { patternRow($0, dimmed: dimmed) }
            }
        }
    }

    private func patternRow(_ cat: FaanCategory, dimmed: Bool) -> some View {
        HStack(spacing: 10) {
            Text(cat.traditionalChineseName)
                .font(MJFont.serif(14, weight: .bold))
                .foregroundStyle(dimmed ? MJColor.cream(0.42) : MJColor.gold)
                .frame(width: 56, alignment: .leading)
            Text(cat.englishName)
                .font(MJFont.ui(12))
                .foregroundStyle(dimmed ? MJColor.cream(0.42) : MJColor.cream(0.82))
            Spacer(minLength: 0)
            if cat.isLimitHand {
                Text("Limit")
                    .font(MJFont.ui(9.5, weight: .semibold))
                    .foregroundStyle(MJColor.gold(dimmed ? 0.4 : 0.85))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(MJColor.gold(dimmed ? 0.2 : 0.4), lineWidth: 1))
            }
        }
    }

    // MARK: Shared bits

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(MJFont.ui(11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(MJColor.gold(0.9))
    }
}

/// One combination row: the group's mini glyphs, its name, what's still needed, and
/// two fresh-set odds — the chance to *complete* it over a hand (the telling number,
/// so a pair reads easier than a triplet) and the per-draw chance a draw helps.
private struct GroupRow: View {
    let group: TileGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.kind.rawValue)
                    .font(MJFont.ui(14, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                Text("· need \(group.moreNeeded) more")
                    .font(MJFont.ui(11))
                    .foregroundStyle(MJColor.cream(0.5))
                Spacer(minLength: 0)
                Text(TileInsight.percent(group.completionChance))
                    .font(MJFont.ui(13, weight: .bold))
                    .foregroundStyle(MJColor.gold)
                Text("finish")
                    .font(MJFont.ui(9))
                    .foregroundStyle(MJColor.cream(0.4))
            }
            HStack(spacing: 8) {
                ForEach(Array(group.tiles.enumerated()), id: \.offset) { i, t in
                    tileCell(t, chance: group.perTileOdds[i])
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private func tileCell(_ tile: Tile, chance: Double) -> some View {
        VStack(spacing: 3) {
            MahjongTileView(tile, theme: .ivory, width: 30, showsBadge: false)
            Text(TileInsight.percent(chance))
                .font(MJFont.ui(9, weight: .medium))
                .foregroundStyle(MJColor.gold(0.9))
        }
    }
}

/// A notable-hand row: the pattern's 繁中 + English name and a short example layout
/// (mini tiles) that illustrates the shape, featuring this tile where it belongs.
private struct NotableHandRow: View {
    let category: FaanCategory
    let example: [Tile]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(category.traditionalChineseName)
                    .font(MJFont.serif(15, weight: .bold))
                    .foregroundStyle(MJColor.gold)
                Text(category.englishName)
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.78))
                Spacer(minLength: 0)
                if category.isLimitHand {
                    Text("Limit")
                        .font(MJFont.ui(9.5, weight: .semibold))
                        .foregroundStyle(MJColor.gold(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(MJColor.gold(0.4), lineWidth: 1))
                }
            }
            if !example.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(example.enumerated()), id: \.offset) { _, t in
                        MahjongTileView(t, theme: .ivory, width: 20, showsBadge: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MJColor.cardRaised))
    }
}
