import XCTest
@testable import Recognition

final class TileFootprintDepthEvidenceTests: XCTestCase {
    func testBarePlaneRequiresAtLeastThreeTrustworthySamples() {
        XCTAssertEqual(
            TileFootprintDepthClassifier.classify(
                tableHeights: [0.001, -0.002],
                cameraDepthDeltas: [0, 0]
            ),
            .unknown
        )
        XCTAssertEqual(
            TileFootprintDepthClassifier.classify(
                tableHeights: [-0.002, 0.001, 0.006, 0.010],
                cameraDepthDeltas: [0, 0.001, -0.001, 0]
            ),
            .barePlane
        )
    }

    func testOccupiedPatchNeverQualifiesAsEmpty() {
        XCTAssertEqual(
            TileFootprintDepthClassifier.classify(
                tableHeights: [0.018, 0.021, 0.024, 0.026],
                cameraDepthDeltas: [-0.020, -0.021, -0.024, -0.026]
            ),
            .occupied
        )
        XCTAssertEqual(
            TileFootprintDepthClassifier.classify(
                tableHeights: [0, 0.001, -0.002, 0.003, 0.020],
                cameraDepthDeltas: [0, 0, 0, 0, -0.020]
            ),
            .occupied,
            "one trustworthy standing-tile sample must hold the identity"
        )
    }

    func testGeometryMoreThanFortyMillimetersNearerIsOcclusion() {
        XCTAssertEqual(
            TileFootprintDepthClassifier.classify(
                tableHeights: [0.001, 0.003, 0.004, 0.006],
                cameraDepthDeltas: [-0.010, -0.041, -0.012, -0.009]
            ),
            .occluded
        )
    }

    func testInconsistentOrHighPatchRemainsUnknown() {
        XCTAssertEqual(
            TileFootprintDepthClassifier.classify(
                tableHeights: [-0.020, 0.002, 0.055, 0.080],
                cameraDepthDeltas: [0, 0, 0, 0]
            ),
            .unknown
        )
    }
}
