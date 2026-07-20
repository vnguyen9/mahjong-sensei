import XCTest
import simd
@testable import Recognition

final class WorldProjectionTests: XCTestCase {
    func test_depthUnprojectionAndProjectionRoundTrip() throws {
        let intrinsics = simd_double3x3(
            SIMD3(1000, 0, 0),
            SIMD3(0, 1000, 0),
            SIMD3(500, 500, 1)
        )
        let projection = TableProjection(
            cameraTransform: matrix_identity_double4x4,
            intrinsics: intrinsics,
            imageResolution: SIMD2(1000, 1000),
            planeTransform: matrix_identity_double4x4
        )

        let world = try XCTUnwrap(
            projection.worldPoint(
                ofNormalizedOrientedPoint: SIMD2(0.5, 0.5),
                orientedImageSize: SIMD2(1000, 1000),
                depthMeters: 2
            )
        )
        XCTAssertEqual(world.x, 0, accuracy: 1e-9)
        XCTAssertEqual(world.y, 0, accuracy: 1e-9)
        XCTAssertEqual(world.z, -2, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(projection.cameraAxisDepth(ofWorldPoint: world)),
            2,
            accuracy: 1e-9
        )

        let imagePoint = try XCTUnwrap(
            projection.normalizedOrientedPoint(
                ofWorldPoint: world,
                orientedImageSize: SIMD2(1000, 1000)
            )
        )
        XCTAssertEqual(imagePoint.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(imagePoint.y, 0.5, accuracy: 1e-9)
    }

    func test_nonPositiveOrBehindCameraDepthIsRejected() {
        let projection = TableProjection(
            cameraTransform: matrix_identity_double4x4,
            intrinsics: matrix_identity_double3x3,
            imageResolution: SIMD2(10, 10),
            planeTransform: matrix_identity_double4x4
        )
        XCTAssertNil(
            projection.worldPoint(
                ofNormalizedOrientedPoint: SIMD2(0.5, 0.5),
                orientedImageSize: SIMD2(10, 10),
                depthMeters: 0
            )
        )
        XCTAssertNil(projection.cameraAxisDepth(ofWorldPoint: SIMD3(0, 0, 1)))
    }
}
