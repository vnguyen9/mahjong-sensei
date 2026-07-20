import XCTest
import simd
@testable import Recognition

final class TableOriginStateTests: XCTestCase {
    func test_initialYawFacesCameraAndUsesPlaneHeight() {
        var plane = matrix_identity_float4x4
        plane.columns.3 = SIMD4(2, 0.75, 3, 1)
        let origin = TableOriginState(
            lockedPlaneTransform: plane,
            lockedExtent: 0.9,
            cameraPosition: SIMD3(2, 1.2, 4),
            at: 0
        )
        XCTAssertEqual(origin.tableToWorld.columns.3.y, 0.75, accuracy: 0.0001)
        XCTAssertGreaterThan(origin.tableToWorld.columns.2.z, 0.99)
    }

    func test_eightTracksInitializeMedianAndClampedExtent() {
        var origin = TableOriginState(
            lockedPlaneTransform: matrix_identity_float4x4,
            lockedExtent: 1.1,
            cameraPosition: SIMD3(0, 1, 1),
            at: 0
        )
        let points = (0..<8).map {
            SIMD3<Float>(Float($0) * 0.04 - 0.14, 0, Float($0 % 2) * 0.1)
        }
        XCTAssertTrue(origin.updateAutoFit(confirmedWorldPositions: points, at: 1))
        XCTAssertTrue(origin.hasTileCloudFit)
        XCTAssertEqual(origin.extent.x, 0.65, accuracy: 0.0001)
        XCTAssertEqual(origin.extent.y, 0.65, accuracy: 0.0001)
    }

    func test_autoFitExpandsButNeverShrinksThenFreezes() {
        var origin = TableOriginState(
            lockedPlaneTransform: matrix_identity_float4x4,
            lockedExtent: 0.9,
            cameraPosition: SIMD3(0, 1, 1),
            at: 0
        )
        let compact = (0..<8).map { SIMD3<Float>(Float($0) * 0.05, 0, 0) }
        _ = origin.updateAutoFit(confirmedWorldPositions: compact, at: 1)
        let initial = origin.extent
        let smaller = Array(repeating: SIMD3<Float>(0, 0, 0), count: 8)
        _ = origin.updateAutoFit(confirmedWorldPositions: smaller, at: 2)
        XCTAssertEqual(origin.extent, initial)
        XCTAssertFalse(origin.updateAutoFit(confirmedWorldPositions: compact, at: 30))
        XCTAssertTrue(origin.isFrozen)
    }

    func test_manualRecenterDisablesAutoFitForSession() {
        var origin = TableOriginState(
            lockedPlaneTransform: matrix_identity_float4x4,
            lockedExtent: 0.9,
            cameraPosition: SIMD3(0, 1, 1),
            at: 0
        )
        origin.recenterPond(at: SIMD3(0.25, 9, -0.4))
        XCTAssertEqual(origin.tableToWorld.columns.3.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(origin.tableToWorld.columns.3.y, 0, accuracy: 0.0001)
        XCTAssertEqual(origin.tableToWorld.columns.3.z, -0.4, accuracy: 0.0001)
        XCTAssertTrue(origin.autoFitDisabled)
        XCTAssertTrue(origin.isFrozen)
    }
}
