import XCTest
@testable import Recognition

final class WorldMapCalibrationMetadataTests: XCTestCase {
    func testCurrentMetadataRoundTripsAndValidates() throws {
        let metadata = WorldMapCalibrationMetadata(extent: SIMD2(0.82, 0.91))
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(
            WorldMapCalibrationMetadata.self,
            from: data
        )

        XCTAssertEqual(decoded.validatedExtent, SIMD2(0.82, 0.91))
    }

    func testUnknownVersionFallsBackToFreshCalibration() {
        let metadata = WorldMapCalibrationMetadata(
            version: WorldMapCalibrationMetadata.currentVersion + 1,
            extent: SIMD2(0.82, 0.91)
        )

        XCTAssertNil(metadata.validatedExtent)
    }

    func testInvalidExtentFallsBackToFreshCalibration() {
        XCTAssertNil(
            WorldMapCalibrationMetadata(extent: SIMD2(0.2, 0.9))
                .validatedExtent
        )
        XCTAssertNil(
            WorldMapCalibrationMetadata(extent: SIMD2(.nan, 0.9))
                .validatedExtent
        )
    }
}
