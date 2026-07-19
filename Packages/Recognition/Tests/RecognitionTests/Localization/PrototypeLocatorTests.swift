import XCTest
import CoreGraphics
@testable import Recognition
import MahjongCore

/// Chunk A locator tests (§7.1): the prototype adapter keeps box + confidence
/// only, and — critically — retains `back` (face-down) boxes that the
/// trusted `recognize()` path drops.
final class PrototypeLocatorTests: XCTestCase {

    private static func blankImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private static func frame() -> RecognizerFrame { .image(blankImage()) }

    /// Exposes raw detector boxes (incl. `back`) the way `VisionRecognizer`
    /// does, so the locator can be tested without a real Core ML model.
    private struct StubRawRecognizer: Recognizer, RawBoxDetecting {
        var raw: [RawTileDetection]

        func recognize(_ frame: RecognizerFrame) async throws -> RecognitionResult {
            // Mirrors production: only labels with a `Tile` mapping survive.
            let tiles = raw.compactMap { d -> DetectedTile? in
                HKDetectorLabels.tile(for: d.label).map {
                    DetectedTile(tile: $0, confidence: d.confidence, box: d.box)
                }
            }
            return RecognitionResult(tiles: tiles)
        }

        func detectRawBoxes(_ frame: RecognizerFrame) async throws -> [RawTileDetection] { raw }
    }

    private struct ThrowingRecognizer: Recognizer {
        struct Boom: Error {}
        func recognize(_ frame: RecognizerFrame) async throws -> RecognitionResult { throw Boom() }
    }

    func testRetainsBackBoxes() async throws {
        let backBox = TileBoundingBox(x: 0.1, y: 0.1, width: 0.1, height: 0.2)
        let faceBox = TileBoundingBox(x: 0.5, y: 0.5, width: 0.1, height: 0.2)
        let raw = [
            RawTileDetection(label: "back", confidence: 0.9, box: backBox),
            RawTileDetection(label: "3p", confidence: 0.95, box: faceBox),
        ]
        let locator = PrototypeLocator(recognizer: StubRawRecognizer(raw: raw))

        let localizations = try await locator.locate(in: LocatorInput(frame: Self.frame()))

        XCTAssertEqual(localizations.count, 2, "the `back` box must survive alongside the mapped one")
        let backLocalization = localizations.first { $0.box == backBox }
        XCTAssertNotNil(backLocalization, "back box missing from locator output")
        XCTAssertEqual(Double(backLocalization?.confidence ?? -1), 0.9, accuracy: 0.0001)
        XCTAssertTrue(localizations.contains { $0.box == faceBox })
        XCTAssertTrue(localizations.allSatisfy { $0.poseHint == .unknown })

        // Sanity: `recognize()` itself (the trusted Scan-Score path) still drops `back`.
        let plain = try await StubRawRecognizer(raw: raw).recognize(Self.frame())
        XCTAssertEqual(plain.tiles.count, 1)
    }

    func testFallsBackToRecognizeWhenRawIsUnavailable() async throws {
        let mock = MockRecognizer(result: .row([.m(1), .m(2)]))
        let locator = PrototypeLocator(recognizer: mock)

        let localizations = try await locator.locate(in: LocatorInput(frame: Self.frame()))

        XCTAssertEqual(localizations.count, 2)
    }

    func testLocatorThrowPropagates() async {
        let locator = PrototypeLocator(recognizer: ThrowingRecognizer())
        do {
            _ = try await locator.locate(in: LocatorInput(frame: Self.frame()))
            XCTFail("expected the locator to propagate the throw")
        } catch {
            // expected
        }
    }
}
