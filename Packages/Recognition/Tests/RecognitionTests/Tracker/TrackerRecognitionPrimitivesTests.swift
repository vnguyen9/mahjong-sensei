import CoreGraphics
import XCTest
@testable import Recognition
import MahjongCore

final class TrackerRecognitionPrimitivesTests: XCTestCase {
    func testCropperReturnsNativeCropAndSourceMetadata() throws {
        let context = CGContext(
            data: nil,
            width: 100,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let source = try XCTUnwrap(context.makeImage())
        let sourceBox = TileBoundingBox(x: 0.20, y: 0.25, width: 0.20, height: 0.25)

        let crop = try XCTUnwrap(RecognizerFrameCropper(contextFraction: 0).crop(
            .image(source), box: sourceBox, frameID: FrameID(1)
        ))

        XCTAssertEqual(crop.sourceBox, sourceBox)
        guard case let .cgImage(image, orientation) = crop.frame else {
            return XCTFail("Expected a materialized CGImage crop")
        }
        XCTAssertEqual(orientation, .up)
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 20)
    }

    func testUltralyticsPortraitLetterboxUsesGraySidePaddingGeometry() {
        let geometry = UltralyticsLetterboxGeometry(
            sourceSize: CGSize(width: 3_024, height: 4_032)
        )

        XCTAssertEqual(geometry.resizedWidth, 480)
        XCTAssertEqual(geometry.resizedHeight, 640)
        XCTAssertEqual(geometry.leftPadding, 80)
        XCTAssertEqual(geometry.rightPadding, 80)
        XCTAssertEqual(geometry.topPadding, 0)
        XCTAssertEqual(geometry.bottomPadding, 0)

        let box = geometry.normalizedCanonicalBox(
            x1: 80, y1: 0, x2: 560, y2: 640
        )
        XCTAssertEqual(box.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(box.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(box.width, 1, accuracy: 0.000_001)
        XCTAssertEqual(box.height, 1, accuracy: 0.000_001)
    }

    func testUltralyticsInverseMappingHandlesAsymmetricRounding() {
        for size in [CGSize(width: 1_001, height: 777),
                     CGSize(width: 777, height: 1_001)] {
            let geometry = UltralyticsLetterboxGeometry(sourceSize: size)
            let sourceBox = TileBoundingBox(x: 0.173, y: 0.281,
                                            width: 0.219, height: 0.337)
            let x1 = sourceBox.x * Double(geometry.sourceWidth) * geometry.scale
                + Double(geometry.leftPadding)
            let y1 = sourceBox.y * Double(geometry.sourceHeight) * geometry.scale
                + Double(geometry.topPadding)
            let x2 = (sourceBox.x + sourceBox.width)
                * Double(geometry.sourceWidth) * geometry.scale
                + Double(geometry.leftPadding)
            let y2 = (sourceBox.y + sourceBox.height)
                * Double(geometry.sourceHeight) * geometry.scale
                + Double(geometry.topPadding)
            let mapped = geometry.normalizedCanonicalBox(
                x1: x1, y1: y1, x2: x2, y2: y2
            )
            let twoPixelX = 2 / Double(geometry.sourceWidth)
            let twoPixelY = 2 / Double(geometry.sourceHeight)
            XCTAssertEqual(mapped.x, sourceBox.x, accuracy: twoPixelX)
            XCTAssertEqual(mapped.y, sourceBox.y, accuracy: twoPixelY)
            XCTAssertEqual(mapped.width, sourceBox.width, accuracy: twoPixelX)
            XCTAssertEqual(mapped.height, sourceBox.height, accuracy: twoPixelY)
            XCTAssertEqual(geometry.leftPadding + geometry.resizedWidth
                           + geometry.rightPadding, geometry.inputSize)
            XCTAssertEqual(geometry.topPadding + geometry.resizedHeight
                           + geometry.bottomPadding, geometry.inputSize)
        }
    }

    func testOrientationBakingProducesUprightRasterDimensions() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 20, height: 10,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let source = try XCTUnwrap(context.makeImage())

        let up = try UltralyticsLetterboxRenderer.bakeOrientation(source,
                                                                  orientation: .up)
        let down = try UltralyticsLetterboxRenderer.bakeOrientation(source,
                                                                    orientation: .down)
        let left = try UltralyticsLetterboxRenderer.bakeOrientation(source,
                                                                    orientation: .left)
        let right = try UltralyticsLetterboxRenderer.bakeOrientation(source,
                                                                     orientation: .right)

        XCTAssertEqual([up.width, up.height], [20, 10])
        XCTAssertEqual([down.width, down.height], [20, 10])
        XCTAssertEqual([left.width, left.height], [10, 20])
        XCTAssertEqual([right.width, right.height], [10, 20])
    }
}
