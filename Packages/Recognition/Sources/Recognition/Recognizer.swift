import Foundation
import MahjongCore

/// Abstraction over "turn a captured frame into recognized tiles". The live
/// implementation (AVCapture → Vision → Core ML on the Neural Engine) drops in
/// behind this protocol once the trained model is exported; the app targets this
/// interface so every screen works today on `MockRecognizer`.
public protocol Recognizer: Sendable {
    func recognize() async -> RecognitionResult
}

/// A recognizer that returns a fixed, scripted result — drives the whole UI
/// (and previews/tests) with zero dependency on the trained model or a camera.
public struct MockRecognizer: Recognizer {
    public var result: RecognitionResult
    public init(result: RecognitionResult = MockHands.winning) { self.result = result }
    public func recognize() async -> RecognitionResult { result }
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
}
