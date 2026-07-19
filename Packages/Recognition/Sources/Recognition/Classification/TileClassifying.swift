import MahjongCore

/// Stage 2 of the two-stage recognizer (§7.2): identifies the face shown by
/// one already-localized tile crop.
public protocol TileClassifying: Sendable {
    func classify(_ crop: TileCrop) async throws -> TileFaceHypothesis
}

/// Every possible classifier output: one of the 42 playable faces, or a
/// face-down tile. There is deliberately no `.unknown` case here — §7.2:
/// "unknown is derived ... not a class." Low-confidence/out-of-distribution
/// results are expressed through `TileFaceHypothesis.rejectionScore`/`topFace == nil`.
public enum TileFace: Hashable, Sendable {
    case tile(Tile)
    case back
}

/// One classifier's belief about a crop's face: a (possibly partial)
/// probability distribution plus the derived top call, confidence, margin to
/// the runner-up, and an OOD/rejection score. `topFace == nil` means "no
/// usable signal" — treat as unknown, not as a specific face.
public struct TileFaceHypothesis: Sendable, Hashable {
    public var probabilities: [TileFace: Float]
    public var topFace: TileFace?
    public var confidence: Float
    public var margin: Float
    public var rejectionScore: Float

    public init(probabilities: [TileFace: Float] = [:],
                topFace: TileFace? = nil,
                confidence: Float = 0,
                margin: Float = 0,
                rejectionScore: Float = 1) {
        self.probabilities = probabilities
        self.topFace = topFace
        self.confidence = confidence
        self.margin = margin
        self.rejectionScore = rejectionScore
    }

    /// No usable signal at all (empty/failed crop) — maximal rejection, no top face.
    public static let rejected = TileFaceHypothesis(rejectionScore: 1)
}

/// A native tile crop handed to the classifier, plus the frame it came from
/// (§5.1: every downstream projection must trace back to one `ARFrame`).
public struct TileCrop: Sendable {
    public var frame: RecognizerFrame
    public var frameID: FrameID

    public init(frame: RecognizerFrame, frameID: FrameID) {
        self.frame = frame
        self.frameID = frameID
    }
}
