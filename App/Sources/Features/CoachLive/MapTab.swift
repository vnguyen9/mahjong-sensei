import SwiftUI
import DesignSystem
import MahjongCore
import Recognition

/// Top-down table schematic: pond center, opponents at their relative
/// edges, unresolved chip bottom-trailing (UI plan §9 — design-critical).
struct MapTab: View {
    @Environment(CoachLiveSession.self) private var session
    @Environment(\.liveCompression) private var compression
    let onTapUnresolved: () -> Void
    let onTapUnknown: (TrackID) -> Void

    private var pondTileWidth: CGFloat { compression == .full ? 16 : 13 }
    private var meldTileWidth: CGFloat { compression == .full ? 15 : 13 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RadialGradient(colors: [Color(hex: 0x17594A), Color(hex: 0x0D362C)],
                                     center: .init(x: 0.5, y: 0.45), startRadius: 0, endRadius: 240))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(MJColor.gold(0.22), lineWidth: 1)
                }

            VStack {
                seatRow(.across)
                Spacer(minLength: 0)
                HStack(alignment: .center) {
                    seatRow(.left)
                    Spacer(minLength: 0)
                    seatRow(.right)
                }
                Spacer(minLength: 0)
                myRevealedUnknownRow
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            pondCloud
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !session.unresolved.isEmpty {
                Button(action: onTapUnresolved) {
                    Text("\(session.unresolved.count) ? · tap")
                        .font(MJFont.ui(11, weight: .bold))
                        .foregroundStyle(MJColor.inkOnAmber)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(MJColor.amberZone, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(10)
            }

            if !session.spatialUnknownTiles.isEmpty {
                unknownSummary
                    .padding(10)
                    .padding(.bottom, session.unresolved.isEmpty ? 42 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `.center`-anchored wrap layout of the discard pond.
    private var pondCloud: some View {
        FlowLayout(spacing: 2, lineSpacing: 3) {
            ForEach(session.pond) { entry in
                MahjongTileView(entry.tile, theme: .jade, width: pondTileWidth)
                    .overlay {
                        if entry.isNewest {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(MJColor.amberZone, lineWidth: 1.5)
                        }
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            ForEach(unknownTiles(in: .tablePond)) { tile in
                unknownTile(tile)
            }
        }
        .frame(maxWidth: 210)
        .animation(.smooth(duration: 0.35), value: session.pond.map(\.id))
    }

    @ViewBuilder
    private func seatRow(_ seat: RelativeSeat) -> some View {
        let wind = seat.wind(mySeatWind: session.seatWind)
        if let melds = session.opponentMelds[seat], !melds.isEmpty {
            VStack(spacing: 4) {
                Text(windEnglish(wind))
                    .font(MJFont.ui(11, weight: .semibold))
                    .foregroundStyle(MJColor.cream(0.55))
                VStack(spacing: 2) {
                    ForEach(Array(melds.enumerated()), id: \.offset) { _, meld in
                        TileRow(meld.tiles, theme: .jade, width: meldTileWidth, spacing: 1.5)
                    }
                }
                unknownRow(for: seat)
            }
        } else {
            VStack(spacing: 3) {
                Text("\(windEnglish(wind)) · \(session.concealedCounts[seat] ?? 13) · concealed")
                    .font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.55))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.06), in: Capsule())
                unknownRow(for: seat)
            }
        }
    }

    private var unknownSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(session.spatialUnknownTiles.count) physical tile\(session.spatialUnknownTiles.count == 1 ? "" : "s") need faces")
                    .font(MJFont.ui(11, weight: .bold))
            }
            let boundary = unknownTiles(in: .boundaryUnresolved)
            if !boundary.isEmpty {
                HStack(spacing: 2) {
                    ForEach(boundary) { tile in unknownTile(tile) }
                }
            }
        }
        .foregroundStyle(MJColor.inkOnAmber)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(MJColor.amberZone, in: Capsule())
        .accessibilityLabel("\(session.spatialUnknownTiles.count) physical tiles need face identification")
    }

    @ViewBuilder
    private var myRevealedUnknownRow: some View {
        let tiles = unknownTiles(in: .mineMeld)
        if !tiles.isEmpty {
            VStack(spacing: 3) {
                Text("Your revealed tiles")
                    .font(MJFont.ui(10, weight: .semibold))
                    .foregroundStyle(MJColor.cream(0.55))
                HStack(spacing: 2) {
                    ForEach(tiles) { tile in unknownTile(tile) }
                }
            }
        }
    }

    @ViewBuilder
    private func unknownRow(for seat: RelativeSeat) -> some View {
        let tiles = unknownTiles(in: semanticZone(for: seat))
        if !tiles.isEmpty {
            HStack(spacing: 2) {
                ForEach(tiles) { tile in unknownTile(tile) }
            }
        }
    }

    private func semanticZone(for seat: RelativeSeat) -> SemanticZoneID {
        switch seat {
        case .me: return .mineMeld
        case .left: return .tableRevealedLeft
        case .across: return .tableRevealedFar
        case .right: return .tableRevealedRight
        }
    }

    private func unknownTiles(in zone: SemanticZoneID) -> [SpatialUnknownTile] {
        session.spatialUnknownTiles.filter { $0.zone == zone }
    }

    private func unknownTile(_ tile: SpatialUnknownTile) -> some View {
        Button { onTapUnknown(tile.id) } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(MJColor.amberZone, style: StrokeStyle(lineWidth: 1.4, dash: [3, 2]))
                .frame(width: meldTileWidth, height: meldTileWidth * 1.35)
                .overlay {
                    Text("?")
                        .font(MJFont.ui(12, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unknown physical tile")
        .accessibilityHint("Double tap to identify its face.")
    }
}

/// A center-aligned, top-to-bottom wrapping row layout — SwiftUI has no
/// built-in wrap container. Used only by `MapTab`'s pond cloud.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = maxWidth.isFinite ? maxWidth : (rows.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2   // center each row
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading, proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int]; var width: CGFloat; var height: CGFloat }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = items.isEmpty ? size.width : width + spacing + size.width
            if extended > maxWidth, !items.isEmpty {
                rows.append(Row(items: items, width: width, height: height))
                items = []; width = 0; height = 0
            }
            width = items.isEmpty ? size.width : width + spacing + size.width
            height = max(height, size.height)
            items.append(index)
        }
        if !items.isEmpty { rows.append(Row(items: items, width: width, height: height)) }
        return rows
    }
}
