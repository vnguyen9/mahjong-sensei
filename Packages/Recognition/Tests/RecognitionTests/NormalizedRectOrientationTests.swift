import CoreGraphics
import ImageIO
import XCTest
@testable import Recognition

final class NormalizedRectOrientationTests: XCTestCase {
    private let asymmetric = TileBoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    private let fullFrame = TileBoundingBox(x: 0, y: 0, width: 1, height: 1)

    // MARK: - Per-orientation math

    func testUpIsIdentity() {
        let result = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .up)
        assertEqual(result, asymmetric)
    }

    func testUpMirroredMatchesUp() {
        let result = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .upMirrored)
        assertEqual(result, asymmetric)
    }

    func testDownIs180DegreeRotation() {
        let result = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .down)
        assertEqual(result, TileBoundingBox(x: 1 - 0.1 - 0.3, y: 1 - 0.2 - 0.4, width: 0.3, height: 0.4))
    }

    func testRightRotatesNinetyDegreesClockwiseBackToNative() {
        let result = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .right)
        assertEqual(result, TileBoundingBox(x: 0.2, y: 1 - 0.1 - 0.3, width: 0.4, height: 0.3))
    }

    func testLeftRotatesNinetyDegreesCounterclockwiseBackToNative() {
        let result = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .left)
        assertEqual(result, TileBoundingBox(x: 1 - 0.2 - 0.4, y: 0.1, width: 0.4, height: 0.3))
    }

    func testMirroredVariantsMatchTheirBaseOrientation() {
        let pairs: [(CGImagePropertyOrientation, CGImagePropertyOrientation)] = [
            (.downMirrored, .down), (.rightMirrored, .right), (.leftMirrored, .left),
        ]
        for (mirrored, base) in pairs {
            let a = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: mirrored)
            let b = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: base)
            assertEqual(a, b, "\(mirrored) should match \(base)")
        }
    }

    // MARK: - Round trips

    func testDownAppliedTwiceRoundTrips() {
        let once = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .down)
        let twice = NormalizedRectOrientation.metadataRect(fromOriented: once, orientation: .down)
        assertEqual(twice, asymmetric)
    }

    func testRightThenLeftRoundTrips() {
        let native = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .right)
        let roundTripped = NormalizedRectOrientation.metadataRect(fromOriented: native, orientation: .left)
        assertEqual(roundTripped, asymmetric)
    }

    func testLeftThenRightRoundTrips() {
        let native = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .left)
        let roundTripped = NormalizedRectOrientation.metadataRect(fromOriented: native, orientation: .right)
        assertEqual(roundTripped, asymmetric)
    }

    func testUpRoundTrips() {
        let native = NormalizedRectOrientation.metadataRect(fromOriented: asymmetric, orientation: .up)
        let roundTripped = NormalizedRectOrientation.metadataRect(fromOriented: native, orientation: .up)
        assertEqual(roundTripped, asymmetric)
    }

    // MARK: - Edge rects

    func testFullFrameMapsToFullFrameForEveryOrientation() {
        for orientation: CGImagePropertyOrientation in [.up, .down, .left, .right] {
            let result = NormalizedRectOrientation.metadataRect(fromOriented: fullFrame, orientation: orientation)
            assertEqual(result, fullFrame, "orientation \(orientation)")
        }
    }

    func testZeroSizedRectAtOriginStaysWithinUnitSquareForEveryOrientation() {
        let corner = TileBoundingBox(x: 0, y: 0, width: 0, height: 0)
        for orientation: CGImagePropertyOrientation in [.up, .down, .left, .right] {
            let result = NormalizedRectOrientation.metadataRect(fromOriented: corner, orientation: orientation)
            XCTAssertEqual(result.width, 0, accuracy: 1e-9, "orientation \(orientation)")
            XCTAssertEqual(result.height, 0, accuracy: 1e-9, "orientation \(orientation)")
            XCTAssertTrue((0...1).contains(result.x), "orientation \(orientation) x=\(result.x)")
            XCTAssertTrue((0...1).contains(result.y), "orientation \(orientation) y=\(result.y)")
        }
    }

    func testZeroSizedRectAtFarCornerStaysWithinUnitSquareForEveryOrientation() {
        let corner = TileBoundingBox(x: 1, y: 1, width: 0, height: 0)
        for orientation: CGImagePropertyOrientation in [.up, .down, .left, .right] {
            let result = NormalizedRectOrientation.metadataRect(fromOriented: corner, orientation: orientation)
            XCTAssertEqual(result.width, 0, accuracy: 1e-9, "orientation \(orientation)")
            XCTAssertEqual(result.height, 0, accuracy: 1e-9, "orientation \(orientation)")
            XCTAssertTrue((0...1).contains(result.x), "orientation \(orientation) x=\(result.x)")
            XCTAssertTrue((0...1).contains(result.y), "orientation \(orientation) y=\(result.y)")
        }
    }

    // MARK: - Helpers

    private func assertEqual(_ a: TileBoundingBox, _ b: TileBoundingBox,
                             _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 1e-9, message, file: file, line: line)
    }
}
