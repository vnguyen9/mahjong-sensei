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
    /// Candidates below this remain visible to Developer Mode but are not
    /// proposed to a player in the review UI.
    public static let suggestionConfidenceFloor = 0.15
    private static let diagnosticDecodeFloor = 0.0001

    public var recognizer: Recognizer

    public init(recognizer: Recognizer) {
        self.recognizer = recognizer
    }

    public func classify(_ crop: TileCrop) async throws -> TileFaceHypothesis {
        var hypothesis: TileFaceHypothesis
        if let rawDetector = recognizer as? RawBoxDetecting {
            let raw = try await rawDetector.detectRawBoxes(
                crop.frame,
                minimumConfidence: Self.diagnosticDecodeFloor
            )
            hypothesis = Self.hypothesis(fromRaw: raw)
        } else {
            let result = try await recognizer.recognize(crop.frame)
            hypothesis = Self.hypothesis(fromDetections: result.tiles)
        }
        let size = crop.frame.orientedPixelSize
        hypothesis.diagnostics.cropPixelWidth = Int(size.width.rounded())
        hypothesis.diagnostics.cropPixelHeight = Int(size.height.rounded())
        return hypothesis
    }

    /// Highest-confidence raw box → its face (including `back`); empty/no
    /// mappable label → `.rejected` (high rejection score, no top face).
    static func hypothesis(fromRaw raw: [RawTileDetection]) -> TileFaceHypothesis {
        var confidenceByFace: [TileFace: Double] = [:]
        for detection in raw {
            guard let face = TileFace(detectorLabel: detection.label) else { continue }
            confidenceByFace[face] = max(confidenceByFace[face] ?? 0,
                                         detection.confidence)
        }
        let ranked = confidenceByFace.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return String(describing: $0.key) < String(describing: $1.key)
        }
        guard let top = ranked.first else {
            return .rejected
        }
        return hypothesis(face: top.key, topConfidence: top.value,
                          runnerUpConfidence: ranked.dropFirst().first?.value,
                          rankedCandidates: ranked.map {
                              TileFaceCandidate(face: $0.key, confidence: Float($0.value))
                          })
    }

    /// Fallback path for recognizers that only implement `recognize(_:)`
    /// (never sees `back`, since ``DetectedTile`` can't represent it).
    static func hypothesis(fromDetections detections: [DetectedTile]) -> TileFaceHypothesis {
        var confidenceByFace: [TileFace: Double] = [:]
        for detection in detections {
            let face = TileFace.tile(detection.tile)
            confidenceByFace[face] = max(confidenceByFace[face] ?? 0,
                                         detection.confidence)
        }
        let ranked = confidenceByFace.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return String(describing: $0.key) < String(describing: $1.key)
        }
        guard let top = ranked.first else { return .rejected }
        return hypothesis(face: top.key, topConfidence: top.value,
                          runnerUpConfidence: ranked.dropFirst().first?.value,
                          rankedCandidates: ranked.prefix(5).map {
                              TileFaceCandidate(face: $0.key,
                                                confidence: Float($0.value))
                          })
    }

    private static func hypothesis(face: TileFace, topConfidence: Double,
                                   runnerUpConfidence: Double?,
                                   rankedCandidates: [TileFaceCandidate])
        -> TileFaceHypothesis {
        let confidence = Float(topConfidence)
        let margin = runnerUpConfidence.map { Float(topConfidence - $0) } ?? confidence
        let accepted = topConfidence >= suggestionConfidenceFloor
        let probabilities = Dictionary(uniqueKeysWithValues: rankedCandidates.map {
            ($0.face, $0.confidence)
        })
        return TileFaceHypothesis(probabilities: probabilities,
                                  topFace: accepted ? face : nil,
                                  confidence: confidence, margin: margin,
                                  rejectionScore: 1 - confidence,
                                  rejectionReason: accepted ? nil : .belowAutoConfirmThreshold,
                                  diagnostics: TileFaceDiagnosticMetadata(
                                    rawTopCandidates: Array(rankedCandidates.prefix(5))
                                  ))
    }
}

extension TileFace {
    /// Maps a raw detector label (see `HKDetectorLabels.ordered`) to a face,
    /// including `back` — which `HKDetectorLabels.tile(for:)` maps to `nil`
    /// because it's not a playable ``Tile``.
    public init?(detectorLabel label: String) {
        if label == "back" { self = .back; return }
        guard let tile = HKDetectorLabels.tile(for: label) else { return nil }
        self = .tile(tile)
    }
}
