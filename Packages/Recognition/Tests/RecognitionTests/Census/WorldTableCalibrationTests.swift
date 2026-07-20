import XCTest
import simd
@testable import Recognition

final class WorldTableCalibrationTests: XCTestCase {
    private let identity = matrix_identity_float4x4
    private let pond: [SIMD2<Float>] = [
        SIMD2(-0.10, -0.08), SIMD2(0.10, -0.08),
        SIMD2(0.10, 0.08), SIMD2(-0.10, 0.08),
    ]

    func testGuidedMarksPlacePondCenterAtOriginAndHandAlongPositiveZ() throws {
        let calibration = try XCTUnwrap(WorldTableCalibration.guided(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.30, 0.42), SIMD2(0.30, 0.42)),
            pondPolygon: pond
        ))

        let pondCenter = calibration.pondPolygon.reduce(.zero, +)
            / Float(calibration.pondPolygon.count)
        XCTAssertEqual(pondCenter.x, 0, accuracy: 0.0001)
        XCTAssertEqual(pondCenter.y, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(calibration.handPolygon.map(\.y).max() ?? 0, 0)
        XCTAssertEqual(calibration.tableToWorld.columns.2.z, 1, accuracy: 0.0001)
    }

    func testExtentDerivationPreservesIndependentAxesAndClamps() throws {
        let calibration = try XCTUnwrap(WorldTableCalibration.guided(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.25, 0.20), SIMD2(0.25, 0.20)),
            pondPolygon: pond
        ))
        XCTAssertEqual(calibration.extent.x, 0.65, accuracy: 0.0001)
        XCTAssertEqual(calibration.extent.y, 0.65, accuracy: 0.0001)

        let large = try XCTUnwrap(WorldTableCalibration.guided(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.80, 0.80), SIMD2(0.80, 0.80)),
            pondPolygon: pond
        ))
        XCTAssertEqual(large.extent.x, 1.20, accuracy: 0.0001)
        XCTAssertEqual(large.extent.y, 1.20, accuracy: 0.0001)
    }

    func testRejectsDegenerateOrTooCloseMarks() {
        XCTAssertNil(WorldTableCalibration.guided(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.20, 0.10), SIMD2(0.20, 0.10)),
            pondPolygon: pond
        ))
        XCTAssertNil(WorldTableCalibration.guided(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.20, 0.40), SIMD2(0.20, 0.40)),
            pondPolygon: []
        ))
    }

    func testExactPondPolygonFeedsSemanticZones() throws {
        let calibration = try XCTUnwrap(WorldTableCalibration.guided(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.30, 0.42), SIMD2(0.30, 0.42)),
            pondPolygon: pond
        ))
        XCTAssertEqual(calibration.semanticZones[.tablePond], calibration.pondPolygon)
        XCTAssertEqual(calibration.semanticZones[.mineHand], calibration.handPolygon)
    }
}
