import simd
import Foundation

/// Builds a `TrackerConfig.TableGeometry` from a handful of coarse user marks
/// placed during ARKit table calibration. The marks are points in **anchor-local
/// plane metres** — exactly the space `TableProjection.tablePoint(...)` returns:
/// `SIMD2(x: local x, y: local z)`, origin at the plane anchor's centre, with
/// local **+z pointing toward the user** (ARTableCapture yaw-aligns the locked
/// plane so the user's edge is the high-z side).
///
/// The tracker's normalized table space maps from anchor-local metres as
/// `n = local / extent + 0.5` (see `DetectionProjector`), so the plane centre is
/// `(0.5, 0.5)` and the user's edge is `nz = 1`. `TableGeometry` carries only
/// three scalars — `extent`, `handBandDepth`, `pondRadius` — from which
/// `ZoneModel` derives every zone, so calibration only has to pin those three.
/// Everything here is pure simd math (no ARKit / platform types) and unit-tested.
public enum TableCalibrationGeometry {

    /// Sane physical bounds so a stray mark can never produce a degenerate
    /// geometry that breaks zone assignment downstream.
    public static let extentRange: ClosedRange<Double> = 0.40...1.60
    public static let handBandDepthRange: ClosedRange<Double> = 0.06...0.45
    public static let pondRadiusRange: ClosedRange<Double> = 0.10...0.45

    /// - Parameters:
    ///   - extentMetres: table size along the play axis (from marked corners or
    ///     the ARKit plane extent). `<= 0` falls back to the 0.9 m default.
    ///   - handBandInnerEdge: a point on the inner edge of the user's hand band
    ///     (the edge nearest the user). `handBandDepth` is how far that sits
    ///     inward from the user's `+z` edge, as a fraction of `extent`. `nil`
    ///     keeps the default depth.
    ///   - pondEdge: a point on the rim of the central pond. `pondRadius` is its
    ///     distance from the plane centre, as a fraction of `extent`. `nil`
    ///     keeps the default radius.
    public static func geometry(extentMetres: Double,
                                handBandInnerEdge: SIMD2<Double>?,
                                pondEdge: SIMD2<Double>?) -> TrackerConfig.TableGeometry {
        let defaults = TrackerConfig.TableGeometry()
        let extent = extentMetres > 0 ? extentMetres.clamped(to: extentRange) : defaults.extent

        let handBandDepth: Double
        if let edge = handBandInnerEdge {
            // edge.y is the local z of the mark; the user's edge is at
            // z = +extent/2, so the band's depth inward is that minus the mark.
            let depthMetres = extent / 2 - edge.y
            handBandDepth = (depthMetres / extent).clamped(to: handBandDepthRange)
        } else {
            handBandDepth = defaults.handBandDepth
        }

        let pondRadius: Double
        if let pond = pondEdge {
            let radiusMetres = (pond.x * pond.x + pond.y * pond.y).squareRoot()
            pondRadius = (radiusMetres / extent).clamped(to: pondRadiusRange)
        } else {
            pondRadius = defaults.pondRadius
        }

        return TrackerConfig.TableGeometry(extent: extent,
                                           handBandDepth: handBandDepth,
                                           pondRadius: pondRadius)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
