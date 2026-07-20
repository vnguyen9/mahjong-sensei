import simd
import Foundation
import MahjongCore

/// Builds a `TrackerConfig.TableGeometry` from a handful of coarse user marks
/// placed during ARKit table calibration. The marks are points in **anchor-local
/// plane metres** — exactly the space `TableProjection.tablePoint(...)` returns:
/// `SIMD2(x: local x, y: local z)`, origin at the plane anchor's centre, with
/// local **+z pointing toward the user** (ARTableCapture yaw-aligns the locked
/// plane so the user's edge is the high-z side).
///
/// The tracker's normalized table space maps from anchor-local metres as
/// `n = local / extent + 0.5` (see `DetectionProjector`), so the plane centre is
/// `(0.5, 0.5)` and the user's edge is `nz = 1`. The hand row is an **oriented**
/// band: two end-posts pinch-dropped along the row give a near-edge line that
/// may tilt, plus a depth. The pond stays a single rim point. Seats and the
/// three opponent meld bands are synthesized from the plane edges + the user's
/// seat wind. Everything here is pure simd math (no ARKit / platform types) and
/// unit-tested.
public enum TableCalibrationGeometry {

    /// Sane physical bounds so a stray mark can never produce a degenerate
    /// geometry that breaks zone assignment downstream.
    public static let extentRange: ClosedRange<Double> = 0.40...1.60
    public static let handBandDepthRange: ClosedRange<Double> = 0.06...0.45
    public static let pondRadiusRange: ClosedRange<Double> = 0.10...0.45

    /// Primary producer — a two-post oriented hand band + pond + seats.
    ///
    /// - Parameters:
    ///   - extentMetres: table size along the play axis (marked corners or the
    ///     ARKit plane extent). `<= 0` falls back to the 0.9 m default.
    ///   - handPostA/handPostB: the two end-posts of the user's row, in
    ///     anchor-local metres (`SIMD2(x: local x, y: local z)`). Their mean
    ///     inset from the user's `+z` edge sets `depth`; their tilt sets the
    ///     band's angle. Either `nil` → treated as a single-post (or default)
    ///     full-width band, preserving the old single-mark behavior.
    ///   - pondCornerA/pondCornerB: two opposite corners of the pond, in
    ///     anchor-local metres → an **axis-aligned rectangle** in table space
    ///     (off-centre ponds need this). If only one is given it degrades to
    ///     the legacy centred disk (radius = its distance from centre); both
    ///     `nil` keeps the default disk.
    ///   - pondQuad: 4 ordered corners of a refined pond, in anchor-local
    ///     metres. When present it **overrides** `pondCornerA/B` → an arbitrary
    ///     `PondShape.quad` (a rotated/irregular pond the axis-aligned rect
    ///     can't cover).
    ///   - mySeatWind: the user's seat wind, used to label the 4 seats.
    ///   - seatMidpoints: user-dragged opponent seat midpoints (anchor-local
    ///     metres), for `.left`/`.right`/`.across` only. When present, each
    ///     given seat's auto meld band + `SeatSlot.edgeMidpoint` are
    ///     repositioned to hug that midpoint instead of the default plane-edge
    ///     midpoint. `nil` (the default) leaves the auto-placed seats/bands
    ///     untouched — byte-identical to the pre-edit-mode behavior.
    public static func geometry(extentMetres: Double,
                                handPostA: SIMD2<Double>?,
                                handPostB: SIMD2<Double>?,
                                pondCornerA: SIMD2<Double>?,
                                pondCornerB: SIMD2<Double>?,
                                pondQuad: [SIMD2<Double>]? = nil,
                                mySeatWind: Wind = .east,
                                seatMidpoints: [RelativeSeat: SIMD2<Double>]? = nil) -> TrackerConfig.TableGeometry {
        let defaults = TrackerConfig.TableGeometry()
        let extent = extentMetres > 0 ? extentMetres.clamped(to: extentRange) : defaults.extent

        // Normalize the posts (nil → the other, or both nil → no band info).
        let a = handPostA ?? handPostB
        let b = handPostB ?? handPostA
        var depth = defaults.handBandDepth
        var handBand: TrackerConfig.OrientedBand?
        if let a, let b {
            let na = SIMD2(a.x / extent + 0.5, a.y / extent + 0.5)
            let nb = SIMD2(b.x / extent + 0.5, b.y / extent + 0.5)
            depth = (1 - (na.y + nb.y) / 2).clamped(to: handBandDepthRange)
            // Shift the post line to the user edge (nz≈1) preserving its tilt,
            // then extrapolate to full table width for the near edge.
            let sa = SIMD2(na.x, na.y + depth), sb = SIMD2(nb.x, nb.y + depth)
            if abs(sa.x - sb.x) < 1e-6 {
                handBand = TrackerConfig.OrientedBand(a: SIMD2(0, 1), b: SIMD2(1, 1), depth: depth)
            } else {
                let m = (sb.y - sa.y) / (sb.x - sa.x)
                let za = sa.y + m * (0 - sa.x), zb = sa.y + m * (1 - sa.x)
                handBand = TrackerConfig.OrientedBand(a: SIMD2(0, za), b: SIMD2(1, zb), depth: depth)
            }
        }

        // Pond: two corners → an axis-aligned rect (normalized, clamped to the
        // table and a sane minimum size); one corner → the legacy centred disk;
        // none → the default disk.
        let pond: TrackerConfig.PondShape
        func norm(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2((p.x / extent + 0.5).clamped(to: 0...1), (p.y / extent + 0.5).clamped(to: 0...1))
        }
        if let quad = pondQuad, quad.count == 4 {
            pond = .quad(corners: quad.map(norm))
        } else if let ca = pondCornerA, let cb = pondCornerB {
            let na = norm(ca), nb = norm(cb)
            var mn = SIMD2(Swift.min(na.x, nb.x), Swift.min(na.y, nb.y))
            var mx = SIMD2(Swift.max(na.x, nb.x), Swift.max(na.y, nb.y))
            // Enforce a minimum footprint around the box centre so a near-zero
            // drag can't collapse the pond to a line.
            let minSide = 2 * pondRadiusRange.lowerBound   // 0.20 of extent
            if mx.x - mn.x < minSide {
                let c = (mn.x + mx.x) / 2
                mn.x = (c - minSide / 2).clamped(to: 0...1); mx.x = (c + minSide / 2).clamped(to: 0...1)
            }
            if mx.y - mn.y < minSide {
                let c = (mn.y + mx.y) / 2
                mn.y = (c - minSide / 2).clamped(to: 0...1); mx.y = (c + minSide / 2).clamped(to: 0...1)
            }
            pond = .rect(min: mn, max: mx)
        } else if let single = pondCornerA ?? pondCornerB {
            let radiusMetres = (single.x * single.x + single.y * single.y).squareRoot()
            let r = (radiusMetres / extent).clamped(to: pondRadiusRange)
            pond = .disk(center: SIMD2(0.5, 0.5), radius: r)
        } else {
            pond = defaults.pond
        }

        // Start from the legacy init (seats + axis-aligned meld bands at the
        // same depth), then swap in the oriented hand band + pond region.
        var g = TrackerConfig.TableGeometry(extent: extent, handBandDepth: depth,
                                            mySeatWind: mySeatWind)
        if let handBand { g.handBand = handBand }
        g.pond = pond

        // Opponent seats dragged to arbitrary positions during "Edit layout":
        // reposition that seat's meld band + edge midpoint to hug the new
        // location instead of the default plane-edge midpoint.
        if let seatMidpoints {
            for seat: RelativeSeat in [.left, .right, .across] {
                guard let m = seatMidpoints[seat] else { continue }
                let nm = SIMD2((m.x / extent + 0.5).clamped(to: 0...1), (m.y / extent + 0.5).clamped(to: 0...1))
                let d = SIMD2(0.5 - nm.x, 0.5 - nm.y)
                let length = (d.x * d.x + d.y * d.y).squareRoot()
                guard length >= 1e-6 else { continue }
                let du = SIMD2(d.x / length, d.y / length)
                let perp = SIMD2(-du.y, du.x)
                let a = SIMD2(nm.x - 0.5 * perp.x, nm.y - 0.5 * perp.y)
                let b = SIMD2(nm.x + 0.5 * perp.x, nm.y + 0.5 * perp.y)
                g.meldBands[seat] = TrackerConfig.OrientedBand(a: a, b: b, depth: g.handBandDepth)
                if let idx = g.seats.firstIndex(where: { $0.seat == seat }) {
                    g.seats[idx].edgeMidpoint = nm
                }
            }
        }
        return g
    }

    /// The whole-table **auto-partition** layout — the AR default. Unlike
    /// `geometry(...)`, it takes NO user marks: it is generated purely in
    /// normalized table space (central pond rect + the four player regions
    /// filling the rest), so it is correct in the live locked-plane frame *by
    /// construction* — no cross-session transfer of positional corners (the bug
    /// that threw the pinch-calibrated pond into the wrong quadrant). Zoning
    /// (`ZoneModel`, `.partition` layout) assigns every non-pond tile to the
    /// nearest table edge, so there are no `.unresolved` gaps.
    ///
    /// - Parameters:
    ///   - extentMetres: physical metres the normalized [0,1] range spans (the
    ///     live plane extent). `<= 0` → the 0.9 m default.
    ///   - mySeatWind: the user's seat wind, to label the 4 seats.
    ///   - pondHalfWidth/pondHalfDepth: half-size of the central pond rect as a
    ///     fraction of extent (default 0.22 → pond spans the central
    ///     [0.28, 0.72] on each axis, matching the mockup's large centre pond).
    ///     The player regions (hand band + 3 meld bands, for the overlay) fill
    ///     from each edge inward to meet the pond, closing the old moat.
    public static func autoPartition(extentMetres: Double,
                                     mySeatWind: Wind = .east,
                                     pondHalfWidth: Double = 0.22,
                                     pondHalfDepth: Double = 0.22) -> TrackerConfig.TableGeometry {
        let defaults = TrackerConfig.TableGeometry()
        let extent = extentMetres > 0 ? extentMetres.clamped(to: extentRange) : defaults.extent
        // Central pond rect. Half-sizes clamped so the rect stays a sensible
        // centre region (never collapsing, never swallowing a whole edge).
        let hw = pondHalfWidth.clamped(to: 0.10...0.40)
        let hd = pondHalfDepth.clamped(to: 0.10...0.40)
        let mn = SIMD2(0.5 - hw, 0.5 - hd), mx = SIMD2(0.5 + hw, 0.5 + hd)

        // Start from the legacy init for seats/winds, then override every zone.
        var g = TrackerConfig.TableGeometry(extent: extent, mySeatWind: mySeatWind)
        g.pond = .rect(min: mn, max: mx)
        // Player regions reach from each edge inward to the pond (overlay only —
        // `.partition` zoning uses pond + nearest-edge, not these bands).
        g.handBand = TrackerConfig.OrientedBand(a: SIMD2(0, 1), b: SIMD2(1, 1), depth: 0.5 - hd)
        g.meldBands = [
            .left: TrackerConfig.OrientedBand(a: SIMD2(0, 0), b: SIMD2(0, 1), depth: 0.5 - hw),
            .right: TrackerConfig.OrientedBand(a: SIMD2(1, 0), b: SIMD2(1, 1), depth: 0.5 - hw),
            .across: TrackerConfig.OrientedBand(a: SIMD2(0, 0), b: SIMD2(1, 0), depth: 0.5 - hd),
        ]
        g.layout = .partition
        return g
    }

    /// Back-compat single-mark convenience — the inner-edge point is used as
    /// both posts, yielding a full-width horizontal band at the old depth.
    public static func geometry(extentMetres: Double,
                                handBandInnerEdge: SIMD2<Double>?,
                                pondEdge: SIMD2<Double>?) -> TrackerConfig.TableGeometry {
        geometry(extentMetres: extentMetres,
                 handPostA: handBandInnerEdge, handPostB: handBandInnerEdge,
                 pondCornerA: pondEdge, pondCornerB: nil)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
