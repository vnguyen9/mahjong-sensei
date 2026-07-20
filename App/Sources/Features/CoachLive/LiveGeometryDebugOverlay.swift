#if DEBUG
import SwiftUI
import DesignSystem
import MahjongCore
import Recognition
import simd

/// DEV-ONLY overlay that draws the **calibrated table geometry** projected onto
/// the live tracking feed — the hand band, the pond, each opponent's meld band,
/// and the seat/wind markers — so you can confirm on-device that calibration
/// actually lands on the real table and tracks it as the camera pans.
///
/// The live feed is a plain `CAMetalLayer` (no SceneKit), so rather than a 3D
/// overlay (which would need a second `ARSession` fighting the tracking one),
/// this projects each geometry corner to screen with the SAME math the tracking
/// loop uses — `TableProjection.normalizedOrientedPoint` (`CoachLiveSession`'s
/// per-frame projection) → `AspectFillMapping.previewRect` — and strokes flat
/// `Canvas` polygons. `latestFrame` is polled (not observable), so a
/// `TimelineView(.animation)` re-projects every display frame.
///
/// Gated to `#if DEBUG` and toggled from the triple-tap debug HUD; hidden until
/// the plane is locked and a geometry exists.
struct LiveGeometryDebugOverlay: View {
    @Environment(CoachLiveSession.self) private var session
    /// The captured global frame of the fixed preview (same `previewBounds` the
    /// zone brackets map against).
    let previewBounds: CGRect

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, _ in draw(&context) }
                .allowsHitTesting(false)
        }
    }

    private func draw(_ context: inout GraphicsContext) {
        guard previewBounds.width > 0, previewBounds.height > 0,
              let capture = session.arCapture,
              let lockedPlaneTransform = capture.lockedPlaneTransform,
              let frame = capture.latestFrame else { return }

        let controller = session.worldCensusController
        let planeTransform = controller?.tableOrigin.tableToWorld
            ?? lockedPlaneTransform
        let fittedExtent = controller.map {
            Double(max($0.tableOrigin.extent.x, $0.tableOrigin.extent.y))
        } ?? session.calibratedTableGeometry?.extent ?? 0.9
        var geometry = session.calibratedTableGeometry
            ?? TableCalibrationGeometry.autoPartition(
                extentMetres: fittedExtent,
                mySeatWind: session.seatWind
            )
        geometry.extent = fittedExtent
        let extent = geometry.extent
        guard extent > 0 else { return }

        let projection = TableProjection(
            cameraTransform: frame.cameraTransform,
            intrinsics: frame.intrinsics,
            imageResolution: SIMD2<Float>(Float(frame.imageResolution.width),
                                          Float(frame.imageResolution.height)),
            planeTransform: planeTransform)
        let orientedSIMD = SIMD2<Double>(Double(frame.orientedImageSize.width),
                                         Double(frame.orientedImageSize.height))
        let orientedCG = frame.orientedImageSize

        /// Normalized table point → screen point (nil if behind camera).
        func screen(_ n: SIMD2<Double>) -> CGPoint? {
            let local = SIMD2<Double>((n.x - 0.5) * extent, (n.y - 0.5) * extent)
            guard let uv = projection.normalizedOrientedPoint(ofTablePoint: local,
                                                              orientedImageSize: orientedSIMD) else { return nil }
            return AspectFillMapping.previewRect(
                ofNormalized: TileBoundingBox(x: uv.x, y: uv.y, width: 0, height: 0),
                previewBounds: previewBounds, orientedImageSize: orientedCG).origin
        }

        /// Fill + stroke a closed polygon; skips entirely if any corner is
        /// off-screen this frame (a partial polygon would read as a lie).
        func polygon(_ corners: [SIMD2<Double>], fill: Color, stroke: Color) {
            let pts = corners.compactMap(screen)
            guard pts.count == corners.count, pts.count >= 3 else { return }
            var path = Path()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
            context.fill(path, with: .color(fill))
            context.stroke(path, with: .color(stroke), lineWidth: 2)
        }

        // Hand band (gold), opponent meld bands (amber), pond (jade).
        for (_, band) in geometry.meldBands {
            polygon(band.corners, fill: MJColor.amberZone.opacity(0.10), stroke: MJColor.amberZone.opacity(0.8))
        }
        polygon(pondCorners(geometry.pond), fill: MJColor.jadeAccent.opacity(0.16), stroke: MJColor.jadeAccent.opacity(0.9))
        polygon(geometry.handBand.corners, fill: MJColor.gold.opacity(0.14), stroke: MJColor.gold.opacity(0.9))

        // LiDAR census anchors (cyan): world points are projected fresh from
        // the current camera pose, so on-device drift is immediately visible
        // while panning or changing angle.
        if let census = session.worldCensusController?.snapshot {
            for track in census.tracks where track.lifecycle == .confirmed {
                guard let world = track.worldPosition,
                      let uv = projection.normalizedOrientedPoint(
                        ofWorldPoint: SIMD3<Double>(
                            Double(world.x), Double(world.y), Double(world.z)
                        ),
                        orientedImageSize: orientedSIMD
                      ) else { continue }
                let point = AspectFillMapping.previewRect(
                    ofNormalized: TileBoundingBox(
                        x: uv.x, y: uv.y, width: 0, height: 0
                    ),
                    previewBounds: previewBounds,
                    orientedImageSize: orientedCG
                ).origin
                let anchor = Path(
                    ellipseIn: CGRect(
                        x: point.x - 4, y: point.y - 4, width: 8, height: 8
                    )
                )
                context.fill(anchor, with: .color(.cyan.opacity(0.9)))
            }
        }

        // Seat + wind markers.
        for seat in geometry.seats {
            guard let p = screen(seat.edgeMidpoint) else { continue }
            let dot = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(MJColor.creamHeading.opacity(0.9)))
            context.draw(Text(windLetter(seat.wind))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MJColor.creamHeading),
                at: CGPoint(x: p.x, y: p.y - 14))
        }
    }

    /// Pond outline points: rect/quad use their 4 corners; a disk is sampled
    /// into a 20-point ring so it reads as round, not square.
    private func pondCorners(_ pond: TrackerConfig.PondShape) -> [SIMD2<Double>] {
        if case let .disk(center, radius) = pond {
            let n = 20
            return (0..<n).map { i in
                let a = Double(i) / Double(n) * 2 * .pi
                return SIMD2<Double>(center.x + radius * Foundation.cos(a),
                                     center.y + radius * Foundation.sin(a))
            }
        }
        return pond.corners
    }

    private func windLetter(_ w: Wind) -> String {
        switch w {
        case .east: return "E"
        case .south: return "S"
        case .west: return "W"
        case .north: return "N"
        }
    }
}
#endif
