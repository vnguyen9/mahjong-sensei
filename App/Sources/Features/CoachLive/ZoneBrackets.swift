import SwiftUI
import DesignSystem
import MahjongCore
import Recognition

/// Four rounded L-corners framing a zone — the feed's "fixed chrome" bracket
/// (UI plan §7): 20pt arms, 3pt stroke, 10pt corner radius, none configurable.
struct CornerBracketShape: Shape {
    var arm: CGFloat = 20
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Never let an arm or elbow exceed half the (small) zone.
        let a = min(arm, min(rect.width, rect.height) / 2)
        let r = min(radius, a)

        // Top-left.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + a))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.minX + a, y: rect.minY), radius: r)
        p.addLine(to: CGPoint(x: rect.minX + a, y: rect.minY))
        // Top-right.
        p.move(to: CGPoint(x: rect.maxX - a, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                 tangent2End: CGPoint(x: rect.maxX, y: rect.minY + a), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + a))
        // Bottom-right.
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - a))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - a, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX - a, y: rect.maxY))
        // Bottom-left.
        p.move(to: CGPoint(x: rect.minX + a, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.maxY - a), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - a))
        return p
    }
}

/// Zone corner brackets over the (fixed, full-screen) live feed (UI plan §7,
/// redesigned under Workstream E2 — "faint zone guides, not loud boxes").
///
/// In healthy spatial mode, exact calibration polygons are projected from the
/// current ARKit camera at 30 Hz, independently of recognition cadence. Mock
/// scenes retain their image-space `session.zoneBoxes` mapping.
///
/// E2 replaced the old "one amber bracket per unresolved tile" spam (dozens of
/// "N ? · tap" boxes tiling the feed) with a SINGLE consolidated chip — the
/// MINE/POND brackets themselves are now drawn faint/thin (calm guides, not
/// loud boxes), and the MINE bracket brightens while it reads as the player's
/// turn (`session.phase` `.thinking`/`.action`) as a low-cost "your move"
/// signal.
///
/// The consolidated unresolved chip and the MINE/POND **label chips** are the
/// only hit-testable elements — tapping the unresolved chip opens the
/// existing unresolved-assignment sheet; tapping a zone chip opens the
/// bracket-reassign confirmation (plan A3: "the tiles under THIS bracket are
/// actually X"). The bracket strokes themselves stay
/// `allowsHitTesting(false)` (only the small chip label is a tap target) so
/// the feed chrome above stays tappable and a stray tap near a corner arm
/// doesn't accidentally fire a reassignment.
struct ZoneBracketsOverlay: View {
    @Environment(CoachLiveSession.self) private var session
    /// The captured global frame of the fixed full-screen preview layer. Its
    /// size is ARKit's projection viewport; mock scenes also use its origin.
    let previewBounds: CGRect
    let onTapUnresolved: () -> Void
    /// Tapped MINE/POND chip → which zone it labels — the parent turns this
    /// into a confirmation dialog and, on confirm, `session.reassignZoneBracket(_:)`.
    let onTapZoneChip: (ZoneKind) -> Void

    private static let creamBracket = Color(hex: 0xF0E6D2, alpha: 0.85)

    /// While it reads as the player's turn, the MINE bracket brightens from
    /// its default faint/calm treatment to a fuller-opacity, thicker stroke —
    /// a cheap "your move" nicety, no new state needed.
    private var isMyTurn: Bool { session.phase == .thinking || session.phase == .action }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let rects = currentRects()
            ZStack(alignment: .topLeading) {
                if let r = rects.mine {
                    bracket(r, color: MJColor.gold, label: mineLabel,
                            chipBG: MJColor.gold, chipFG: MJColor.inkOnGold,
                            strokeOpacity: isMyTurn ? 0.9 : 0.35,
                            lineWidth: isMyTurn ? 2.5 : 1.5,
                            onTapChip: { onTapZoneChip(.mine) })
                }
                if let r = rects.pond {
                    bracket(r, color: Self.creamBracket, label: tableLabel,
                            chipBG: MJColor.cream, chipFG: MJColor.inkOnGold,
                            strokeOpacity: 0.3, lineWidth: 1.5,
                            onTapChip: { onTapZoneChip(.table) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if !session.unresolved.isEmpty {
                unresolvedChip
                    // Clears the torch button / LIVE pill / suggestion chips
                    // in the chrome above (same `chromeClearance` budget the
                    // zone labels use) and sits well inside the feed pane's
                    // smallest breathing split so it never gets clipped by
                    // the seam.
                    .padding(.top, Self.chromeClearance + 8)
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isMyTurn)
        .animation(.easeInOut(duration: 0.2), value: session.unresolved.isEmpty)
    }

    // MARK: - Labels

    private var mineLabel: String {
        let meldTiles = session.myMelds.reduce(0) { $0 + $1.tiles.filter { !$0.isBonus }.count }
        let count = session.handTiles.count + (session.drawnTile == nil ? 0 : 1) + meldTiles
        return "YOURS · \(count)"
    }
    private var tableLabel: String { "POND · \(session.pond.count)" }

    // MARK: - Consolidated unresolved chip

    /// The single replacement for the old per-tile amber brackets — one small
    /// pill, always in the same corner, that opens the same unresolved-
    /// assignment sheet the individual brackets used to.
    private var unresolvedChip: some View {
        Button(action: onTapUnresolved) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(session.unresolved.count) unresolved · tap")
                    .font(MJFont.ui(12, weight: .bold))
            }
            .foregroundStyle(MJColor.inkOnAmber)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(MJColor.amberZone.opacity(0.92), in: Capsule())
            .overlay { Capsule().strokeBorder(MJColor.inkOnAmber.opacity(0.15), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bracket + chip

    /// Below this overlay-space y the top chrome lives (back/torch buttons +
    /// the centered LIVE pill, ~112pt) — a zone label straddling a bracket top
    /// edge up there would collide with it, so the label tucks inside instead.
    private static let chromeClearance: CGFloat = 132

    /// The MINE/POND chip is always the tappable element (`onTapChip`) — the
    /// `CornerBracketShape` stroke stays `allowsHitTesting(false)` so it never
    /// intercepts a tap meant for the chip or the feed chrome beneath it.
    /// `strokeOpacity`/`lineWidth` are what make E2's brackets read as faint,
    /// calm zone guides instead of the old loud 3pt boxes — MINE brightens
    /// while it's the player's turn (see `isMyTurn`), POND stays faint always.
    private func bracket(_ rect: CGRect, color: Color, label: String,
                         chipBG: Color, chipFG: Color, strokeOpacity: Double, lineWidth: CGFloat,
                         onTapChip: @escaping () -> Void) -> some View {
        let labelInside = rect.minY < Self.chromeClearance
        return ZStack(alignment: .topLeading) {
            CornerBracketShape()
                .stroke(color.opacity(strokeOpacity),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .frame(width: rect.width, height: rect.height)
                .allowsHitTesting(false)
            chip(label, chipBG: chipBG, chipFG: chipFG, onTap: onTapChip)
                .offset(x: 8, y: labelInside ? 8 : -13)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .position(x: rect.midX, y: rect.midY)
    }

    private func chip(_ label: String, chipBG: Color, chipFG: Color, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) { chipLabel(label, chipBG: chipBG, chipFG: chipFG, showsPencil: true) }
            .buttonStyle(.plain)
    }

    /// The chip's own visual — a small pencil glyph is the tappability
    /// affordance on the two reassignable (MINE/POND) chips only.
    private func chipLabel(_ label: String, chipBG: Color, chipFG: Color, showsPencil: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(MJFont.ui(11, weight: .bold))
            if showsPencil {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(chipFG)
        .padding(.vertical, 2).padding(.horizontal, 8)
        .background(chipBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }

    // MARK: - Mapping + stabilizing

    /// Spatial mode projects exact calibration polygons with ARKit's current
    /// camera every display tick. Mock/non-AR scenes retain their existing
    /// image-space mapping for deterministic previews.
    private func currentRects() -> (mine: CGRect?, pond: CGRect?) {
        if session.countSource == .worldCensus,
           session.spatialTrackingHealth == .healthy,
           previewBounds.width > 0,
           previewBounds.height > 0 {
            let projected = session.currentProjectedZoneRects(
                viewportSize: previewBounds.size
            )
            return (
                projected.mine?.insetBy(dx: -6, dy: -6),
                projected.pond?.insetBy(dx: -6, dy: -6)
            )
        }
        return (
            mappedRect(for: session.zoneBoxes.mine),
            mappedRect(for: session.zoneBoxes.table)
        )
    }

    /// Fold `boxes` into their union, map to the preview, pad +6pt, and shift
    /// into the overlay's local space (which coincides with `previewBounds`).
    private func mappedRect(for boxes: [TileBoundingBox]) -> CGRect? {
        guard !boxes.isEmpty, previewBounds.width > 0,
              session.orientedImageSize.width > 0 else { return nil }
        let u = unionBox(boxes)
        let global = AspectFillMapping.previewRect(ofNormalized: u, previewBounds: previewBounds,
                                                   orientedImageSize: session.orientedImageSize)
            .insetBy(dx: -6, dy: -6)
        return global.offsetBy(dx: -previewBounds.minX, dy: -previewBounds.minY)
    }

    private func unionBox(_ boxes: [TileBoundingBox]) -> TileBoundingBox {
        let minX = boxes.map(\.x).min() ?? 0
        let minY = boxes.map(\.y).min() ?? 0
        let maxX = boxes.map { $0.x + $0.width }.max() ?? 0
        let maxY = boxes.map { $0.y + $0.height }.max() ?? 0
        return TileBoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

}
