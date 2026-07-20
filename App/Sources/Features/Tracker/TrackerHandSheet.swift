import SwiftUI
import UIKit
import DesignSystem
import MahjongCore
import MahjongData
import EfficiencyEngine
import CoachEngine

/// Stay-open hand editor: tap or drag tiles from the palette into the hand strip
/// without dismissing. Tapping a hand tile opens `TrackerTileSheet`.
///
/// Sheet height is locked to a large detent (no content-driven shrink) so empty
/// vs filled hand feels the same size.
struct TrackerHandSheet: View {
    let tracker: TrackerSession
    @Environment(\.dismiss) private var dismiss

    @State private var suit: HandSuitTab = .man
    @State private var inspectTile: TileSelection?

    private var hand: [Tile] { tracker.hand }

    /// Reserved height for ~3 wrapped rows of 32pt tiles + padding.
    private static let handAreaMinHeight: CGFloat = 128

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetGrabber()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Your hand (\(hand.count)/\(TrackerSession.maxHandSize))")
                        .font(MJFont.serif(15, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)

                    handArea

                    Text(hintText)
                        .font(MJFont.ui(11, weight: oddsLine == nil ? .regular : .semibold))
                        .foregroundStyle(oddsLine == nil ? MJColor.cream(0.5) : MJColor.creamHeading)
                        .frame(minHeight: 16, alignment: .leading)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(HandSuitTab.allCases, id: \.self) { tab in
                                FilterChip(tab.label, active: suit == tab) { suit = tab }
                            }
                        }
                        .padding(.horizontal, 2)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                              spacing: 10) {
                        ForEach(suit.options, id: \.self) { tile in
                            paletteTile(tile)
                        }
                    }
                    .padding(.horizontal, 4)

                    Spacer(minLength: 8)

                    GoldButton("Done") { dismiss() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .padding(.top, 8)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .sheet(item: $inspectTile) { sel in
            TrackerTileSheet(tile: sel.tile, tracker: tracker)
        }
    }

    private var hintText: String {
        if let oddsLine { return oddsLine }
        if hand.count >= TrackerSession.maxHandSize {
            return "Hand full (\(TrackerSession.maxHandSize)) — tap a tile above to edit"
        }
        return "Tap or drag tiles below to add · tap hand to edit counts"
    }

    // MARK: Hand area (stable height + wrap)

    private var handArea: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MJColor.cardRaised)

            if hand.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(MJColor.gold(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(8)
                    .overlay {
                        Text("Drop tiles here")
                            .font(MJFont.ui(11, weight: .medium))
                            .foregroundStyle(MJColor.gold(0.7))
                    }
            } else {
                TrackerHandTilesView(tiles: hand, tileWidth: 32) { tile in
                    inspectTile = TileSelection(tile)
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.handAreaMinHeight, alignment: .topLeading)
        .dropDestination(for: TileTransfer.self) { items, _ in
            guard let first = items.first else { return false }
            return add(first.tile)
        }
    }

    // MARK: Palette

    private func paletteTile(_ tile: Tile) -> some View {
        let allowed = tracker.canAddToHand(tile)
        return Button {
            _ = add(tile)
        } label: {
            MahjongTileView(tile, theme: .jade, width: 44)
        }
        .buttonStyle(.plain)
        .draggable(TileTransfer(tile)) {
            MahjongTileView(tile, theme: .jade, width: 40)
        }
        .opacity(allowed ? 1 : 0.4)
        .disabled(!allowed)
    }

    @discardableResult
    private func add(_ tile: Tile) -> Bool {
        guard tracker.canAddToHand(tile) else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return false
        }
        tracker.setHand(hand + [tile])
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        return true
    }

    private var oddsLine: String? {
        guard (13...14).contains(hand.count) else { return nil }
        let table = TableState(concealed: hand, melds: [], bonusTiles: [],
                               seenHistogram: tracker.seenHistogram, unseenCount: tracker.unseenCount,
                               opponentMeldCount: 0,
                               context: GameContext(seatWind: .east, prevailingWind: .east, houseRules: .standard))
        let advice = CoachAdvisor.advise(table)
        if let best = advice.best {
            return "Discard \(MahjongData.name(for: best.tile).traditional) → \(shantenLabel(best.shantenAfter)) · \(best.ukeireTotal) live · \(pct(best.nextDrawOdds))"
        }
        if let wait = advice.waitSet {
            return "\(shantenLabel(wait.shanten)) · \(wait.totalLive) live · \(pct(wait.nextDrawOdds)) next draw"
        }
        return shantenLabel(advice.currentShanten)
    }

    private func pct(_ odds: Double) -> String { String(format: "%.1f%%", odds * 100) }
}

// MARK: - Drag payload

struct TileTransfer: Transferable, Hashable {
    let classIndex: Int

    init(_ tile: Tile) { classIndex = tile.classIndex }
    init(classIndex: Int) { self.classIndex = classIndex }

    var tile: Tile { Tile(classIndex: classIndex) ?? .m(1) }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { transfer in
            String(transfer.classIndex)
        } importing: { raw in
            TileTransfer(classIndex: Int(raw) ?? 0)
        }
    }
}

// MARK: - Suit tabs

private enum HandSuitTab: CaseIterable, Hashable {
    case man, pin, sou, honor

    var label: String {
        switch self {
        case .man: return "萬 Chars"
        case .pin: return "筒 Dots"
        case .sou: return "索 Bamboo"
        case .honor: return "字 Honors"
        }
    }

    var options: [Tile] {
        switch self {
        case .man: return (1...9).map { .m($0) }
        case .pin: return (1...9).map { .p($0) }
        case .sou: return (1...9).map { .s($0) }
        case .honor: return [.east, .south, .west, .north, .redDragon, .greenDragon, .whiteDragon]
        }
    }
}
