import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import MahjongCore

/// A single frame handed to a ``Recognizer`` — either a still image (a picked
/// photo) or a live camera pixel buffer. The orientation is passed through to
/// Vision so rotated captures are read correctly.
public enum RecognizerFrame: @unchecked Sendable {
    case cgImage(CGImage, CGImagePropertyOrientation)
    case pixelBuffer(CVPixelBuffer, CGImagePropertyOrientation)

    /// A still image (defaults to `.up`).
    public static func image(_ image: CGImage,
                             orientation: CGImagePropertyOrientation = .up) -> RecognizerFrame {
        .cgImage(image, orientation)
    }

    /// A live camera frame (use `.right` for the back camera held in portrait).
    public static func buffer(_ buffer: CVPixelBuffer,
                              orientation: CGImagePropertyOrientation = .up) -> RecognizerFrame {
        .pixelBuffer(buffer, orientation)
    }
}

/// Abstraction over "turn a captured frame into recognized tiles". The live
/// implementation — ``VisionRecognizer`` (Vision → Core ML on the Neural Engine)
/// — sits behind this; ``MockRecognizer`` drives previews/tests with scripted data.
public protocol Recognizer: Sendable {
    func recognize(_ frame: RecognizerFrame) async throws -> RecognitionResult
}

public enum RecognizerError: Error, Sendable {
    /// No compiled model resource (`<name>.mlmodelc`) was found in the bundle —
    /// e.g. before the detector has been exported and bundled.
    case modelNotFound(String)
}

/// A recognizer that returns a fixed, scripted result regardless of the frame —
/// drives the whole UI (and previews/tests) with zero dependency on a model or camera.
public struct MockRecognizer: Recognizer {
    public var result: RecognitionResult
    public init(result: RecognitionResult = MockHands.winning) { self.result = result }
    public func recognize(_ frame: RecognizerFrame) async throws -> RecognitionResult { result }
}

/// Canonical sample hands taken from the design walkthrough, for mock/preview use.
public enum MockHands {
    /// Result-screen hand: Chow 2·3·4萬 · Chow 6·7·8萬 · Pung 中·中·中 · Pung 東·東·東 · Pair 白·白.
    /// One tile is flagged low-confidence to exercise the correction flow.
    public static let winning = RecognitionResult.row(
        [.m(2), .m(3), .m(4), .m(6), .m(7), .m(8),
         .redDragon, .redDragon, .redDragon,
         .east, .east, .east, .whiteDragon, .whiteDragon],
        lowConfidenceIndices: [8]
    )

    /// Coach-lane hand: bamboo-flush leaning, a green-dragon pair, an isolated 9萬
    /// and an off-suit 3筒 — the "discard 9萬 to keep the flush" narrative.
    public static let coach = RecognitionResult.row(
        [.s(2), .s(3), .s(4), .s(5), .s(6), .s(7), .s(8),
         .greenDragon, .greenDragon, .m(9), .p(3), .s(1), .s(9), .p(5)]
    )

    /// Two physical rows spanning every dot & bamboo rank — exercises the new pip
    /// layouts, badges, and row-mirroring (debug / preview use).
    public static let twoRowWinning = RecognitionResult.rows([
        [.p(2), .p(3), .p(4), .p(5), .p(6), .p(7), .p(8)],
        [.s(2), .s(3), .s(4), .s(5), .s(6), .s(7), .s(8)],
    ])
}
