import ImageIO
import XCTest
import simd
@testable import Recognition

final class FrameImageTransformTests: XCTestCase {
    func testRawOrientedRoundTripsForEverySupportedIPadOrientation() {
        let orientations: [CGImagePropertyOrientation] = [.right, .left, .up, .down]
        let points = [
            SIMD2<Double>(0, 0), SIMD2(1, 1),
            SIMD2(0.19, 0.73), SIMD2(0.82, 0.11),
        ]

        for orientation in orientations {
            let transform = FrameImageTransform(
                imageOrientation: orientation,
                imageResolution: CGSize(width: 1920, height: 1440)
            )
            for point in points {
                let raw = transform.rawNormalized(fromOriented: point)
                let recovered = transform.orientedNormalized(fromRaw: raw)
                XCTAssertEqual(recovered.x, point.x, accuracy: 1e-12)
                XCTAssertEqual(recovered.y, point.y, accuracy: 1e-12)
            }
        }
    }

    func testOrientedSizeSwapsOnlyForQuarterTurns() {
        XCTAssertEqual(
            FrameImageTransform(
                imageOrientation: .right,
                imageResolution: CGSize(width: 1920, height: 1440)
            ).orientedImageSize,
            CGSize(width: 1440, height: 1920)
        )
        XCTAssertEqual(
            FrameImageTransform(
                imageOrientation: .down,
                imageResolution: CGSize(width: 1920, height: 1440)
            ).orientedImageSize,
            CGSize(width: 1920, height: 1440)
        )
    }
}
