import simd
import Foundation

/// Turns detector output (normalized oriented-image `DetectedTile`s) into
/// synthetic **table-space** `DetectedTile`s: same identity/face/confidence,
/// but a `box` expressed in normalized table units instead of image pixels.
///
/// This is the seam that lets a `.tableSpace`-configured `TableTracker` stay
/// completely unaware of ARKit — it only ever ingests `TileBoundingBox`es,
/// and table-space mode just means those boxes happen to be table-plane
/// coordinates rather than image coordinates.
public enum DetectionProjector {
    /// Projects each tile's on-table point through `projection`, then
    /// synthesizes a fixed-size table-space box (known physical tile
    /// footprint, not the detector's image-space box shape) around it.
    ///
    /// - Parameters:
    ///   - tiles: detections in normalized oriented-image space.
    ///   - projection: the frame's camera/plane matrices.
    ///   - orientedImageSize: the oriented (portrait) image's pixel size —
    ///     forwarded to `projection` unchanged.
    ///   - tableExtent: metres spanned by table-space's normalized `[0,1]`
    ///     range (e.g. `0.9`) — the divisor that turns anchor-local metres
    ///     into the tracker's normalized table-space units, centered so the
    ///     plane anchor's origin lands at `(0.5, 0.5)`.
    ///   - tileSize: physical tile footprint in metres (e.g. `(0.024, 0.032)`
    ///     for a ~24×32mm tile face), used to size the synthesized box.
    /// - Returns: table-space `DetectedTile`s, one per input tile whose
    ///   projection succeeded (id/tile/confidence/inReticle preserved).
    ///   Tiles the projection can't place — ray parallel to the table, or
    ///   the hit falls behind the camera — are dropped; the returned count
    ///   is otherwise equal to `tiles.count`.
    public static func projectToTableSpace(_ tiles: [DetectedTile],
                                           projection: TableProjection,
                                           orientedImageSize: SIMD2<Double>,
                                           tableExtent: Double,
                                           tileSize: SIMD2<Double>) -> [DetectedTile] {
        guard tableExtent > 0 else { return [] }
        let w = tileSize.x / tableExtent
        let h = tileSize.y / tableExtent

        return tiles.compactMap { tile in
            // Bottom-center, uniformly: for an upright (standing) tile this
            // is the point actually touching the table surface, which is
            // what the plane intersection needs to be physically meaningful.
            // A flat (lying) tile's whole face already sits on the table, so
            // its bottom-center is off from its true centroid by at most
            // half a tile-height — a small, bounded error — and the detector
            // doesn't reliably tell us which case we're in, so one rule for
            // both avoids a per-tile orientation branch that would just be
            // guessing anyway.
            let bottomCenter = SIMD2<Double>(tile.box.centerX, tile.box.y + tile.box.height)
            guard let local = projection.tablePoint(ofNormalizedOrientedPoint: bottomCenter,
                                                     orientedImageSize: orientedImageSize) else {
                return nil
            }
            // Anchor origin → table-space (0.5, 0.5); `local.y` holds the
            // plane's local z (see `TableProjection`'s doc comment).
            let nx = local.x / tableExtent + 0.5
            let nz = local.y / tableExtent + 0.5
            let box = TileBoundingBox(x: nx - w / 2, y: nz - h / 2, width: w, height: h)
            return DetectedTile(id: tile.id, tile: tile.tile, confidence: tile.confidence,
                                box: box, inReticle: tile.inReticle)
        }
    }
}
