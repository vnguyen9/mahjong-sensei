import SwiftUI
import UIKit
import DesignSystem
import MahjongCore
import MahjongData
import EfficiencyEngine
import CoachEngine

/// One atomic hand editor shared by camera recognition and manual entry.
/// `initialTiles` is a proposal only; TrackerSession is changed once, on Apply.
struct TrackerHandSheet: View {
    let tracker: TrackerSession
    let sourceImage: UIImage?
    let onScanHand: (() -> Void)?
    let onApplied: (() -> Void)?
    private let isPad: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [Tile]
    @State private var suit: HandSuitTab = .man
    @State private var editTarget: HandEditTarget?
    @State private var errorMessage: String?

    private static let handAreaMinHeight: CGFloat = 128

    init(tracker: TrackerSession,
         initialTiles: [Tile]? = nil,
         sourceImage: UIImage? = nil,
         onScanHand: (() -> Void)? = nil,
         onApplied: (() -> Void)? = nil) {
        self.tracker = tracker
        self.sourceImage = sourceImage
        self.onScanHand = onScanHand
        self.onApplied = onApplied
        isPad = UIDevice.current.userInterfaceIdiom == .pad
        _draft = State(initialValue: initialTiles ?? tracker.hand)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let sourceImage {
                        Image(uiImage: sourceImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: isPad ? 300 : 190)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityLabel("Photographed hand")
                    }

                    Text("Your hand (\(draft.count)/\(TrackerSession.maxHandSize))")
                        .font(MJFont.serif(17, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)

                    handArea

                    Text(hintText)
                        .font(.footnote)
                        .foregroundStyle(oddsLine == nil ? MJColor.cream(0.62) : MJColor.creamHeading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let onScanHand {
                        Button {
                            dismiss()
                            onScanHand()
                        } label: {
                            Label(sourceImage == nil ? "Scan Hand" : "Scan Again",
                                  systemImage: "camera.viewfinder")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Opens the camera with a wide hand guide. Unsaved edits are discarded.")
                    }

                    Divider().overlay(MJColor.gold(0.18))

                    Text("Enter Hand Tiles")
                        .font(.headline)
                        .foregroundStyle(MJColor.creamHeading)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(HandSuitTab.allCases, id: \.self) { tab in
                                FilterChip(tab.label, active: suit == tab) { suit = tab }
                            }
                        }
                        .padding(.horizontal, 2)
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                        spacing: 10
                    ) {
                        ForEach(suit.options, id: \.self) { tile in
                            paletteTile(tile)
                        }
                    }
                    .padding(.horizontal, 4)

                }
                .padding(20)
                .padding(.bottom, 24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(MJColor.sheetGlass.ignoresSafeArea())
            .navigationTitle(sourceImage == nil ? "Edit Hand" : "Review Hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply Hand") { apply() }
                        .disabled(!isDraftValid)
                        .accessibilityHint("Replaces the saved hand with this reviewed draft.")
                }
            }
        }
        .presentationDetents(isPad ? [.fraction(0.94)] : [.large])
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .sheet(item: $editTarget) { target in
            TrackerHandTileDraftEditor(
                tile: target.tile,
                onReplace: { replacement in
                    guard draft.indices.contains(target.index) else { return }
                    draft[target.index] = replacement
                    editTarget = nil
                },
                onRemove: {
                    guard draft.indices.contains(target.index) else { return }
                    draft.remove(at: target.index)
                    editTarget = nil
                }
            )
            .presentationDetents(isPad ? [.fraction(0.88)] : [.large])
        }
        .alert("Hand not applied", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Check the hand and try again.")
        }
    }

    private var handArea: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MJColor.cardRaised)

            if draft.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(MJColor.gold(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(8)
                    .overlay {
                        Text("Scan your hand or add tiles below")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(MJColor.gold(0.78))
                    }
            } else {
                let columns = [GridItem(.adaptive(minimum: 36), spacing: 7)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                    ForEach(Array(draft.enumerated()), id: \.offset) { index, tile in
                        Button {
                            editTarget = HandEditTarget(index: index, tile: tile)
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            MahjongTileView(tile, width: 34)
                                .frame(minWidth: 44, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(MahjongData.name(for: tile).english)")
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.handAreaMinHeight, alignment: .topLeading)
    }

    private var hintText: String {
        if let oddsLine { return oddsLine }
        if draft.count >= TrackerSession.maxHandSize {
            return "Hand full — tap a tile above to change or remove it."
        }
        return "Tap a detected tile to correct or remove it. Add missing tiles below."
    }

    private func paletteTile(_ tile: Tile) -> some View {
        let allowed = canAdd(tile)
        return Button {
            guard allowed else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            draft.append(tile)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        } label: {
            MahjongTileView(tile, width: 44)
                .frame(minWidth: 44, minHeight: 54)
        }
        .buttonStyle(.plain)
        .opacity(allowed ? 1 : 0.38)
        .disabled(!allowed)
        .accessibilityLabel("Add \(MahjongData.name(for: tile).english)")
    }

    private func canAdd(_ tile: Tile) -> Bool {
        guard draft.count < TrackerSession.maxHandSize else { return false }
        let cap = tile.isBonus ? 1 : 4
        let inDraft = draft.filter { $0 == tile }.count
        let onTable = tile.isBonus ? 0 : tracker.tableSeen(tile)
        return inDraft + onTable < cap
    }

    private var isDraftValid: Bool {
        guard draft.count <= TrackerSession.maxHandSize else { return false }
        let grouped = Dictionary(grouping: draft, by: { $0 })
        return grouped.allSatisfy { tile, copies in
            copies.count + (tile.isBonus ? 0 : tracker.tableSeen(tile))
                <= (tile.isBonus ? 1 : 4)
        }
    }

    private func apply() {
        do {
            try tracker.applyHand(draft)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onApplied?()
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorMessage = error.localizedDescription
        }
    }

    private var oddsLine: String? {
        guard (13...14).contains(draft.count) else { return nil }
        let table = TableState(
            concealed: draft, melds: [], bonusTiles: [],
            seenHistogram: tracker.seenHistogram,
            unseenCount: max(1, 136 - tracker.seenHistogram.reduce(0, +) - draft.count),
            opponentMeldCount: 0,
            context: GameContext(seatWind: .east, prevailingWind: .east,
                                 houseRules: .standard)
        )
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

private struct HandEditTarget: Identifiable {
    var index: Int
    var tile: Tile
    var id: Int { index }
}

private struct TrackerHandTileDraftEditor: View {
    let tile: Tile
    let onReplace: (Tile) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var suit: SuitTab
    @State private var selection: Tile

    init(tile: Tile, onReplace: @escaping (Tile) -> Void,
         onRemove: @escaping () -> Void) {
        self.tile = tile
        self.onReplace = onReplace
        self.onRemove = onRemove
        _suit = State(initialValue: SuitTab(for: tile))
        _selection = State(initialValue: tile)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TileFaceSelectionGrid(suit: $suit, selection: $selection)
                    Button("Use \(MahjongData.name(for: selection).english)") {
                        onReplace(selection)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Remove from Hand", role: .destructive, action: onRemove)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(20)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Edit Hand Tile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
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
        case .honor: return [.east, .south, .west, .north,
                             .redDragon, .greenDragon, .whiteDragon]
        }
    }
}
