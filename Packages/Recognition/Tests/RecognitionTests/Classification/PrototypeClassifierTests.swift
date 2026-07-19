import XCTest
import CoreGraphics
@testable import Recognition
import MahjongCore

/// Chunk A classifier tests (§7.2): the placeholder adapter takes the
/// highest-confidence detection's face, including `back` when the wrapped
/// recognizer exposes raw boxes.
final class PrototypeClassifierTests: XCTestCase {

    private static func blankImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private static func crop(frameID: Int = 0) -> TileCrop {
        TileCrop(frame: .image(blankImage()), frameID: FrameID(frameID))
    }

    private struct StubRawRecognizer: Recognizer, RawBoxDetecting {
        var raw: [RawTileDetection]
        func recognize(_ frame: RecognizerFrame) async throws -> RecognitionResult { .empty }
        func detectRawBoxes(_ frame: RecognizerFrame) async throws -> [RawTileDetection] { raw }
    }

    func testBackCropClassifiesToBackFace() async throws {
        let raw = [RawTileDetection(label: "back", confidence: 0.88,
                                    box: TileBoundingBox(x: 0, y: 0, width: 1, height: 1))]
        let classifier = PrototypeClassifier(recognizer: StubRawRecognizer(raw: raw))

        let hypothesis = try await classifier.classify(Self.crop())

        XCTAssertEqual(hypothesis.topFace, .back)
        XCTAssertEqual(Double(hypothesis.confidence), 0.88, accuracy: 0.0001)
        XCTAssertEqual(hypothesis.probabilities[.back], hypothesis.confidence)
    }

    func testFaceCropClassifiesToTile() async throws {
        let raw = [RawTileDetection(label: "3p", confidence: 0.7,
                                    box: TileBoundingBox(x: 0, y: 0, width: 1, height: 1))]
        let classifier = PrototypeClassifier(recognizer: StubRawRecognizer(raw: raw))

        let hypothesis = try await classifier.classify(Self.crop())

        XCTAssertEqual(hypothesis.topFace, .tile(.p(3)))
    }

    func testHigherConfidenceDetectionWinsAndSetsMargin() async throws {
        let raw = [
            RawTileDetection(label: "1m", confidence: 0.6, box: TileBoundingBox(x: 0, y: 0, width: 1, height: 1)),
            RawTileDetection(label: "2m", confidence: 0.9, box: TileBoundingBox(x: 0, y: 0, width: 1, height: 1)),
        ]
        let classifier = PrototypeClassifier(recognizer: StubRawRecognizer(raw: raw))

        let hypothesis = try await classifier.classify(Self.crop())

        XCTAssertEqual(hypothesis.topFace, .tile(.m(2)))
        XCTAssertEqual(Double(hypothesis.margin), 0.3, accuracy: 0.0001)
    }

    func testNoDetectionRejects() async throws {
        let classifier = PrototypeClassifier(recognizer: StubRawRecognizer(raw: []))

        let hypothesis = try await classifier.classify(Self.crop())

        XCTAssertNil(hypothesis.topFace)
        XCTAssertEqual(hypothesis.rejectionScore, 1)
    }

    func testFallsBackToRecognizeWhenRawIsUnavailable() async throws {
        let mock = MockRecognizer(result: .row([.m(5)]))
        let classifier = PrototypeClassifier(recognizer: mock)

        let hypothesis = try await classifier.classify(Self.crop())

        XCTAssertEqual(hypothesis.topFace, .tile(.m(5)))
    }
}
