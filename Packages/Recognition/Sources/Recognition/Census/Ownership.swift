import simd

/// §10.1: where a physical track's tiles get counted. Derived *after*
/// matching, purely from calibrated zone geometry.
public enum CensusBucket: Sendable, Hashable {
    case mine
    case table
    case ignored
    case unresolved
}

/// Resolves ownership from calibrated, anchor-local zone polygons. Pure
/// geometry: no function in this type takes a `TileFace`/`TileFaceHypothesis`
/// parameter, by design — "face identity never decides ownership" (§10.1) is
/// enforced by the type signature, not just by convention.
enum OwnershipResolver {
    /// Static geometric routing from a semantic zone to its bucket (§10.1).
    static func bucket(for zone: SemanticZoneID) -> CensusBucket {
        switch zone {
        case .mineHand, .mineMeld:
            return .mine
        case .tablePond, .tableRevealedLeft, .tableRevealedFar, .tableRevealedRight:
            return .table
        case .ignoredWall:
            return .ignored
        case .boundaryUnresolved:
            return .unresolved
        }
    }

    /// Resolves one track's bucket from its footprint against the calibrated
    /// zone polygons (anchor-local metres). Samples the footprint's center
    /// and, when it has a nonzero radius, four cardinal points on its
    /// boundary; if those samples disagree — the footprint straddles two
    /// zones, or part of it falls outside every zone — the track is
    /// `.unresolved` rather than guessed (§10.1: "footprint crossing an
    /// ownership boundary beyond tolerance → unresolved").
    static func resolve(center: SIMD2<Float>, footprintRadius: Float,
                        zones: [SemanticZoneID: [SIMD2<Float>]]) -> CensusBucket {
        let samples = samplePoints(center: center, radius: footprintRadius)
        var buckets: Set<CensusBucket> = []
        for point in samples {
            buckets.insert(bucketAtPoint(point, zones: zones))
        }
        return buckets.count == 1 ? buckets.first! : .unresolved
    }

    private static func bucketAtPoint(_ point: SIMD2<Float>,
                                      zones: [SemanticZoneID: [SIMD2<Float>]]) -> CensusBucket {
        var containingBuckets: Set<CensusBucket> = []
        for (zoneID, vertices) in zones where pointInPolygon(point, vertices: vertices) {
            containingBuckets.insert(bucket(for: zoneID))
        }
        // No zone claims the point, or two zones with different buckets both
        // claim it: either way, don't guess.
        guard containingBuckets.count == 1 else { return .unresolved }
        return containingBuckets.first!
    }

    private static func samplePoints(center: SIMD2<Float>, radius: Float) -> [SIMD2<Float>] {
        guard radius > 0 else { return [center] }
        return [
            center,
            center + SIMD2(radius, 0), center + SIMD2(-radius, 0),
            center + SIMD2(0, radius), center + SIMD2(0, -radius),
        ]
    }

    /// Even-odd ray-casting point-in-polygon test — the same rule as
    /// `ObservedPolygon.contains(_:)` (Chunk A), duplicated here because
    /// ownership zones arrive as raw anchor-local vertex arrays, not
    /// `ObservedPolygon`s (they describe the calibrated zone shape, not one
    /// frame's observed crop of it).
    private static func pointInPolygon(_ point: SIMD2<Float>, vertices: [SIMD2<Float>]) -> Bool {
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
