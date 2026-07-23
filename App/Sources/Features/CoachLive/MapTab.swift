import SwiftUI
import DesignSystem
import MahjongCore
import Recognition

/// Top-down table schematic with an allocated region for every seat and the
/// pond. Nothing is overlaid on the pond: compact drawer heights shrink each
/// region, while labels and tile rows stay inside their own bounds.
struct MapTab: View {
    @Environment(CoachLiveSession.self) private var session
    @Environment(\.liveCompression) private var compression
    @Environment(\.liveControlMetrics) private var metrics
    let onTapUnresolved: () -> Void
    let onTapUnknown: (TrackID) -> Void

    private var pondTileWidth: CGFloat { compression == .full ? metrics.pondTileWidth : max(13, metrics.pondTileWidth - 3) }
    private var meldTileWidth: CGFloat { compression == .full ? metrics.meldTileWidth : max(13, metrics.meldTileWidth - 2) }
    private var pondCloudMaxWidth: CGFloat {
        metrics.minimumEditHitTarget == 0 ? 210 : metrics.paneWidthCap * 0.6
    }
    private var hasBottomRegion: Bool {
        !unknownTiles(in: .mineMeld).isEmpty
            || !unknownTiles(in: .boundaryUnresolved).isEmpty
            || !session.unresolved.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            let horizontalGap = max(3, 5 * metrics.scale)
            let pondWidth = min(pondCloudMaxWidth, geo.size.width * 0.46)
            let sideWidth = max(72, (geo.size.width - pondWidth - horizontalGap * 2 - 8) / 2)

            VStack(spacing: 3) {
                seatRow(.across)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)

                HStack(spacing: horizontalGap) {
                    seatRow(.left)
                        .frame(width: sideWidth)
                        .frame(maxHeight: .infinity)
                        .clipped()

                    ScrollView(.vertical, showsIndicators: false) {
                        pondCloud
                            .frame(maxWidth: pondWidth)
                    }
                    .frame(width: pondWidth)
                    .frame(maxHeight: .infinity)

                    seatRow(.right)
                        .frame(width: sideWidth)
                        .frame(maxHeight: .infinity)
                        .clipped()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if hasBottomRegion {
                    bottomRegion
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                }
            }
            .padding(4)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(RadialGradient(colors: [Color(hex: 0x17594A), Color(hex: 0x0D362C)],
                                     center: .init(x: 0.5, y: 0.45), startRadius: 0, endRadius: 240))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(MJColor.gold(0.22), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// `.center`-anchored wrap layout of the discard pond.
    private var pondCloud: some View {
        FlowLayout(spacing: 2, lineSpacing: 3) {
            ForEach(session.pond) { entry in
                MahjongTileView(entry.tile, width: pondTileWidth)
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
        .frame(maxWidth: pondCloudMaxWidth)
        .animation(.smooth(duration: 0.35), value: session.pond.map(\.id))
    }

    @ViewBuilder
    private func seatRow(_ seat: RelativeSeat) -> some View {
        let wind = seat.wind(mySeatWind: session.seatWind)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let melds = session.opponentMelds[seat], !melds.isEmpty {
                    Text(windEnglish(wind))
                        .font(MJFont.ui(11 * metrics.scale, weight: .semibold))
                        .foregroundStyle(MJColor.cream(0.55))
                    ForEach(Array(melds.enumerated()), id: \.offset) { _, meld in
                        TileRow(meld.tiles, width: meldTileWidth, spacing: 1.5)
                    }
                } else {
                    Text("\(windEnglish(wind)) · \(session.concealedCounts[seat] ?? 13) · concealed")
                        .font(MJFont.ui(11 * metrics.scale))
                        .foregroundStyle(MJColor.cream(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 8 * metrics.scale)
                        .padding(.vertical, 4 * metrics.scale)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
                unknownRow(for: seat)
            }
            .frame(minHeight: 44)
        }
    }

    private var bottomRegion: some View {
        HStack(spacing: 6) {
            myRevealedUnknownRow
                .frame(maxWidth: .infinity, alignment: .leading)
            let boundary = unknownTiles(in: .boundaryUnresolved)
            if !boundary.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(boundary) { tile in unknownTile(tile) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if !session.unresolved.isEmpty {
                Button(action: onTapUnresolved) {
                    Text("\(session.unresolved.count) ? · tap")
                        .font(MJFont.ui(11 * metrics.scale, weight: .bold))
                        .foregroundStyle(MJColor.inkOnAmber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 8)
                        .background(MJColor.amberZone, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    @ViewBuilder
    private var myRevealedUnknownRow: some View {
        let tiles = unknownTiles(in: .mineMeld)
        if !tiles.isEmpty {
            HStack(spacing: 3) {
                Text("Your revealed tiles")
                    .font(MJFont.ui(10 * metrics.scale, weight: .semibold))
                    .foregroundStyle(MJColor.cream(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(tiles) { tile in unknownTile(tile) }
                    }
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
                .frame(minWidth: metrics.minimumEditHitTarget, minHeight: metrics.minimumEditHitTarget)
                .overlay {
                    Text("?")
                        .font(MJFont.ui(12 * metrics.scale, weight: .bold))
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
