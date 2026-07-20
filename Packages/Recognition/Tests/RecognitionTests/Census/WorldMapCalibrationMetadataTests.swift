import XCTest
import simd
@testable import Recognition

final class WorldMapCalibrationMetadataTests: XCTestCase {
    func testCurrentMetadataRoundTripsAndValidates() throws {
        let calibration = Self.calibration()
        let metadata = WorldMapCalibrationMetadata(calibration: calibration)
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(
            WorldMapCalibrationMetadata.self,
            from: data
        )

        let restored = try XCTUnwrap(
            decoded.validatedCalibration(
                tableToWorld: calibration.tableToWorld,
                sourceOverride: .restoredWorldMap
            )
        )
        XCTAssertEqual(restored.extent, calibration.extent)
        XCTAssertEqual(restored.pondPolygon, calibration.pondPolygon)
        XCTAssertEqual(restored.handPolygon, calibration.handPolygon)
        XCTAssertEqual(
            restored.revealedZonePolygons,
            calibration.revealedZonePolygons
        )
        XCTAssertEqual(restored.source, .restoredWorldMap)
    }

    func testOldExtentOnlyVersionFallsBackToFreshCalibration() {
        let metadata = WorldMapCalibrationMetadata(
            version: 1,
            calibration: Self.calibration()
        )

        XCTAssertNil(metadata.validatedExtent)
        XCTAssertNil(
            metadata.validatedCalibration(tableToWorld: matrix_identity_float4x4)
        )
    }

    func testVersionTwoOuterPlaneGeometryFallsBackToFreshCalibration() {
        let metadata = WorldMapCalibrationMetadata(
            version: 2,
            calibration: Self.calibration()
        )

        XCTAssertNil(metadata.validatedExtent)
        XCTAssertNil(
            metadata.validatedCalibration(tableToWorld: matrix_identity_float4x4)
        )
    }

    func testInvalidExtentFallsBackToFreshCalibration() {
        var tooSmall = Self.calibration()
        tooSmall.extent = SIMD2(0.2, 0.9)
        XCTAssertNil(
            WorldMapCalibrationMetadata(calibration: tooSmall)
                .validatedExtent
        )
        var invalid = Self.calibration()
        invalid.extent = SIMD2(.nan, 0.9)
        XCTAssertNil(
            WorldMapCalibrationMetadata(calibration: invalid)
                .validatedExtent
        )
    }

    func testMissingExactPolygonFallsBackToFreshCalibration() {
        var metadata = WorldMapCalibrationMetadata(
            calibration: Self.calibration()
        )
        metadata.pondPolygon = []

        XCTAssertNil(
            metadata.validatedCalibration(tableToWorld: matrix_identity_float4x4)
        )
    }

    private static func calibration() -> WorldTableCalibration {
        func rect(
            _ minX: Float, _ minZ: Float,
            _ maxX: Float, _ maxZ: Float
        ) -> [SIMD2<Float>] {
            [
                SIMD2(minX, minZ), SIMD2(maxX, minZ),
                SIMD2(maxX, maxZ), SIMD2(minX, maxZ),
            ]
        }
        return WorldTableCalibration(
            tableToWorld: matrix_identity_float4x4,
            extent: SIMD2(0.82, 0.91),
            pondPolygon: rect(-0.15, -0.12, 0.15, 0.12),
            handPolygon: rect(-0.35, 0.30, 0.35, 0.45),
            revealedZonePolygons: [
                .mineMeld: rect(-0.35, 0.15, 0.35, 0.27),
                .tableRevealedLeft: rect(-0.41, -0.30, -0.20, 0.20),
                .tableRevealedFar: rect(-0.20, -0.45, 0.20, -0.25),
                .tableRevealedRight: rect(0.20, -0.30, 0.41, 0.20),
            ],
            source: .guidedMarks
        )
    }
}
