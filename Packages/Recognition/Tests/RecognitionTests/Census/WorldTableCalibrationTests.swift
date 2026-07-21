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
        revealedZoneMarks: [SemanticZoneID: RevealedZoneMark] = [:],
        revealedZoneCenters: [SemanticZoneID: SIMD2<Float>] = [:]
    ) throws -> WorldTableCalibration {
        try XCTUnwrap(WorldTableCalibration.guided(marks: GuidedTableMarks(
            planeTransform: identity,
            handEndpoints: handEndpoints,
            pondPolygon: pond,
            revealedZoneMarks: revealedZoneMarks,
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
        // Each default strip uses its matching pond edge, not the unrelated
        // hand width. Left/right follow the pond's vertical edge; far follows
        // its horizontal edge.
        XCTAssertEqual(simd_distance(left[1], left[0]), 0.160, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(right[1], right[0]), 0.160, accuracy: 0.0001)
        XCTAssertEqual(simd_distance(far[1], far[0]), 0.200, accuracy: 0.0001)
        XCTAssertEqual(left[1].x - left[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(right[1].x - right[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(far[1].y - far[0].y, 0, accuracy: 0.0001)
        XCTAssertEqual(abs(leftBounds.max.x - leftBounds.min.x), 0.040, accuracy: 0.0001)
        XCTAssertEqual(abs(farBounds.max.y - farBounds.min.y), 0.040, accuracy: 0.0001)
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
        XCTAssertEqual(simd_distance(adjustedLeft[1], adjustedLeft[0]), 0.160, accuracy: 0.0001)
    }

    func testEndpointMarkControlsCenterLengthAndRotation() throws {
        let mark = RevealedZoneMark(
            start: SIMD2(-0.52, 0.10),
            end: SIMD2(-0.36, 0.22)
        )
        let calibration = try calibration(
            revealedZoneMarks: [.tableRevealedLeft: mark]
        )
        let stored = try XCTUnwrap(calibration.revealedZoneMarks[.tableRevealedLeft])
        let polygon = try XCTUnwrap(calibration.revealedZonePolygons[.tableRevealedLeft])

        XCTAssertEqual(stored.center.x, -0.44, accuracy: 0.0001)
        XCTAssertEqual(stored.center.y, 0.16, accuracy: 0.0001)
        XCTAssertEqual(stored.length, 0.20, accuracy: 0.0001)
        XCTAssertEqual(stored.depth, 0.040, accuracy: 0.0001)
        XCTAssertEqual(polygon.count, 4)
        XCTAssertGreaterThan(abs(polygon[1].x - polygon[0].x), 0.01)
        XCTAssertGreaterThan(abs(polygon[1].y - polygon[0].y), 0.01)
    }

    func testShortEndpointMarkIsExtendedTo72mmWithoutChangingCenterOrRotation() throws {
        let short = RevealedZoneMark(
            start: SIMD2(-0.40, 0.10),
            end: SIMD2(-0.37, 0.10)
        )
        let calibration = try calibration(
            revealedZoneMarks: [.tableRevealedLeft: short]
        )
        let stored = try XCTUnwrap(calibration.revealedZoneMarks[.tableRevealedLeft])

        XCTAssertEqual(stored.center.x, -0.385, accuracy: 0.0001)
        XCTAssertEqual(stored.center.y, 0.10, accuracy: 0.0001)
        XCTAssertEqual(stored.length, 0.072, accuracy: 0.0001)
        XCTAssertEqual(stored.end.y - stored.start.y, 0, accuracy: 0.0001)
    }

    func testClampingPreservesEndpointRotationAndKeepsPolygonInsideExtent() throws {
        let mark = RevealedZoneMark(
            start: SIMD2(-0.90, -0.20),
            end: SIMD2(0.90, 0.70)
        )
        let clamped = try XCTUnwrap(mark.clamped(to: SIMD2(0.80, 0.80)))
        let polygon = try XCTUnwrap(clamped.polygon())

        XCTAssertLessThanOrEqual(abs(clamped.center.x), 0.40)
        XCTAssertLessThanOrEqual(abs(clamped.center.y), 0.40)
        for point in polygon {
            XCTAssertLessThanOrEqual(abs(point.x), 0.40 + 0.0001)
            XCTAssertLessThanOrEqual(abs(point.y), 0.40 + 0.0001)
        }
        XCTAssertGreaterThanOrEqual(clamped.length, RevealedZoneMark.minimumLength)
    }

    func testTranslationClampPreservesCompleteStripShapeAtExtentEdge() throws {
        let mark = RevealedZoneMark(
            start: SIMD2(-0.18, -0.12),
            end: SIMD2(0.18, 0.12)
        )
        let moved = try XCTUnwrap(mark.translated(
            to: SIMD2(1.0, 1.0),
            within: SIMD2(0.80, 0.70)
        ))
        let polygon = try XCTUnwrap(moved.polygon())

        XCTAssertEqual(moved.length, mark.length, accuracy: 0.000_001)
        XCTAssertEqual(moved.depth, mark.depth, accuracy: 0.000_001)
        XCTAssertEqual(moved.longAxis?.x ?? 0, mark.longAxis?.x ?? 1, accuracy: 0.000_001)
        XCTAssertEqual(moved.longAxis?.y ?? 0, mark.longAxis?.y ?? 1, accuracy: 0.000_001)
        for point in polygon {
            XCTAssertLessThanOrEqual(abs(point.x), 0.400_1)
            XCTAssertLessThanOrEqual(abs(point.y), 0.350_1)
        }
    }

    func testTranslationRejectsStripThatCannotFitWithoutResizing() {
        let mark = RevealedZoneMark(
            start: SIMD2(-0.30, 0),
            end: SIMD2(0.30, 0)
        )
        XCTAssertNil(mark.translated(
            to: .zero,
            within: SIMD2(0.40, 0.40)
        ))
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

    func testTileDimensionsDefaultToStandardAndRemainPartOfCalibration() throws {
        let guided = try calibration()
        XCTAssertEqual(guided.tileDimensions, .standard)
        XCTAssertEqual(guided.tileDimensions.width, 0.024, accuracy: 0.000_001)
        XCTAssertEqual(guided.tileDimensions.length, 0.032, accuracy: 0.000_001)
        XCTAssertEqual(guided.tileDimensions.height, 0.016, accuracy: 0.000_001)

        let custom = PhysicalTileDimensions(width: 0.028, length: 0.036, height: 0.017)
        let direct = WorldTableCalibration(
            tableToWorld: identity,
            extent: SIMD2(0.80, 0.90),
            pondPolygon: pond,
            handPolygon: pond,
            revealedZonePolygons: [:],
            tileDimensions: custom,
            source: .guidedMarks
        )
        XCTAssertEqual(direct.tileDimensions, custom)
    }
}
