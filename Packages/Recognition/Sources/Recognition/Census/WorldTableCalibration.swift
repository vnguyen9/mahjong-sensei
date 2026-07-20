import Foundation
import simd

public enum CalibrationSource: String, Sendable, Codable, Equatable {
    case guidedMarks
    case restoredWorldMap
    case manualRecenter
}

/// The raw marks collected during guided calibration. Every point is in the
/// locked AR plane's local X/Z coordinate system. Optional revealed-zone
/// centers are deliberate user adjustments, not detections of players.
public struct GuidedTableMarks: Sendable, Equatable {
    public var planeTransform: simd_float4x4
    public var handStart: SIMD2<Float>
    public var handEnd: SIMD2<Float>
    public var pondPolygon: [SIMD2<Float>]
    public var revealedZoneCenters: [SemanticZoneID: SIMD2<Float>]
    public var source: CalibrationSource

    public init(
        planeTransform: simd_float4x4,
        handEndpoints: (SIMD2<Float>, SIMD2<Float>),
        pondPolygon: [SIMD2<Float>],
        revealedZoneCenters: [SemanticZoneID: SIMD2<Float>] = [:],
        source: CalibrationSource = .guidedMarks
    ) {
        self.planeTransform = planeTransform
        handStart = handEndpoints.0
        handEnd = handEndpoints.1
        self.pondPolygon = pondPolygon
        self.revealedZoneCenters = revealedZoneCenters
        self.source = source
    }

    public var handEndpoints: (SIMD2<Float>, SIMD2<Float>) {
        (handStart, handEnd)
    }
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

    /// Builds the canonical table frame and exact region polygons from guided
    /// marks. The table origin is the pond center; the hand mark chooses +Z.
    /// No AR-plane extent enters this calculation: opponent marks, when
    /// supplied, translate their nearby default revealed regions only.
    public static func guided(
        marks: GuidedTableMarks
    ) -> WorldTableCalibration? {
        guard marks.pondPolygon.count >= 3 else { return nil }

        let pondCenter = marks.pondPolygon.reduce(SIMD2<Float>.zero, +)
            / Float(marks.pondPolygon.count)
        let handMidpoint = (marks.handStart + marks.handEnd) * 0.5
        let pondToHand = handMidpoint - pondCenter
        let pondHandDistance = simd_length(pondToHand)
        guard pondHandDistance.isFinite, pondHandDistance >= 0.150 else {
            return nil
        }

        var worldY = SIMD3<Float>(
            marks.planeTransform.columns.1.x,
            marks.planeTransform.columns.1.y,
            marks.planeTransform.columns.1.z
        )
        guard simd_length_squared(worldY) > 1e-8 else { return nil }
        worldY = simd_normalize(worldY)
        if worldY.y < 0 { worldY = -worldY }

        let localZ = pondToHand / pondHandDistance
        let localZWorld4 = marks.planeTransform * SIMD4(localZ.x, 0, localZ.y, 0)
        var worldZ = SIMD3<Float>(localZWorld4.x, localZWorld4.y, localZWorld4.z)
        worldZ -= worldY * simd_dot(worldZ, worldY)
        guard simd_length_squared(worldZ) > 1e-8 else { return nil }
        worldZ = simd_normalize(worldZ)
        let worldX = simd_normalize(simd_cross(worldY, worldZ))

        let origin4 = marks.planeTransform * SIMD4(pondCenter.x, 0, pondCenter.y, 1)
        let tableToWorld = simd_float4x4(
            SIMD4(worldX, 0),
            SIMD4(worldY, 0),
            SIMD4(worldZ, 0),
            SIMD4(origin4.x, origin4.y, origin4.z, 1)
        )
        let planeToTable = simd_inverse(tableToWorld) * marks.planeTransform
        func canonical(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let p = planeToTable * SIMD4(point.x, 0, point.y, 1)
            return SIMD2(p.x, p.z)
        }

        let canonicalPond = marks.pondPolygon.map(canonical)
        let canonicalPondCenter = canonicalPond.reduce(SIMD2<Float>.zero, +)
            / Float(canonicalPond.count)
        let handA = canonical(marks.handStart)
        let handB = canonical(marks.handEnd)
        let handVector = handB - handA
        let handWidth = simd_length(handVector)
        guard handWidth.isFinite, handWidth > 0.001 else { return nil }

        let handAxis = handVector / handWidth
        var handInward = SIMD2(-handAxis.y, handAxis.x)
        if simd_dot(handInward, canonicalPondCenter - (handA + handB) * 0.5) < 0 {
            handInward = -handInward
        }

        let handMid = (handA + handB) * 0.5
        let handPolygon = orientedRect(
            center: handMid,
            longAxis: handAxis,
            longLength: handWidth + 0.040,
            depth: 0.100
        )

        // The user-facing hand band and their exposed-tile strip deliberately
        // leave a 20 mm no-owner boundary. The strip follows the *actual*
        // hand row, so a slightly angled mark stays angled everywhere.
        let mineMeld = orientedRect(
            center: handMid + handInward * 0.120,
            longAxis: handAxis,
            longLength: handWidth + 0.040,
            depth: 0.100
        )

        let pondBounds = bounds(of: canonicalPond)
        let opponentLength = min(0.420, max(0.280, handWidth))
        let gap: Float = 0.020
        let revealedDepth: Float = 0.100
        let halfDepth = revealedDepth * 0.5

        let defaultCenters: [SemanticZoneID: SIMD2<Float>] = [
            .tableRevealedLeft: SIMD2(
                pondBounds.min.x - gap - halfDepth,
                canonicalPondCenter.y
            ),
            .tableRevealedFar: SIMD2(
                canonicalPondCenter.x,
                pondBounds.min.y - gap - halfDepth
            ),
            .tableRevealedRight: SIMD2(
                pondBounds.max.x + gap + halfDepth,
                canonicalPondCenter.y
            ),
        ]
        let longAxes: [SemanticZoneID: SIMD2<Float>] = [
            .tableRevealedLeft: SIMD2(0, 1),
            .tableRevealedFar: SIMD2(1, 0),
            .tableRevealedRight: SIMD2(0, 1),
        ]

        var revealed: [SemanticZoneID: [SIMD2<Float>]] = [
            .mineMeld: mineMeld,
        ]
        for zone in [
            SemanticZoneID.tableRevealedLeft,
            .tableRevealedFar,
            .tableRevealedRight,
        ] {
            guard let defaultCenter = defaultCenters[zone],
                  let longAxis = longAxes[zone] else { continue }
            let adjustedCenter: SIMD2<Float>
            if let markedCenter = marks.revealedZoneCenters[zone] {
                // A dragged marker moves its whole region; its seat-relative
                // orientation and dimensions cannot accidentally rotate.
                adjustedCenter = canonical(markedCenter)
            } else {
                adjustedCenter = defaultCenter
            }
            revealed[zone] = orientedRect(
                center: adjustedCenter,
                longAxis: longAxis,
                longLength: opponentLength,
                depth: revealedDepth
            )
        }

        let allPolygons = [canonicalPond, handPolygon] + Array(revealed.values)
        let extent = extentContaining(polygons: allPolygons, padding: 0.060)

        return WorldTableCalibration(
            tableToWorld: tableToWorld,
            extent: extent,
            pondPolygon: canonicalPond,
            handPolygon: handPolygon,
            revealedZonePolygons: revealed,
            source: marks.source
        )
    }

    /// Compatibility entry point for existing call sites. New production code
    /// should construct `GuidedTableMarks` explicitly so it is clear which
    /// values are user marks and which regions are derived.
    public static func guided(
        planeTransform: simd_float4x4,
        handEndpoints: (SIMD2<Float>, SIMD2<Float>),
        pondPolygon: [SIMD2<Float>],
        revealedZoneCenters: [SemanticZoneID: SIMD2<Float>] = [:],
        source: CalibrationSource = .guidedMarks
    ) -> WorldTableCalibration? {
        guided(marks: GuidedTableMarks(
            planeTransform: planeTransform,
            handEndpoints: handEndpoints,
            pondPolygon: pondPolygon,
            revealedZoneCenters: revealedZoneCenters,
            source: source
        ))
    }

    private static func orientedRect(
        center: SIMD2<Float>,
        longAxis: SIMD2<Float>,
        longLength: Float,
        depth: Float
    ) -> [SIMD2<Float>] {
        let halfLong = longLength * 0.5
        let halfDepth = depth * 0.5
        let crossAxis = SIMD2(-longAxis.y, longAxis.x)
        return [
            center - longAxis * halfLong - crossAxis * halfDepth,
            center + longAxis * halfLong - crossAxis * halfDepth,
            center + longAxis * halfLong + crossAxis * halfDepth,
            center - longAxis * halfLong + crossAxis * halfDepth,
        ]
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

    private static func extentContaining(
        polygons: [[SIMD2<Float>]],
        padding: Float
    ) -> SIMD2<Float> {
        let points = polygons.flatMap { $0 }
        let bounds = bounds(of: points)
        let halfX = max(abs(bounds.min.x), abs(bounds.max.x)) + padding
        let halfZ = max(abs(bounds.min.y), abs(bounds.max.y)) + padding
        return SIMD2(clamp(halfX * 2), clamp(halfZ * 2))
    }

    private static func clamp(_ value: Float) -> Float {
        min(1.20, max(0.65, value))
    }
}
