import Foundation
import simd

public enum CalibrationSource: String, Sendable, Codable, Equatable {
    case guidedMarks
    case restoredWorldMap
    case manualRecenter
}

/// The single table-space contract shared by tracking, zoning, ROI planning,
/// overlays, and persistence. Local X/Z lie on the table; local +Z points from
/// the marked pond toward the user's hand row.
public struct WorldTableCalibration: Sendable, Equatable {
    public var tableToWorld: simd_float4x4
    public var extent: SIMD2<Float>
    public var pondPolygon: [SIMD2<Float>]
    public var handPolygon: [SIMD2<Float>]
    public var revealedZonePolygons: [SemanticZoneID: [SIMD2<Float>]]
    public var source: CalibrationSource

    public init(
        tableToWorld: simd_float4x4,
        extent: SIMD2<Float>,
        pondPolygon: [SIMD2<Float>],
        handPolygon: [SIMD2<Float>],
        revealedZonePolygons: [SemanticZoneID: [SIMD2<Float>]],
        source: CalibrationSource
    ) {
        self.tableToWorld = tableToWorld
        self.extent = extent
        self.pondPolygon = pondPolygon
        self.handPolygon = handPolygon
        self.revealedZonePolygons = revealedZonePolygons
        self.source = source
    }

    public var worldToTable: simd_float4x4 { simd_inverse(tableToWorld) }

    public var semanticZones: [SemanticZoneID: [SIMD2<Float>]] {
        var zones = revealedZonePolygons
        zones[.mineHand] = handPolygon
        zones[.tablePond] = pondPolygon
        return zones
    }

    /// Builds the canonical frame from marks expressed in the locked
    /// ARPlaneAnchor's local X/Z coordinates.
    public static func guided(
        planeTransform: simd_float4x4,
        handEndpoints: (SIMD2<Float>, SIMD2<Float>),
        pondPolygon: [SIMD2<Float>],
        revealedZoneCenters: [SemanticZoneID: SIMD2<Float>] = [:],
        source: CalibrationSource = .guidedMarks
    ) -> WorldTableCalibration? {
        guard pondPolygon.count >= 3 else { return nil }

        let pondCenter = pondPolygon.reduce(SIMD2<Float>.zero, +)
            / Float(pondPolygon.count)
        let handMidpoint = (handEndpoints.0 + handEndpoints.1) * 0.5
        let pondToHand = handMidpoint - pondCenter
        let pondHandDistance = simd_length(pondToHand)
        guard pondHandDistance.isFinite, pondHandDistance >= 0.150 else {
            return nil
        }

        var worldY = SIMD3<Float>(
            planeTransform.columns.1.x,
            planeTransform.columns.1.y,
            planeTransform.columns.1.z
        )
        guard simd_length_squared(worldY) > 1e-8 else { return nil }
        worldY = simd_normalize(worldY)
        if worldY.y < 0 { worldY = -worldY }

        let localZ = pondToHand / pondHandDistance
        let localZWorld4 = planeTransform * SIMD4(localZ.x, 0, localZ.y, 0)
        var worldZ = SIMD3<Float>(localZWorld4.x, localZWorld4.y, localZWorld4.z)
        worldZ -= worldY * simd_dot(worldZ, worldY)
        guard simd_length_squared(worldZ) > 1e-8 else { return nil }
        worldZ = simd_normalize(worldZ)
        let worldX = simd_normalize(simd_cross(worldY, worldZ))

        let origin4 = planeTransform * SIMD4(pondCenter.x, 0, pondCenter.y, 1)
        let tableToWorld = simd_float4x4(
            SIMD4(worldX, 0),
            SIMD4(worldY, 0),
            SIMD4(worldZ, 0),
            SIMD4(origin4.x, origin4.y, origin4.z, 1)
        )
        let planeToTable = simd_inverse(tableToWorld) * planeTransform
        func canonical(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let p = planeToTable * SIMD4(point.x, 0, point.y, 1)
            return SIMD2(p.x, p.z)
        }

        let canonicalPond = pondPolygon.map(canonical)
        let handA = canonical(handEndpoints.0)
        let handB = canonical(handEndpoints.1)
        let handWidth = simd_distance(handA, handB)
        let pondBounds = bounds(of: canonicalPond)
        let pondWidth = pondBounds.max.x - pondBounds.min.x
        let pondDepth = pondBounds.max.y - pondBounds.min.y
        let width = clamp(max(handWidth + 0.120, pondWidth + 0.240))
        let depth = clamp(max(pondHandDistance * 2 + 0.120, pondDepth + 0.240))
        let extent = SIMD2(width, depth)

        let halfWidth = width * 0.5
        let halfDepth = depth * 0.5
        let handInnerZ = min(handA.y, handB.y)
        let handPolygon = [
            SIMD2(-halfWidth, handInnerZ),
            SIMD2(halfWidth, handInnerZ),
            SIMD2(halfWidth, halfDepth),
            SIMD2(-halfWidth, halfDepth),
        ]

        // Deliberate 20 mm gaps leave ambiguous boundaries unresolved.
        let gap: Float = 0.020
        let nearPond = pondBounds.max.y + gap
        let farPond = pondBounds.min.y - gap
        let leftPond = pondBounds.min.x - gap
        let rightPond = pondBounds.max.x + gap
        let mineMeldMaxZ = handInnerZ - gap

        var revealed: [SemanticZoneID: [SIMD2<Float>]] = [
            .mineMeld: rect(
                minX: -halfWidth, maxX: halfWidth,
                minZ: min(nearPond, mineMeldMaxZ), maxZ: mineMeldMaxZ
            ),
            .tableRevealedLeft: rect(
                minX: -halfWidth, maxX: leftPond,
                minZ: -halfDepth, maxZ: halfDepth
            ),
            .tableRevealedFar: rect(
                minX: leftPond, maxX: rightPond,
                minZ: -halfDepth, maxZ: farPond
            ),
            .tableRevealedRight: rect(
                minX: rightPond, maxX: halfWidth,
                minZ: -halfDepth, maxZ: halfDepth
            ),
        ].filter { $0.value.count == 4 }
        for (zone, planeCenter) in revealedZoneCenters {
            guard [
                SemanticZoneID.tableRevealedLeft,
                .tableRevealedFar,
                .tableRevealedRight,
            ].contains(zone) else { continue }
            let center = canonical(planeCenter)
            let half = SIMD2<Float>(0.14, 0.06)
            revealed[zone] = rect(
                minX: max(-halfWidth, center.x - half.x),
                maxX: min(halfWidth, center.x + half.x),
                minZ: max(-halfDepth, center.y - half.y),
                maxZ: min(halfDepth, center.y + half.y)
            )
        }

        return WorldTableCalibration(
            tableToWorld: tableToWorld,
            extent: extent,
            pondPolygon: canonicalPond,
            handPolygon: handPolygon,
            revealedZonePolygons: revealed,
            source: source
        )
    }

    private static func bounds(
        of polygon: [SIMD2<Float>]
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        polygon.reduce(
            (SIMD2(repeating: Float.greatestFiniteMagnitude),
             SIMD2(repeating: -Float.greatestFiniteMagnitude))
        ) { result, point in
            (simd_min(result.0, point), simd_max(result.1, point))
        }
    }

    private static func rect(
        minX: Float, maxX: Float, minZ: Float, maxZ: Float
    ) -> [SIMD2<Float>] {
        guard minX < maxX, minZ < maxZ else { return [] }
        return [
            SIMD2(minX, minZ), SIMD2(maxX, minZ),
            SIMD2(maxX, maxZ), SIMD2(minX, maxZ),
        ]
    }

    private static func clamp(_ value: Float) -> Float {
        min(1.20, max(0.65, value))
    }
}
