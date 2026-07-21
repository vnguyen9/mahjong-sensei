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

    /// Center-first ownership keeps a tile stable when its measured footprint
    /// jitters across a boundary. A center inside exactly one polygon wins.
    /// Outside all polygons, a uniquely nearest edge may snap within the
    /// measured-tile tolerance; overlaps and equal-distance ambiguity remain
    /// unresolved.
    static func resolve(center: SIMD2<Float>, footprintRadius: Float,
                        zones: [SemanticZoneID: [SIMD2<Float>]]) -> CensusBucket {
        bucket(for: semanticZone(center: center, footprintRadius: footprintRadius, zones: zones))
    }

    static func semanticZone(center: SIMD2<Float>, footprintRadius: Float,
                             zones: [SemanticZoneID: [SIMD2<Float>]]) -> SemanticZoneID {
        let containing = zones.compactMap { zone, vertices in
            pointInPolygon(center, vertices: vertices) ? zone : nil
        }
        guard containing.count <= 1 else { return .boundaryUnresolved }
        if let zone = containing.first { return zone }

        let tolerance = min(0.008, max(0, footprintRadius * 2 / 3))
        guard tolerance > 0 else { return .boundaryUnresolved }
        let distances = zones.map { zone, vertices in
            (zone, distance(center, to: vertices))
        }.sorted {
            if abs($0.1 - $1.1) > 0.000_001 { return $0.1 < $1.1 }
            return String(describing: $0.0) < String(describing: $1.0)
        }
        guard let nearest = distances.first, nearest.1 <= tolerance else {
            return .boundaryUnresolved
        }
        if distances.count > 1,
           abs(distances[1].1 - nearest.1) <= 0.000_001 {
            return .boundaryUnresolved
        }
        return nearest.0
    }

    private static func distance(
        _ point: SIMD2<Float>,
        to polygon: [SIMD2<Float>]
    ) -> Float {
        guard polygon.count >= 2 else { return .infinity }
        var result = Float.infinity
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let edge = end - start
            let denominator = simd_length_squared(edge)
            let t = denominator > 0
                ? min(1, max(0, simd_dot(point - start, edge) / denominator))
                : 0
            result = min(result, simd_distance(point, start + edge * t))
        }
        return result
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
