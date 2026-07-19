import MahjongCore

/// Placeholder Stage-2 adapter over the existing 43-class detector: runs it
/// on the native per-tile crop and takes the highest-confidence detection as
/// the face hypothesis. Real crops, real inference — only the model itself
/// (a dedicated small face classifier) is a stand-in.
///
/// Like ``PrototypeLocator``, this prefers the wrapped recognizer's
/// ``RawBoxDetecting`` path when available so a face-down crop classifies to
/// `.back` instead of silently producing no hypothesis at all.
public struct PrototypeClassifier: TileClassifying {
    public var recognizer: Recognizer

    public init(recognizer: Recognizer) {
        self.recognizer = recognizer
    }

    public func classify(_ crop: TileCrop) async throws -> TileFaceHypothesis {
        if let rawDetector = recognizer as? RawBoxDetecting {
            let raw = try await rawDetector.detectRawBoxes(crop.frame)
            return Self.hypothesis(fromRaw: raw)
        }
        let result = try await recognizer.recognize(crop.frame)
        return Self.hypothesis(fromDetections: result.tiles)
    }

    /// Highest-confidence raw box → its face (including `back`); empty/no
    /// mappable label → `.rejected` (high rejection score, no top face).
    static func hypothesis(fromRaw raw: [RawTileDetection]) -> TileFaceHypothesis {
        let ranked = raw.sorted { $0.confidence > $1.confidence }
        guard let top = ranked.first, let face = TileFace(detectorLabel: top.label) else {
            return .rejected
        }
        return hypothesis(face: face, topConfidence: top.confidence,
                          runnerUpConfidence: ranked.dropFirst().first?.confidence)
    }

    /// Fallback path for recognizers that only implement `recognize(_:)`
    /// (never sees `back`, since ``DetectedTile`` can't represent it).
    static func hypothesis(fromDetections detections: [DetectedTile]) -> TileFaceHypothesis {
        let ranked = detections.sorted { $0.confidence > $1.confidence }
        guard let top = ranked.first else { return .rejected }
        return hypothesis(face: .tile(top.tile), topConfidence: top.confidence,
                          runnerUpConfidence: ranked.dropFirst().first?.confidence)
    }

    private static func hypothesis(face: TileFace, topConfidence: Double,
                                   runnerUpConfidence: Double?) -> TileFaceHypothesis {
        let confidence = Float(topConfidence)
        let margin = runnerUpConfidence.map { Float(topConfidence - $0) } ?? confidence
        return TileFaceHypothesis(probabilities: [face: confidence], topFace: face,
                                  confidence: confidence, margin: margin,
                                  rejectionScore: 1 - confidence)
    }
}

extension TileFace {
    /// Maps a raw detector label (see `HKDetectorLabels.ordered`) to a face,
    /// including `back` — which `HKDetectorLabels.tile(for:)` maps to `nil`
    /// because it's not a playable ``Tile``.
    init?(detectorLabel label: String) {
        if label == "back" { self = .back; return }
        guard let tile = HKDetectorLabels.tile(for: label) else { return nil }
        self = .tile(tile)
    }
}
