/// Integration-only Stage-1 adapter over the existing 43-class detector
/// (`VisionRecognizer`, via the ``Recognizer`` protocol). It keeps only box +
/// confidence and ignores the predicted face entirely — the production
/// locator (a one-class YOLO26n `tile` model) doesn't predict a face at all.
///
/// When the wrapped recognizer also conforms to ``RawBoxDetecting`` (true for
/// every real ``VisionRecognizer``), this reads every raw detector box,
/// including `back` (face-down) ones that ``Recognizer/recognize(_:)`` drops
/// because they have no ``Tile`` mapping — §7.1 requires the locator to see
/// every physical tile. Recognizers that only implement the plain protocol
/// (e.g. ``MockRecognizer`` in tests/previews) fall back to `recognize(_:)`
/// and, like today's Scan-Score path, cannot see `back`.
public struct PrototypeLocator: TileLocating {
    public var recognizer: Recognizer

    public init(recognizer: Recognizer) {
        self.recognizer = recognizer
    }

    public func locate(in region: LocatorInput) async throws -> [TileLocalization] {
        if let rawDetector = recognizer as? RawBoxDetecting {
            let raw = try await rawDetector.detectRawBoxes(region.frame)
            return raw.map {
                TileLocalization(box: $0.box, confidence: Float($0.confidence), poseHint: .unknown)
            }
        }
        let result = try await recognizer.recognize(region.frame)
        return result.tiles.map {
            TileLocalization(box: $0.box, confidence: Float($0.confidence), poseHint: .unknown)
        }
    }
}
