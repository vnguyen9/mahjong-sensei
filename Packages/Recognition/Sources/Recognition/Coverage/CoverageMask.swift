import Foundation
import simd

/// A semantic region of the calibrated table (§4.3). Ownership decisions only
/// ever consult which zone(s) covered a track's footprint — never a tile's
/// classified face (§10.1: "ownership is geometric").
public enum SemanticZoneID: Sendable, Hashable, CaseIterable {
    case mineHand
    case mineMeld
    case tablePond
    case tableRevealedLeft
    case tableRevealedFar
    case tableRevealedRight
    case ignoredWall
    case boundaryUnresolved
}

/// One frame's observed footprint of a semantic zone, in anchor-local metres.
/// A `CoverageMask` is a *set* of these, not a bounding box (§5.2): two
/// disjoint crops of the same zone stay two separate polygons.
public struct ObservedPolygon: Sendable, Hashable {
    public var zoneID: SemanticZoneID
    public var vertices: [SIMD2<Float>]
    public var frameID: FrameID
    public var observedAt: TimeInterval
    public var quality: FrameQuality

    public init(zoneID: SemanticZoneID,
                vertices: [SIMD2<Float>],
                frameID: FrameID,
                observedAt: TimeInterval,
                quality: FrameQuality) {
        self.zoneID = zoneID
        self.vertices = vertices
        self.frameID = frameID
        self.observedAt = observedAt
        self.quality = quality
    }

    /// Ray-casting (even-odd rule) point-in-polygon test, pure and
    /// independent of every other polygon in a ``CoverageMask``. Points
    /// exactly on an edge or vertex are implementation-defined (as with any
    /// ray-casting test); callers needing an exact answer there should not
    /// rely on it.
    public func contains(_ point: SIMD2<Float>) -> Bool {
        guard vertices.count >= 3 else { return false }
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
}

/// The set of everywhere the camera has actually observed this session —
/// never a bounding box. §5.2: "no AABB union may bridge an unobserved gap."
public struct CoverageMask: Sendable {
    public var regions: [ObservedPolygon]

    public init(regions: [ObservedPolygon] = []) {
        self.regions = regions
    }

    /// True iff ANY single polygon independently contains `point`. Two
    /// disjoint regions never combine to cover the gap between them.
    public func covers(_ point: SIMD2<Float>) -> Bool {
        regions.contains { $0.contains(point) }
    }

    /// Every polygon that independently covers `point` (there may be more
    /// than one, e.g. overlapping observations from different frames).
    public func regionsCovering(_ point: SIMD2<Float>) -> [ObservedPolygon] {
        regions.filter { $0.contains(point) }
    }
}
