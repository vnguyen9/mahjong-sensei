import ImageIO
import XCTest
@testable import Recognition

final class ScanCameraOrientationTests: XCTestCase {
    func testRearCameraContractForEveryInterfacePose() {
        let expected: [(ScanCameraOrientation, CGImagePropertyOrientation, CGFloat)] = [
            (.portrait, .right, 90),
            (.portraitUpsideDown, .left, 270),
            (.landscapeLeft, .down, 180),
            (.landscapeRight, .up, 0),
        ]

        XCTAssertEqual(expected.map(\.0), ScanCameraOrientation.allCases)
        for (pose, imageOrientation, previewRotationAngle) in expected {
            XCTAssertEqual(pose.imageOrientation, imageOrientation)
            XCTAssertEqual(pose.previewRotationAngle, previewRotationAngle)
        }
    }
}
