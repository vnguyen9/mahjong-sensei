import SwiftUI
import UIKit
import DesignSystem
import MahjongCore
import MahjongData
import Recognition

/// Lane 2 · Check & correct (spec screen 7). The reliability gate — nothing is
/// scored until it passes here. Tap a tile to replace/remove it, drag it away to
/// discard, or tap the "+" to add one. Mirrors the physical rows the camera saw.
struct CorrectView: View {
    @Environment(ScanCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var trayWidth: CGFloat = 0

    private let spacing: CGFloat = 8
    private var session: ScanSession { coordinator.session }

    private enum EditTarget: Identifiable {
        case replace(DetectedTile)
        case add
        var id: String { if case let .replace(d) = self { return d.id.uuidString } else { return "add" } }
        var isAdd: Bool { if case .add = self { return true } else { return false } }
        var current: Tile? { if case let .replace(d) = self { return d.tile } else { return nil } }
    }

    var body: some View {
        ZStack {
            CapturedBackdrop(photo: session.capturedPhoto, fallback: .content)
            VStack(spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 2) {
                    Text(countSummary)
                        .font(MJFont.ui(14, weight: .bold))
                        .foregroundStyle(MJColor.gold)
                    Text("Tap a tile to fix · drag it away to remove")
                        .font(MJFont.ui(13))
                        .foregroundStyle(MJColor.cream(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 4)

                Spacer(minLength: 8)
                tray
                Spacer(minLength: 8)

                countStatusRow
                GoldButton("Looks right →") { coordinator.push(.context) }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 104)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editing) { target in
            CorrectionPicker(
                current: target.current,
                confirmVerb: target.isAdd ? "Add" : "Use",
                onConfirm: { tile in
                    switch target {
                    case let .replace(d): session.replace(id: d.id, with: tile)
                    case .add:            session.append(tile)
                    }
                    editing = nil
                },
                onRemove: target.isAdd ? nil : {
                    if case let .replace(d) = target {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { session.remove(id: d.id) }
                    }
                    editing = nil
                }
            )
            .presentationDetents([.height(target.isAdd ? 500 : 460)])
            .presentationBackground(.clear)
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(MJFont.ui(14, weight: .medium)).foregroundStyle(MJColor.gold)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Check your hand").font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.creamHeading)
            Spacer()
            if session.flaggedIDs.isEmpty {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MJColor.jadeAccent).frame(width: 44, alignment: .trailing)
            } else {
                WarningPill("\(session.flaggedIDs.count) to fix")
            }
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    private var rows: [[DetectedTile]] { session.workingRows }

    /// "N tiles · M bonus" — the one fact the old Detected screen carried over.
    private var countSummary: String {
        let n = session.playable.count
        let bonus = session.bonus.count
        var s = "\(n) tile\(n == 1 ? "" : "s")"
        if bonus > 0 { s += " · \(bonus) bonus" }
        return s
    }

    /// Adaptive tile width from the longest row (counting the ghost "+" on the last
    /// row), clamped 20–48pt, then scaled by pinch zoom.
    private var tileWidth: CGFloat {
        let longest = rows.map(\.count).max() ?? 0
        let lastPlusGhost = (rows.last?.count ?? 0) + 1
        let nMax = max(1, longest, lastPlusGhost)
        let base = trayWidth > 0 ? (trayWidth - spacing * CGFloat(nMax - 1)) / CGFloat(nMax) : 40
        return min(48, max(20, base)) * zoom * gestureZoom
    }

    private var tray: some View {
        let w = tileWidth
        return VStack(spacing: spacing + 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(spacing: spacing) {
                    ForEach(row) { detected in
                        TrayTile(detected: detected, width: w,
                                 flagged: session.flaggedIDs.contains(detected.id),
                                 onTap: { editing = .replace(detected) },
                                 onRemove: { removeTile(detected.id) })
                    }
                    if idx == rows.count - 1 {
                        GhostAddTile(width: w) { editing = .add }
                    }
                }
            }
            if rows.isEmpty {
                GhostAddTile(width: w) { editing = .add }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { trayWidth = $0 })
        .gesture(
            MagnifyGesture()
                .onChanged { gestureZoom = min(1.5, max(0.7, $0.magnification)) }
                .onEnded { _ in
                    zoom = min(1.5, max(0.7, zoom * gestureZoom))
                    gestureZoom = 1
                    if zoom > 0.9, zoom < 1.1 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { zoom = 1 }
                    }
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { zoom = 1 }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var countStatusRow: some View {
        switch session.countStatus(for: session.mode) {
        case .valid:
            EmptyView()
        case let .kongSized(n):
            statusRow(icon: "info.circle", color: MJColor.gold,
                      text: "Kong-sized hand — \(n) playable tiles. Kong scoring isn't supported yet, so the result may undercount.")
        case let .tooFew(n):
            statusRow(icon: "exclamationmark.triangle.fill", color: MJColor.amberLowConf,
                      text: "Only \(n) playable tiles — a winning hand needs 14. Add tiles or rescan.")
        case let .tooMany(n):
            statusRow(icon: "exclamationmark.triangle.fill", color: MJColor.amberLowConf,
                      text: "\(n) playable tiles — too many for one hand. Flick extras off the tray.")
        }
    }

    private func statusRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(text).font(MJFont.ui(11.5, weight: .medium)).foregroundStyle(MJColor.cream(0.78))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.3), lineWidth: 1) }
        .padding(.horizontal, 20)
    }

    private func removeTile(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { session.remove(id: id) }
    }
}

// MARK: - Draggable tray tile (tap to fix · flick away to remove)

private struct TrayTile: View {
    let detected: DetectedTile
    let width: CGFloat
    let flagged: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var drag: CGSize = .zero
    @State private var removing = false
    @State private var dragging = false

    private let removeThreshold: CGFloat = 56
    private var past: Bool { abs(drag.height) > removeThreshold }

    var body: some View {
        MahjongTileView(detected.tile, theme: .jade, width: width)
            .overlay {
                if flagged {
                    RoundedRectangle(cornerRadius: max(6, width * 0.22), style: .continuous)
                        .strokeBorder(MJColor.amberLowConf, lineWidth: 2).padding(-3)
                }
            }
            .overlay {
                if past {
                    RoundedRectangle(cornerRadius: max(6, width * 0.22), style: .continuous)
                        .fill(MJColor.rustAvoid.opacity(0.28)).padding(-3)
                }
            }
            .overlay(alignment: .topLeading) {
                if flagged {
                    Text("?").font(.system(size: max(8, width * 0.28), weight: .bold))
                        .foregroundStyle(Color(hex: 0x1A1A1A))
                        .frame(width: max(13, width * 0.34), height: max(13, width * 0.34))
                        .background(MJColor.amberLowConf, in: Circle())
                        .offset(x: -width * 0.12, y: -width * 0.14)
                }
            }
            .overlay(alignment: .top) {
                if dragging {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(past ? .white : MJColor.cream(0.85))
                        .frame(width: 26, height: 26)
                        .background(past ? MJColor.rustAvoid : Color(hex: 0x38473F), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                        .offset(y: -32)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(removing ? 0.2 : (drag == .zero ? 1 : 1.06))
            .rotationEffect(.degrees(Double(drag.width / 40)))
            .offset(drag)
            .opacity(removing ? 0 : 1)
            .zIndex(drag == .zero ? 0 : 10)
            .onTapGesture { onTap() }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        let wasPast = past
                        drag = value.translation
                        if !dragging {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { dragging = true }
                        }
                        if past, !wasPast { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    }
                    .onEnded { value in
                        let dy = value.translation.height
                        let pdy = value.predictedEndTranslation.height
                        let verticalDominant = abs(value.translation.height) >= abs(value.translation.width)
                        if verticalDominant, abs(dy) > removeThreshold || abs(pdy) > 110 {
                            withAnimation(.easeIn(duration: 0.18)) {
                                drag = CGSize(width: value.translation.width * 1.8, height: value.translation.height * 1.8)
                                removing = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { onRemove() }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                drag = .zero
                                dragging = false
                            }
                        }
                    }
            )
            .transition(.scale.combined(with: .opacity))
    }
}

private struct GhostAddTile: View {
    let width: CGFloat
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: max(6, width * 0.19), style: .continuous)
                .strokeBorder(MJColor.gold(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: width, height: (width * 1.35).rounded())
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: width * 0.4, weight: .semibold))
                        .foregroundStyle(MJColor.gold(0.85))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a tile")
    }
}

// MARK: - Tile picker sheet (replace / add, with suit tabs + remove)

private struct CorrectionPicker: View {
    let current: Tile?
    let confirmVerb: String
    let onConfirm: (Tile) -> Void
    let onRemove: (() -> Void)?

    @State private var suit: SuitTab
    @State private var selection: Tile

    init(current: Tile?, confirmVerb: String, onConfirm: @escaping (Tile) -> Void, onRemove: (() -> Void)?) {
        self.current = current
        self.confirmVerb = confirmVerb
        self.onConfirm = onConfirm
        self.onRemove = onRemove
        let start = current ?? .m(1)
        _selection = State(initialValue: start)
        _suit = State(initialValue: SuitTab(for: start))
    }

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            VStack(spacing: 14) {
                SheetGrabber().padding(.top, 10)
                Text(onRemove == nil ? "Add a tile" : "Replace tile")
                    .font(MJFont.serif(15, weight: .bold)).foregroundStyle(MJColor.creamHeading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(SuitTab.allCases, id: \.self) { tab in
                            FilterChip(tab.label, active: suit == tab) {
                                suit = tab
                                if !tab.options.contains(selection) { selection = tab.options[0] }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                    ForEach(suit.options, id: \.self) { tile in
                        Button { selection = tile } label: {
                            MahjongTileView(tile, theme: .jade, width: 44)
                                .overlay {
                                    if tile == selection {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(MJColor.gold, lineWidth: 2.5).padding(-3)
                                            .shadow(color: MJColor.gold(0.5), radius: 6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)

                GoldButton("\(confirmVerb) \(MahjongData.name(for: selection).traditional) →") { onConfirm(selection) }

                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove this tile", systemImage: "trash")
                            .font(MJFont.ui(13, weight: .semibold))
                            .foregroundStyle(MJColor.rustAvoid)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(MJColor.rustAvoid.opacity(0.5), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }
}

private enum SuitTab: CaseIterable, Hashable {
    case man, pin, sou, honor, bonus

    var label: String {
        switch self {
        case .man: return "萬 Chars"
        case .pin: return "筒 Dots"
        case .sou: return "索 Bamboo"
        case .honor: return "字 Honors"
        case .bonus: return "花 Flowers"
        }
    }

    var options: [Tile] {
        switch self {
        case .man: return (1...9).map { .m($0) }
        case .pin: return (1...9).map { .p($0) }
        case .sou: return (1...9).map { .s($0) }
        case .honor: return [.east, .south, .west, .north, .redDragon, .greenDragon, .whiteDragon]
        case .bonus: return [.flower(.plum), .flower(.orchid), .flower(.chrysanthemum), .flower(.bamboo),
                             .season(.spring), .season(.summer), .season(.autumn), .season(.winter)]
        }
    }

    init(for tile: Tile) {
        switch tile {
        case .suited(.characters, _): self = .man
        case .suited(.dots, _):       self = .pin
        case .suited(.bamboo, _):     self = .sou
        case .wind, .dragon:          self = .honor
        case .flower, .season:        self = .bonus
        }
    }
}
