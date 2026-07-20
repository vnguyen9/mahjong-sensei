import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData
import ScoringEngine

/// Tracker tile drawer — What’s-this chrome with compact same-row Table/Hand
/// steppers that commit live (no Apply).
struct TrackerTileSheet: View {
    let tile: Tile
    let tracker: TrackerSession

    @State private var detent: PresentationDetent = .medium

    private var tableCount: Int { tracker.tableSeen(tile) }
    private var handCopies: Int { tracker.handCount(tile) }

    private var insight: TrackerLiveInsight {
        TrackerLiveInsight(tile: tile, draftSeen: tableCount, hand: tracker.hand,
                           seenHistogram: tracker.seenHistogram)
    }

    private var educational: TileInsight { TileInsight(tile) }

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
                        dualCountRow
                        liveSetSection
                        combinationsSection
                        notableSection
                    }
                    .padding(20)
                    .padding(.bottom, 28)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private func header(_ name: TileName) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            HStack(spacing: 8) {
                switch tile {
                case .wind:
                    MJTag("Wind", kind: .detail)
                case .dragon:
                    MJTag("Dragon", kind: .detail)
                default:
                    EmptyView()
                }
                if tile.isTerminal { MJTag("Terminal", kind: .detail) }
                Spacer(minLength: 0)
            }
            if !name.note.isEmpty {
                Text(name.note)
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Dual steppers (same row)

    private var dualCountRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Counts")
            HStack(spacing: 12) {
                countCluster(label: "Table", seen: tableCount,
                             canMinus: tableCount > 0,
                             canPlus: tableCount + handCopies < 4,
                             onMinus: { tracker.setCount(classIndex: tile.classIndex, count: tableCount - 1) },
                             onPlus: { tracker.setCount(classIndex: tile.classIndex, count: tableCount + 1) })
                Divider().frame(height: 40).overlay(MJColor.gold(0.15))
                countCluster(label: "Hand", seen: handCopies,
                             canMinus: handCopies > 0,
                             canPlus: tableCount + handCopies < 4
                                && tracker.hand.count < TrackerSession.maxHandSize,
                             onMinus: { tracker.setHandCount(classIndex: tile.classIndex, count: handCopies - 1) },
                             onPlus: { tracker.setHandCount(classIndex: tile.classIndex, count: handCopies + 1) })
            }
            Text("\(insight.liveCopies) live in wall")
                .font(MJFont.ui(12))
                .foregroundStyle(MJColor.cream(0.65))
        }
    }

    private func countCluster(label: String, seen: Int, canMinus: Bool, canPlus: Bool,
                              onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(MJFont.ui(10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(MJColor.gold(0.85))
            HStack(spacing: 8) {
                stepButton("minus", enabled: canMinus, action: onMinus)
                SeenPips(seen: seen, scale: 1.6)
                stepButton("plus", enabled: canPlus, action: onPlus)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? MJColor.gold : MJColor.cream(0.25))
                .frame(width: 32, height: 32)
                .background(MJColor.gold(0.1), in: Circle())
                .overlay { Circle().strokeBorder(MJColor.gold(enabled ? 0.35 : 0.12), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Live set

    private var liveSetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Still live")
            HStack(spacing: 18) {
                stat("\(insight.liveCopies) of 4", "copies left")
                Divider().frame(height: 34).overlay(MJColor.gold(0.15))
                stat(TileInsight.percent(insight.drawChance), "next-draw odds")
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                feasibilityTag(insight.pungPossible ? "Pung possible" : "Pung gone", ok: insight.pungPossible)
                feasibilityTag(insight.kongPossible ? "Kong possible" : "Kong gone", ok: insight.kongPossible)
            }
        }
    }

    private func feasibilityTag(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(MJFont.ui(11, weight: .semibold))
            .foregroundStyle(ok ? MJColor.gold : MJColor.cream(0.45))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(ok ? MJColor.gold(0.12) : Color.white.opacity(0.06)))
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
            if insight.combos.isEmpty {
                Text("Bonus tiles aren’t part of runs or triplets.")
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.6))
            } else {
                ForEach(insight.combos) { combo in
                    comboRow(combo)
                }
                Text("Finish % = chance to complete this set over ~\(TileInsight.drawsPerHand) draws from the live wall.")
                    .font(MJFont.ui(10))
                    .foregroundStyle(MJColor.cream(0.4))
                    .padding(.top, 2)
            }
        }
    }

    private func comboRow(_ combo: TrackerLiveInsight.Combo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(combo.kind.rawValue)
                    .font(MJFont.ui(14, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                Text("· need \(combo.moreNeeded) more")
                    .font(MJFont.ui(11))
                    .foregroundStyle(MJColor.cream(0.5))
                Spacer(minLength: 0)
                Text(TileInsight.percent(combo.finishChance))
                    .font(MJFont.ui(13, weight: .bold))
                    .foregroundStyle(MJColor.gold)
                Text("finish")
                    .font(MJFont.ui(9))
                    .foregroundStyle(MJColor.cream(0.4))
            }
            HStack(spacing: 6) {
                ForEach(Array(combo.tiles.enumerated()), id: \.offset) { _, t in
                    MahjongTileView(t, theme: .ivory, width: 28, showsBadge: false)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Notable

    private var notableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Pattern examples")
            Text("Shapes this tile can appear in — not live odds.")
                .font(MJFont.ui(10))
                .foregroundStyle(MJColor.cream(0.4))
            if educational.notableFaan.isEmpty {
                Text("No structural patterns for bonus tiles.")
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.55))
            } else {
                ForEach(educational.notableFaan, id: \.self) { cat in
                    notableRow(cat, example: educational.example(for: cat))
                }
            }
        }
    }

    private func notableRow(_ category: FaanCategory, example: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(category.traditionalChineseName)
                    .font(MJFont.serif(15, weight: .bold))
                    .foregroundStyle(MJColor.gold)
                Text(category.englishName)
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.78))
                Spacer(minLength: 0)
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

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(MJFont.ui(11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(MJColor.gold(0.9))
    }
}
