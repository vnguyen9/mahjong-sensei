import SwiftUI
import DesignSystem
import MahjongCore
import MahjongData
import ScoringEngine

/// Contextual tile dictionary for the practice table. Unlike the generic tile
/// dictionary, its counts are limited to what the human player can see.
struct GameTileLearningSheet: View {
    let context: GameTileInsightContext

    @State private var detent: PresentationDetent = .medium
    @State private var coachSummary: GameTileCoachSummary?
    @State private var isLoadingCoach = false

    private var name: TileName { MahjongData.name(for: context.tile) }
    private var educational: TileInsight { TileInsight(context.tile) }

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetGrabber()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        tableStats
                        if context.isHumanHeld { coachSection }
                        if !context.legalOfferedActions.isEmpty { offeredActions }
                        educationalSection
                    }
                    .padding(20)
                    .padding(.bottom, 30)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .task(id: context.id) {
            coachSummary = nil
            guard context.isHumanHeld else { return }
            isLoadingCoach = true
            let summary = await GameLearningAdvisor.summary(for: context)
            guard !Task.isCancelled else { return }
            coachSummary = summary
            isLoadingCoach = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                MahjongTileView(context.tile, width: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.english)
                        .font(MJFont.serif(20, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)
                    Text("\(name.traditional) · \(name.jyutping)")
                        .font(MJFont.ui(13, weight: .medium))
                        .foregroundStyle(MJColor.gold)
                    Text(locationDescription)
                        .font(MJFont.ui(11, weight: .semibold))
                        .foregroundStyle(MJColor.cream(0.58))
                }
                Spacer(minLength: 0)
            }
            if !name.note.isEmpty {
                Text(name.note)
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tableStats: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Visible at this table")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    stat("\(context.humanHeldCopies)", "in your hand")
                    divider
                    stat("\(context.publiclyVisibleCopies)", "face-up")
                    divider
                    stat("\(context.remainingUnseenCopies)", "unseen")
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        stat("\(context.humanHeldCopies)", "in your hand")
                        divider
                        stat("\(context.publiclyVisibleCopies)", "face-up")
                    }
                    stat("\(context.remainingUnseenCopies)", "unseen")
                }
            }
            if let frequency = context.estimatedUnseenPercent {
                Text("Estimated next unseen base tile: \(frequency)")
                    .font(MJFont.ui(12, weight: .medium))
                    .foregroundStyle(MJColor.lightGold)
                Text("Estimate among \(context.unseenBaseTileCount) unseen base tiles. An unseen copy may be in the wall or another player’s concealed hand.")
                    .font(MJFont.ui(10))
                    .foregroundStyle(MJColor.cream(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            } else if context.tile.isBonus {
                Text("Bonus tiles are replacement draws, so this sheet does not estimate a next-draw frequency.")
                    .font(MJFont.ui(10))
                    .foregroundStyle(MJColor.cream(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(context.wallRemaining) tiles remain · Your wind \(windName(context.seatWind)) · Round wind \(windName(context.prevailingWind))")
                .font(MJFont.ui(11))
                .foregroundStyle(MJColor.cream(0.58))
        }
        .padding(14)
        .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var coachSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Discard coaching")
            if isLoadingCoach {
                HStack(spacing: 10) {
                    ProgressView().tint(MJColor.gold)
                    Text("Checking your public hand…")
                        .font(MJFont.ui(12))
                        .foregroundStyle(MJColor.cream(0.62))
                }
                .frame(minHeight: 44)
            } else if let coachSummary {
                HStack(spacing: 14) {
                    stat(coachRank(coachSummary), "discard rank")
                    divider
                    stat("\(coachSummary.shanten)", "shanten")
                    divider
                    stat("\(coachSummary.outs)", "live outs")
                    Spacer(minLength: 0)
                }
                if let odds = coachSummary.nextDrawOdds {
                    Text("Next-draw estimate \(TileInsight.percent(odds))")
                        .font(MJFont.ui(11, weight: .medium))
                        .foregroundStyle(MJColor.lightGold)
                }
                if coachSummary.reasons.isEmpty {
                    Text(coachSummary.isRecommended ? "This is the current top discard by the public-hand advisor." : "This tile has no discard recommendation in the current phase.")
                        .font(MJFont.ui(11))
                        .foregroundStyle(MJColor.cream(0.58))
                } else {
                    ForEach(Array(coachSummary.reasons.prefix(2).enumerated()), id: \.offset) { _, reason in
                        Text(reason.englishText)
                            .font(MJFont.ui(11))
                            .foregroundStyle(MJColor.cream(0.70))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(MJColor.gold(0.10), in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var offeredActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Legal response")
            Text("These are the responses currently legal for this offered tile.")
                .font(MJFont.ui(11))
                .foregroundStyle(MJColor.cream(0.58))
                GameInsightFlowLayout(spacing: 7) {
                ForEach(context.legalOfferedActions) { action in
                    Text(action.title)
                        .font(MJFont.ui(12, weight: .semibold))
                        .foregroundStyle(MJColor.gold)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(MJColor.gold(0.12), in: Capsule())
                        .accessibilityLabel("Legal action: \(action.title)")
                }
            }
        }
        .padding(14)
        .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var educationalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Tile patterns")
            if educational.groups.isEmpty {
                Text("Set aside — this bonus tile scores on its own and is not part of a run or triplet.")
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.62))
            } else {
                ForEach(educational.groups) { group in
                    HStack(spacing: 8) {
                        Text(group.kind.rawValue)
                            .font(MJFont.ui(13, weight: .semibold))
                            .foregroundStyle(MJColor.creamHeading)
                            .frame(width: 50, alignment: .leading)
                        HStack(spacing: 3) {
                            ForEach(Array(group.tiles.enumerated()), id: \.offset) { _, tile in
                                MahjongTileView(tile, width: 23, showsBadge: false)
                            }
                        }
                        Spacer(minLength: 0)
                        Text("need \(group.moreNeeded)")
                            .font(MJFont.ui(10))
                            .foregroundStyle(MJColor.cream(0.48))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !educational.notableFaan.isEmpty {
                Divider().overlay(MJColor.gold(0.14))
                Text("HK pattern examples")
                    .font(MJFont.ui(12, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                ForEach(educational.notableFaan, id: \.self) { category in
                    Text("\(category.traditionalChineseName) · \(category.englishName)")
                        .font(MJFont.ui(11))
                        .foregroundStyle(MJColor.cream(0.70))
                }
            }
        }
        .padding(14)
        .background(MJColor.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divider: some View {
        Divider().frame(height: 34).overlay(MJColor.gold(0.15))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(MJFont.serif(20, weight: .bold)).foregroundStyle(MJColor.lightGold)
            Text(label).font(MJFont.ui(10)).foregroundStyle(MJColor.cream(0.52))
        }
    }

    private func coachRank(_ summary: GameTileCoachSummary) -> String {
        guard let rank = summary.rank else { return "—" }
        return summary.isRecommended ? "#1" : "#\(rank)"
    }

    private var locationDescription: String {
        switch context.origin {
        case .humanHand: return "Your concealed hand"
        case let .river(ownerSeat): return "Seat \(ownerSeat + 1) discard river"
        case let .meld(ownerSeat): return "Seat \(ownerSeat + 1) exposed meld"
        case let .flower(ownerSeat): return "Seat \(ownerSeat + 1) bonus tray"
        case let .offered(ownerSeat, _): return "Offered by seat \(ownerSeat + 1)"
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(MJFont.ui(11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(MJColor.gold(0.9))
    }
}

/// A tiny wrapping layout for non-interactive response chips. Kept here rather
/// than in the table view so integration only needs to present one sheet type.
private struct GameInsightFlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + (x > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private func windName(_ wind: Wind) -> String {
    ["East", "South", "West", "North"][wind.rawValue]
}
