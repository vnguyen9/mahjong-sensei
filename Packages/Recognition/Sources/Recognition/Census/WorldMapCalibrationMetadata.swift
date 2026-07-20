import Foundation
import simd

/// Platform-neutral metadata stored beside ARKit's opaque world-map archive.
/// Tile identities and counts are deliberately absent. Version 2 stores the
/// exact guided polygons; version 1's transform/extent-only records are
/// intentionally rejected because they may describe the old plane centroid.
public struct WorldMapCalibrationMetadata: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var extentX: Float
    public var extentZ: Float
    public var pondPolygon: [Point]
    public var handPolygon: [Point]
    public var revealedZonePolygons: [SemanticZoneID: [Point]]
    public var calibrationSource: CalibrationSource

    public struct Point: Codable, Equatable, Sendable {
        public var x: Float
        public var z: Float

        public init(_ value: SIMD2<Float>) {
            x = value.x
            z = value.y
        }

        public var simd: SIMD2<Float> { SIMD2(x, z) }
    }

    public init(
        version: Int = Self.currentVersion,
        calibration: WorldTableCalibration
    ) {
        self.version = version
        extentX = calibration.extent.x
        extentZ = calibration.extent.y
        pondPolygon = calibration.pondPolygon.map(Point.init)
        handPolygon = calibration.handPolygon.map(Point.init)
        revealedZonePolygons = calibration.revealedZonePolygons.mapValues {
            $0.map(Point.init)
        }
        calibrationSource = calibration.source
    }

    public var validatedExtent: SIMD2<Float>? {
        guard version == Self.currentVersion,
              extentX.isFinite, extentZ.isFinite,
              (0.65 ... 1.20).contains(extentX),
              (0.65 ... 1.20).contains(extentZ) else {
            return nil
        }
        return SIMD2(extentX, extentZ)
    }

    public func validatedCalibration(
        tableToWorld: simd_float4x4,
        sourceOverride: CalibrationSource? = nil
    ) -> WorldTableCalibration? {
        guard let extent = validatedExtent,
              Self.isValid(polygon: pondPolygon, minimumCount: 3),
              Self.isValid(polygon: handPolygon, minimumCount: 3),
              revealedZonePolygons.allSatisfy({
                  Self.isValid(polygon: $0.value, minimumCount: 3)
              }),
              [
                  SemanticZoneID.mineMeld,
                  .tableRevealedLeft,
                  .tableRevealedFar,
                  .tableRevealedRight,
              ].allSatisfy({
                  revealedZonePolygons[$0]?.count ?? 0 >= 3
              }),
              (0 ..< 4).allSatisfy({
                  tableToWorld[$0].x.isFinite
                      && tableToWorld[$0].y.isFinite
                      && tableToWorld[$0].z.isFinite
                      && tableToWorld[$0].w.isFinite
              }) else {
            return nil
        }
        return WorldTableCalibration(
            tableToWorld: tableToWorld,
            extent: extent,
            pondPolygon: pondPolygon.map(\.simd),
            handPolygon: handPolygon.map(\.simd),
            revealedZonePolygons: revealedZonePolygons.mapValues {
                $0.map(\.simd)
            },
            source: sourceOverride ?? calibrationSource
        )
    }

    private static func isValid(
        polygon: [Point],
        minimumCount: Int
    ) -> Bool {
        polygon.count >= minimumCount && polygon.allSatisfy {
            $0.x.isFinite && $0.z.isFinite
                && abs($0.x) <= 1.20 && abs($0.z) <= 1.20
        }
    }
}
