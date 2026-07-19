import Foundation
import simd

/// Builds the table quadrilateral proposal (Technical design §4.2) from
/// plane boundary geometry and raycast tile footpoints, both already
/// expressed in the candidate plane's own anchor-local (x, z) frame — packed
/// exactly like `Recognition.TableProjection`'s documented convention,
/// `SIMD2(x: local x, y: local z)` (see that type's doc). Pure `simd` math:
/// no `ARKit`, no `Recognition` import, so every piece here is
/// synthesizable/testable with hand-built points, independent of any live
/// AR session.
public enum TableQuadProposal {

    /// One raycast tile footpoint candidate — a 3D anchor-local point where
    /// `.y` is the raycast hit's height OFFSET from the idealized plane
    /// (0 = exactly on the analytic plane model; a real hit-test against
    /// ARKit's plane/mesh geometry can differ slightly from that idealized
    /// model) and `.x`/`.z` is its in-plane position. Packing the offset
    /// alongside the in-plane position — rather than assuming it's always
    /// exactly 0 — is what lets step 3's "farther than 3cm from the plane
    /// model" gate mean something; the caller does the actual raycasting
    /// (ARKit-adjacent geometry this pure type deliberately stays
    /// independent of) and hands in the resulting 3D point.
    public struct Footpoint {
        public var anchorLocalPoint: SIMD3<Float>

        public init(anchorLocalPoint: SIMD3<Float>) { self.anchorLocalPoint = anchorLocalPoint }

        var inPlane: SIMD2<Float> { SIMD2(anchorLocalPoint.x, anchorLocalPoint.z) }
        var offPlaneDistance: Float { abs(anchorLocalPoint.y) }
    }

    /// Four corners, anchor-local metres, in a fixed winding order — see
    /// `corners`'s doc. `CalibratedTable` and `TableCalibrationView` both
    /// read this order directly.
    public struct Proposal {
        /// Order: near-left (closest to the user's confirmed edge, on the
        /// left), near-right, far-right, far-left — walking the rectangle
        /// starting at the near-left corner, going right along the user
        /// edge, then away across the table, then back along the far edge.
        public var corners: [SIMD2<Float>]

        public init(corners: [SIMD2<Float>]) { self.corners = corners }
    }

    public static let maxOffPlaneDistance: Float = 0.03
    public static let maxOutsideBoundaryDistance: Float = 0.08
    public static let tileOnlyExpansion: Float = 0.08
    public static let minSideLength: Float = 0.60
    public static let maxSideLength: Float = 1.40

    /// Builds the proposal (§4.2 steps 1-7).
    ///
    /// - `planeBoundary`: `ARPlaneAnchor.geometry.boundaryVertices` mapped to
    ///   anchor-local (x, z) by the caller — empty/degenerate (<3 points)
    ///   when no boundary geometry is available or trusted yet.
    /// - `footpoints`: raycast tile bottom-center/lower-corner hits (§4.2
    ///   step 2), already expressed anchor-local.
    /// - `userEdgeDirection`: the in-plane (x, z) direction — need not be
    ///   normalized — from roughly the table's center toward the user's
    ///   confirmed edge (step 7's yaw target; e.g. the vector toward the
    ///   session-start camera ground position). A near-zero vector leaves
    ///   the rectangle's existing (arbitrary) orientation unchanged rather
    ///   than divide by ~0.
    ///
    /// Returns `nil` when there isn't enough evidence to fit any rectangle
    /// at all (no boundary AND fewer than 3 supported footpoints) — the
    /// caller keeps sweeping rather than show a fabricated quad.
    public static func propose(planeBoundary: [SIMD2<Float>],
                               footpoints: [Footpoint],
                               userEdgeDirection: SIMD2<Float>) -> Proposal? {
        let supportedFootpoints = footpoints.filter { fp in
            guard fp.offPlaneDistance <= maxOffPlaneDistance else { return false }
            return distance(fp.inPlane, toPolygon: planeBoundary) <= maxOutsideBoundaryDistance
        }.map(\.inPlane)

        let hasBoundary = planeBoundary.count >= 3
        var points: [SIMD2<Float>] = hasBoundary ? planeBoundary : []
        points.append(contentsOf: supportedFootpoints)
        guard points.count >= 3, var rect = minimumAreaRectangle(of: points) else { return nil }

        // Tile-only bounds (no usable plane boundary) get expanded so edge
        // tiles aren't clipped (step 5) — only when there was no boundary to
        // anchor the proposal to begin with.
        if !hasBoundary {
            rect = rect.expanded(by: tileOnlyExpansion)
        }

        rect = rect.clamped(min: minSideLength, max: maxSideLength)
        rect = rect.yawAligned(toward: userEdgeDirection)

        return Proposal(corners: rect.corners)
    }

    // MARK: - Oriented rectangle

    /// An oriented rectangle in anchor-local (x, z): a center, half-extents
    /// along its own two axes, and the axes themselves (unit vectors).
    private struct OrientedRect {
        var center: SIMD2<Float>
        var halfExtentA: Float
        var halfExtentB: Float
        var axisA: SIMD2<Float>
        var axisB: SIMD2<Float>

        /// Near-left, near-right, far-right, far-left — `axisB` is treated
        /// as "+Z/near-far" and `axisA` as "+X/left-right" (true once
        /// `yawAligned` has run; before that, the labels are arbitrary but
        /// the winding is still consistent).
        var corners: [SIMD2<Float>] {
            [center - axisA * halfExtentA + axisB * halfExtentB,   // near-left
             center + axisA * halfExtentA + axisB * halfExtentB,   // near-right
             center + axisA * halfExtentA - axisB * halfExtentB,   // far-right
             center - axisA * halfExtentA - axisB * halfExtentB]   // far-left
        }

        func expanded(by margin: Float) -> OrientedRect {
            var r = self
            r.halfExtentA += margin
            r.halfExtentB += margin
            return r
        }

        func clamped(min minSide: Float, max maxSide: Float) -> OrientedRect {
            var r = self
            r.halfExtentA = min(max(r.halfExtentA * 2, minSide), maxSide) / 2
            r.halfExtentB = min(max(r.halfExtentB * 2, minSide), maxSide) / 2
            return r
        }

        /// Re-derives which local axis is "+Z" (toward the user) without
        /// changing shape/center (step 7): picks whichever of A/B already
        /// points closer to `direction` as the new Z axis, flips its sign if
        /// it points away, then re-derives X as Z rotated -90° so the pair
        /// stays an orthonormal (x, z) basis.
        func yawAligned(toward direction: SIMD2<Float>) -> OrientedRect {
            guard simd_length(direction) > 1e-6 else { return self }
            let dir = simd_normalize(direction)
            let alignA = abs(simd_dot(axisA, dir))
            let alignB = abs(simd_dot(axisB, dir))
            var newZAxis = alignA >= alignB ? axisA : axisB
            let newZHalf = alignA >= alignB ? halfExtentA : halfExtentB
            let newXHalf = alignA >= alignB ? halfExtentB : halfExtentA
            if simd_dot(newZAxis, dir) < 0 { newZAxis = -newZAxis }
            let newXAxis = SIMD2<Float>(newZAxis.y, -newZAxis.x)

            var r = self
            r.axisA = newXAxis
            r.halfExtentA = newXHalf
            r.axisB = newZAxis
            r.halfExtentB = newZHalf
            return r
        }
    }

    /// Rotating-calipers oriented minimum-area bounding rectangle (step 4).
    /// Falls back to an axis-aligned box when the input is too degenerate to
    /// form a real hull edge (collinear points, or fewer than 3 unique
    /// points after hull reduction).
    private static func minimumAreaRectangle(of points: [SIMD2<Float>]) -> OrientedRect? {
        guard !points.isEmpty else { return nil }
        guard let hull = convexHull(points), hull.count >= 3 else {
            return axisAlignedRect(of: points)
        }

        var best: OrientedRect?
        var bestArea = Float.infinity
        for i in 0..<hull.count {
            let p0 = hull[i], p1 = hull[(i + 1) % hull.count]
            let edge = p1 - p0
            guard simd_length(edge) > 1e-9 else { continue }
            let axisB = simd_normalize(edge)             // candidate local "along the edge"
            let axisA = SIMD2<Float>(axisB.y, -axisB.x)   // perpendicular

            var minA = Float.infinity, maxA = -Float.infinity
            var minB = Float.infinity, maxB = -Float.infinity
            for p in hull {
                let a = simd_dot(p, axisA), b = simd_dot(p, axisB)
                minA = min(minA, a); maxA = max(maxA, a)
                minB = min(minB, b); maxB = max(maxB, b)
            }
            let area = (maxA - minA) * (maxB - minB)
            guard area < bestArea else { continue }
            bestArea = area
            let center = axisA * ((minA + maxA) / 2) + axisB * ((minB + maxB) / 2)
            best = OrientedRect(center: center, halfExtentA: (maxA - minA) / 2, halfExtentB: (maxB - minB) / 2,
                                axisA: axisA, axisB: axisB)
        }
        return best ?? axisAlignedRect(of: points)
    }

    private static func axisAlignedRect(of points: [SIMD2<Float>]) -> OrientedRect? {
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return OrientedRect(center: SIMD2((minX + maxX) / 2, (minY + maxY) / 2),
                            halfExtentA: max(0, (maxX - minX) / 2), halfExtentB: max(0, (maxY - minY) / 2),
                            axisA: SIMD2(1, 0), axisB: SIMD2(0, 1))
    }

    /// Monotone-chain convex hull. Returns `nil` for fewer than 3 input
    /// points or fully collinear input (no 2D hull to rotate calipers
    /// against).
    private static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>]? {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return nil }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        return hull.count >= 3 ? hull : nil
    }

    // MARK: - Boundary distance

    /// Distance from `point` to the polygon `boundary` — 0 if inside (even-
    /// odd point-in-polygon test), else the distance to the nearest edge
    /// segment. An empty/degenerate boundary (fewer than 3 vertices) returns
    /// `.infinity` so callers with no real boundary never reject on it (a
    /// tile-only proposal can't fail the "outside the boundary" gate).
    private static func distance(_ point: SIMD2<Float>, toPolygon boundary: [SIMD2<Float>]) -> Float {
        guard boundary.count >= 3 else { return .infinity }
        if pointInPolygon(point, boundary) { return 0 }
        var best = Float.infinity
        for i in 0..<boundary.count {
            let a = boundary[i], b = boundary[(i + 1) % boundary.count]
            best = min(best, distance(point, toSegment: a, b))
        }
        return best
    }

    private static func pointInPolygon(_ point: SIMD2<Float>, _ vertices: [SIMD2<Float>]) -> Bool {
        var inside = false
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let vi = vertices[i], vj = vertices[j]
            if (vi.y > point.y) != (vj.y > point.y) {
                let edgeX = (vj.x - vi.x) * (point.y - vi.y) / (vj.y - vi.y) + vi.x
                if point.x < edgeX { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func distance(_ point: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_dot(ab, ab)
        guard lengthSquared > 1e-12 else { return simd_distance(point, a) }
        let t = min(1, max(0, simd_dot(point - a, ab) / lengthSquared))
        let projected = a + ab * t
        return simd_distance(point, projected)
    }
}
