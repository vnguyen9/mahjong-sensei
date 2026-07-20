import XCTest
import simd
@testable import Recognition

final class WorldTableCalibrationTests: XCTestCase {
    private let identity = matrix_identity_float4x4
    private let pond: [SIMD2<Float>] = [
        SIMD2(-0.10, -0.08), SIMD2(0.10, -0.08),
        SIMD2(0.10, 0.08), SIMD2(-0.10, 0.08),
    ]

    private func calibration(
        handEndpoints: (SIMD2<Float>, SIMD2<Float>) = (
            SIMD2(-0.30, 0.42), SIMD2(0.30, 0.42)
        ),
        revealedZoneCenters: [SemanticZoneID: SIMD2<Float>] = [:]
    ) throws -> WorldTableCalibration {
        try XCTUnwrap(WorldTableCalibration.guided(marks: GuidedTableMarks(
            planeTransform: identity,
            handEndpoints: handEndpoints,
            pondPolygon: pond,
            revealedZoneCenters: revealedZoneCenters
        )))
    }

    private func center(_ polygon: [SIMD2<Float>]) -> SIMD2<Float> {
        polygon.reduce(.zero, +) / Float(polygon.count)
    }

    private func bounds(_ polygon: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        polygon.reduce(
            (SIMD2(repeating: Float.greatestFiniteMagnitude),
             SIMD2(repeating: -Float.greatestFiniteMagnitude))
        ) { result, point in
            (simd_min(result.0, point), simd_max(result.1, point))
        }
    }

    func testGuidedMarksPlacePondCenterAtOriginAndHandAlongPositiveZ() throws {
        let calibration = try calibration()
        XCTAssertEqual(center(calibration.pondPolygon).x, 0, accuracy: 0.0001)
        XCTAssertEqual(center(calibration.pondPolygon).y, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(center(calibration.handPolygon).y, 0)
        XCTAssertEqual(calibration.tableToWorld.columns.2.z, 1, accuracy: 0.0001)
    }

    func testHandBandUsesActualEndpointsWith20mmEndPaddingAnd100mmDepth() throws {
        let calibration = try calibration()
        let expected: [SIMD2<Float>] = [
            SIMD2(-0.32, 0.37), SIMD2(0.32, 0.37),
            SIMD2(0.32, 0.47), SIMD2(-0.32, 0.47),
        ]
        for (actual, expected) in zip(calibration.handPolygon, expected) {
            XCTAssertEqual(actual.x, expected.x, accuracy: Float(0.0001))
            XCTAssertEqual(actual.y, expected.y, accuracy: Float(0.0001))
        }
    }

    func testOpponentRegionsAre20mmFromPondAndFollowSeatAxes() throws {
        let calibration = try calibration()
        let pondBounds = bounds(calibration.pondPolygon)
        let left = try XCTUnwrap(calibration.revealedZonePolygons[.tableRevealedLeft])
        let far = try XCTUnwrap(calibration.revealedZonePolygons[.tableRevealedFar])
        let right = try XCTUnwrap(calibration.revealedZonePolygons[.tableRevealedRight])

        let leftBounds = bounds(left)
        let farBounds = bounds(far)
        let rightBounds = bounds(right)
        XCTAssertEqual(pondBounds.min.x - leftBounds.max.x, 0.020, accuracy: 0.0001)
        XCTAssertEqual(pondBounds.min.y - farBounds.max.y, 0.020, accuracy: 0.0001)
        XCTAssertEqual(rightBounds.min.x - pondBounds.max.x, 0.020, accuracy: 0.0001)

        // Left/right rows are long along local Z; the far row is long along X.
        XCTAssertEqual(simd_distance(left[1], left[0]), 0.420, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(right[1], right[0]), 0.420, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(far[1], far[0]), 0.420, accuracy: 0.0001)
        XCTAssertEqual(left[1].x - left[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(right[1].x - right[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(far[1].y - far[0].y, 0, accuracy: 0.0001)
        XCTAssertEqual(abs(leftBounds.max.x - leftBounds.min.x), 0.100, accuracy: 0.0001)
        XCTAssertEqual(abs(farBounds.max.y - farBounds.min.y), 0.100, accuracy: 0.0001)
    }

    func testDraggedOpponentCenterTranslatesRegionWithoutRotatingIt() throws {
        let defaults = try calibration()
        let adjusted = try calibration(
            revealedZoneCenters: [.tableRevealedLeft: SIMD2(-0.50, 0.15)]
        )
        let defaultLeft = try XCTUnwrap(defaults.revealedZonePolygons[.tableRevealedLeft])
        let adjustedLeft = try XCTUnwrap(adjusted.revealedZonePolygons[.tableRevealedLeft])
        let delta = center(adjustedLeft) - center(defaultLeft)

        XCTAssertEqual(center(adjustedLeft).x, -0.50, accuracy: 0.0001)
        XCTAssertEqual(center(adjustedLeft).y, 0.15, accuracy: 0.0001)
        for index in defaultLeft.indices {
            XCTAssertEqual(adjustedLeft[index].x - defaultLeft[index].x, delta.x, accuracy: 0.0001)
            XCTAssertEqual(adjustedLeft[index].y - defaultLeft[index].y, delta.y, accuracy: 0.0001)
        }
        XCTAssertEqual(adjustedLeft[1].x - adjustedLeft[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(adjustedLeft[1], adjustedLeft[0]), 0.420, accuracy: 0.0001)
    }

    func testMineMeldStripIsParallelAndSeparatedInwardFromHand() throws {
        let calibration = try calibration()
        let mineMeld = try XCTUnwrap(calibration.revealedZonePolygons[.mineMeld])
        let handBounds = bounds(calibration.handPolygon)
        let meldBounds = bounds(mineMeld)

        XCTAssertEqual(simd_distance(mineMeld[1], mineMeld[0]), 0.640, accuracy: 0.0001)
        XCTAssertEqual(mineMeld[1].y - mineMeld[0].y, 0, accuracy: 0.0001)
        XCTAssertEqual(handBounds.min.y - meldBounds.max.y, 0.020, accuracy: 0.0001)
        XCTAssertLessThan(center(mineMeld).y, center(calibration.handPolygon).y)
    }

    func testExtentContainsEveryDerivedPolygonWithIndependentAxesAndPadding() throws {
        let result = try calibration()
        let polygons = [result.pondPolygon, result.handPolygon]
            + Array(result.revealedZonePolygons.values)
        for point in polygons.flatMap({ $0 }) {
            XCTAssertLessThanOrEqual(abs(point.x) + 0.060, result.extent.x * 0.5 + 0.0001)
            XCTAssertLessThanOrEqual(abs(point.y) + 0.060, result.extent.y * 0.5 + 0.0001)
        }
        XCTAssertNotEqual(result.extent.x, result.extent.y)

        let clamped = try calibration(
            handEndpoints: (SIMD2(-0.80, 0.80), SIMD2(0.80, 0.80))
        )
        XCTAssertEqual(clamped.extent.x, 1.20, accuracy: 0.0001)
        XCTAssertEqual(clamped.extent.y, 1.20, accuracy: 0.0001)
    }

    func testRejectsDegenerateOrTooCloseMarks() {
        XCTAssertNil(WorldTableCalibration.guided(marks: GuidedTableMarks(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.20, 0.10), SIMD2(0.20, 0.10)),
            pondPolygon: pond
        )))
        XCTAssertNil(WorldTableCalibration.guided(marks: GuidedTableMarks(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.20, 0.40), SIMD2(-0.20, 0.40)),
            pondPolygon: pond
        )))
        XCTAssertNil(WorldTableCalibration.guided(marks: GuidedTableMarks(
            planeTransform: identity,
            handEndpoints: (SIMD2(-0.20, 0.40), SIMD2(0.20, 0.40)),
            pondPolygon: []
        )))
    }

    func testExactPondPolygonFeedsSemanticZones() throws {
        let calibration = try calibration()
        XCTAssertEqual(calibration.semanticZones[.tablePond], calibration.pondPolygon)
        XCTAssertEqual(calibration.semanticZones[.mineHand], calibration.handPolygon)
    }
}
