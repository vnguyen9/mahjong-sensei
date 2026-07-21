import Foundation
import simd

public enum CalibrationSource: String, Sendable, Codable, Equatable {
    case guidedMarks
    case restoredWorldMap
    case manualRecenter
}

/// Physical dimensions used by the world census. These are deliberately part
/// of the table calibration rather than a detector setting: one table's tile
/// footprint is shared by association, empty-space evidence, crop margins,
/// and presentation geometry.
public struct PhysicalTileDimensions: Sendable, Equatable {
    public var width: Float
    public var length: Float
    public var height: Float

    public static let standard = PhysicalTileDimensions(
        width: 0.024,
        length: 0.032,
        height: 0.016
    )

    public init(width: Float, length: Float, height: Float) {
        self.width = width
        self.length = length
        self.height = height
    }

    /// The existing census represents a tile footprint as a circular radius.
    /// Use half the short edge so neighboring 24 mm tiles stay separable.
    public var footprintRadius: Float { max(0, width * 0.5) }
}

public enum PhysicalTileDimensionsSource: String, Sendable, Equatable {
    case standard
    case measured
    case manual
}

/// An editable exposed-tile strip expressed by its two long-edge endpoints in
/// table-plane coordinates. The strip's depth is deliberately fixed by the
/// calibration UI; moving either endpoint changes both its length and yaw
/// without turning the mark into a freeform quadrilateral.
public struct RevealedZoneMark: Sendable, Equatable {
    public static let fixedDepth: Float = 0.040
    public static let minimumLength: Float = 0.072

    public var start: SIMD2<Float>
    public var end: SIMD2<Float>
    public var depth: Float

    public init(
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        depth: Float = RevealedZoneMark.fixedDepth
    ) {
        self.start = start
        self.end = end
        self.depth = depth
    }

    public var center: SIMD2<Float> { (start + end) * 0.5 }

    public var length: Float { simd_length(end - start) }

    /// Returns the endpoint direction when the mark is geometrically valid.
    public var longAxis: SIMD2<Float>? {
        let vector = end - start
        let length = simd_length(vector)
        guard length.isFinite, length > 0.000_001 else { return nil }
        return vector / length
    }

    /// Enforces the product minimum without changing the mark's center or
    /// rotation. Invalid/non-finite marks are rejected rather than guessed.
    public func enforcingMinimumLength(
        minimumLength: Float = RevealedZoneMark.minimumLength
    ) -> RevealedZoneMark? {
        guard start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite,
              depth.isFinite, depth > 0,
              minimumLength.isFinite, minimumLength > 0,
              let axis = longAxis else {
            return nil
        }
        let enforcedLength = max(length, minimumLength)
        let halfLength = enforcedLength * 0.5
        return RevealedZoneMark(
            start: center - axis * halfLength,
            end: center + axis * halfLength,
            depth: depth
        )
    }

    /// Returns the exact rectangular polygon represented by the endpoints.
    /// Callers use this single result for rendering, zoning, and ROI planning.
    public func polygon(
        minimumLength: Float = RevealedZoneMark.minimumLength
    ) -> [SIMD2<Float>]? {
        guard let mark = enforcingMinimumLength(minimumLength: minimumLength),
              let axis = mark.longAxis else { return nil }
        let halfLength = mark.length * 0.5
        let halfDepth = mark.depth * 0.5
        let crossAxis = SIMD2(-axis.y, axis.x)
        return [
            mark.center - axis * halfLength - crossAxis * halfDepth,
            mark.center + axis * halfLength - crossAxis * halfDepth,
            mark.center + axis * halfLength + crossAxis * halfDepth,
            mark.center - axis * halfLength + crossAxis * halfDepth,
        ]
    }

    /// Clamps a mark to a rectangular calibrated table extent while preserving
    /// its center-relative yaw and fixed depth. If the requested rotation
    /// cannot fit the minimum 72 mm length, no edit is produced.
    public func clamped(
        to extent: SIMD2<Float>,
        minimumLength: Float = RevealedZoneMark.minimumLength
    ) -> RevealedZoneMark? {
        guard extent.x.isFinite, extent.y.isFinite,
              extent.x > 0, extent.y > 0,
              let mark = enforcingMinimumLength(minimumLength: minimumLength),
              let axis = mark.longAxis else { return nil }

        let halfExtent = extent * 0.5
        let crossAxis = SIMD2(-axis.y, axis.x)
        // Reserve room for the fixed strip depth before fitting the endpoints.
        let endpointBounds = halfExtent - SIMD2(abs(crossAxis.x), abs(crossAxis.y)) * (mark.depth * 0.5)
        guard endpointBounds.x > 0, endpointBounds.y > 0 else { return nil }
        let clampedCenter = simd_min(endpointBounds, simd_max(-endpointBounds, mark.center))
        let availableHalfLengthX = axis.x == 0
            ? Float.greatestFiniteMagnitude
            : min(
                (endpointBounds.x - clampedCenter.x) / abs(axis.x),
                (endpointBounds.x + clampedCenter.x) / abs(axis.x)
            )
        let availableHalfLengthZ = axis.y == 0
            ? Float.greatestFiniteMagnitude
            : min(
                (endpointBounds.y - clampedCenter.y) / abs(axis.y),
                (endpointBounds.y + clampedCenter.y) / abs(axis.y)
            )
        let maximumLength = max(0, 2 * min(availableHalfLengthX, availableHalfLengthZ))
        guard maximumLength >= minimumLength else { return nil }
        let length = min(mark.length, maximumLength)
        return RevealedZoneMark(
            start: clampedCenter - axis * (length * 0.5),
            end: clampedCenter + axis * (length * 0.5),
            depth: mark.depth
        )
    }

    /// Translates the complete strip inside a calibrated rectangular extent
    /// without changing its length, yaw, or depth. This is intentionally
    /// separate from ``clamped(to:minimumLength:)``: endpoint editing may
    /// shorten an overlong strip, but dragging a region body must never make
    /// the user's carefully sized mark change shape near a table edge.
    public func translated(
        to requestedCenter: SIMD2<Float>,
        within extent: SIMD2<Float>
    ) -> RevealedZoneMark? {
        guard requestedCenter.x.isFinite, requestedCenter.y.isFinite,
              extent.x.isFinite, extent.y.isFinite,
              extent.x > 0, extent.y > 0,
              let mark = enforcingMinimumLength(),
              let axis = mark.longAxis else { return nil }

        let crossAxis = SIMD2(-axis.y, axis.x)
        let requiredHalfExtent =
            SIMD2(abs(axis.x), abs(axis.y)) * (mark.length * 0.5)
            + SIMD2(abs(crossAxis.x), abs(crossAxis.y)) * (mark.depth * 0.5)
        let centerBounds = extent * 0.5 - requiredHalfExtent
        guard centerBounds.x >= 0, centerBounds.y >= 0 else { return nil }

        let center = simd_min(centerBounds, simd_max(-centerBounds, requestedCenter))
        let halfLength = mark.length * 0.5
        return RevealedZoneMark(
            start: center - axis * halfLength,
            end: center + axis * halfLength,
            depth: mark.depth
        )
    }
}

/// The raw marks collected during guided calibration. Every point is in the
/// locked AR plane's local X/Z coordinate system. Optional revealed-zone
/// endpoint marks are deliberate user adjustments, not detections of players.
public struct GuidedTableMarks: Sendable, Equatable {
    public var planeTransform: simd_float4x4
    public var handStart: SIMD2<Float>
    public var handEnd: SIMD2<Float>
    public var pondPolygon: [SIMD2<Float>]
    /// Endpoint controls for the three opponent exposed-tile regions. These
    /// points are in the locked plane's local X/Z system until `guided` turns
    /// them into canonical table-local marks.
    public var revealedZoneMarks: [SemanticZoneID: RevealedZoneMark]
    /// Compatibility input for the former center-only editor. New code must
    /// use `revealedZoneMarks`, which can retain the user's chosen length and
    /// rotation.
    public var revealedZoneCenters: [SemanticZoneID: SIMD2<Float>]
    public var source: CalibrationSource

    public init(
        planeTransform: simd_float4x4,
        handEndpoints: (SIMD2<Float>, SIMD2<Float>),
        pondPolygon: [SIMD2<Float>],
        revealedZoneMarks: [SemanticZoneID: RevealedZoneMark] = [:],
        revealedZoneCenters: [SemanticZoneID: SIMD2<Float>] = [:],
        source: CalibrationSource = .guidedMarks
    ) {
        self.planeTransform = planeTransform
        handStart = handEndpoints.0
        handEnd = handEndpoints.1
        self.pondPolygon = pondPolygon
        self.revealedZoneMarks = revealedZoneMarks
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
    /// Exact, table-local endpoint marks from which the opponent polygons were
    /// made. Keeping these alongside the resulting polygons makes edits and
    /// persistence deterministic without a second geometry reconstruction.
    public var revealedZoneMarks: [SemanticZoneID: RevealedZoneMark]
    public var revealedZonePolygons: [SemanticZoneID: [SIMD2<Float>]]
    /// Defaults preserve existing calibrated tables until the optional tile
    /// measurement step supplies a table-specific value.
    public var tileDimensions: PhysicalTileDimensions
    public var tileDimensionsSource: PhysicalTileDimensionsSource
    public var source: CalibrationSource

    public init(
        tableToWorld: simd_float4x4,
        extent: SIMD2<Float>,
        pondPolygon: [SIMD2<Float>],
        handPolygon: [SIMD2<Float>],
        revealedZoneMarks: [SemanticZoneID: RevealedZoneMark] = [:],
        revealedZonePolygons: [SemanticZoneID: [SIMD2<Float>]],
        tileDimensions: PhysicalTileDimensions = .standard,
        tileDimensionsSource: PhysicalTileDimensionsSource = .standard,
        source: CalibrationSource
    ) {
        self.tableToWorld = tableToWorld
        self.extent = extent
        self.pondPolygon = pondPolygon
        self.handPolygon = handPolygon
        self.revealedZoneMarks = revealedZoneMarks
        self.revealedZonePolygons = revealedZonePolygons
        self.tileDimensions = tileDimensions
        self.tileDimensionsSource = tileDimensionsSource
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

        var revealed: [SemanticZoneID: [SIMD2<Float>]] = [
            .mineMeld: mineMeld,
        ]
        var canonicalMarks = defaultRevealedZoneMarks(around: canonicalPond)
        for zone in [
            SemanticZoneID.tableRevealedLeft,
            .tableRevealedFar,
            .tableRevealedRight,
        ] {
            guard let fallback = canonicalMarks[zone] else { continue }
            let selected: RevealedZoneMark?
            if let rawMark = marks.revealedZoneMarks[zone] {
                selected = RevealedZoneMark(
                    start: canonical(rawMark.start),
                    end: canonical(rawMark.end),
                    depth: rawMark.depth
                ).enforcingMinimumLength()
            } else if let legacyCenter = marks.revealedZoneCenters[zone],
                      let axis = fallback.longAxis {
                // Maintain old center-only marks until the calibration view
                // migrates. They inherit the seat-relative default size and
                // orientation; only real endpoint marks may rotate or resize.
                let center = canonical(legacyCenter)
                selected = RevealedZoneMark(
                    start: center - axis * (fallback.length * 0.5),
                    end: center + axis * (fallback.length * 0.5),
                    depth: fallback.depth
                ).enforcingMinimumLength()
            } else {
                selected = fallback.enforcingMinimumLength()
            }
            guard let mark = selected, let polygon = mark.polygon() else { continue }
            canonicalMarks[zone] = mark
            revealed[zone] = polygon
        }

        let allPolygons = [canonicalPond, handPolygon] + Array(revealed.values)
        let extent = extentContaining(polygons: allPolygons, padding: 0.060)

        return WorldTableCalibration(
            tableToWorld: tableToWorld,
            extent: extent,
            pondPolygon: canonicalPond,
            handPolygon: handPolygon,
            revealedZoneMarks: canonicalMarks,
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
        revealedZoneMarks: [SemanticZoneID: RevealedZoneMark] = [:],
        revealedZoneCenters: [SemanticZoneID: SIMD2<Float>] = [:],
        source: CalibrationSource = .guidedMarks
    ) -> WorldTableCalibration? {
        guided(marks: GuidedTableMarks(
            planeTransform: planeTransform,
            handEndpoints: handEndpoints,
            pondPolygon: pondPolygon,
            revealedZoneMarks: revealedZoneMarks,
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

    /// Default opponent strips sit 20 mm beyond the matching pond edge. Their
    /// long dimension is the length of that pond edge and their narrow
    /// dimension is the fixed 40 mm exposed-tile depth.
    public static func defaultRevealedZoneMarks(
        around pondPolygon: [SIMD2<Float>]
    ) -> [SemanticZoneID: RevealedZoneMark] {
        guard pondPolygon.count >= 3 else { return [:] }
        let pondBounds = bounds(of: pondPolygon)
        let pondCenter = pondPolygon.reduce(SIMD2<Float>.zero, +)
            / Float(pondPolygon.count)
        let verticalLength = max(
            RevealedZoneMark.minimumLength,
            pondBounds.max.y - pondBounds.min.y
        )
        let horizontalLength = max(
            RevealedZoneMark.minimumLength,
            pondBounds.max.x - pondBounds.min.x
        )
        let gap: Float = 0.020
        let halfDepth = RevealedZoneMark.fixedDepth * 0.5

        func mark(
            center: SIMD2<Float>,
            axis: SIMD2<Float>,
            length: Float
        ) -> RevealedZoneMark {
            RevealedZoneMark(
                start: center - axis * (length * 0.5),
                end: center + axis * (length * 0.5),
                depth: RevealedZoneMark.fixedDepth
            )
        }

        return [
            .tableRevealedLeft: mark(
                center: SIMD2(pondBounds.min.x - gap - halfDepth, pondCenter.y),
                axis: SIMD2(0, 1),
                length: verticalLength
            ),
            .tableRevealedFar: mark(
                center: SIMD2(pondCenter.x, pondBounds.min.y - gap - halfDepth),
                axis: SIMD2(1, 0),
                length: horizontalLength
            ),
            .tableRevealedRight: mark(
                center: SIMD2(pondBounds.max.x + gap + halfDepth, pondCenter.y),
                axis: SIMD2(0, 1),
                length: verticalLength
            ),
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
