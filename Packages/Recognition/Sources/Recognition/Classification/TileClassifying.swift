import Foundation
import MahjongCore

/// Stage 2 of the two-stage recognizer (§7.2): identifies the face shown by
/// one already-localized tile crop.
public protocol TileClassifying: Sendable {
    func classify(_ crop: TileCrop) async throws -> TileFaceHypothesis
}

/// Classifiers that can amortize preprocessing and Core ML scheduling across
/// many native tile crops. Callers choose their own memory-bounded batch size;
/// other features can continue using ``TileClassifying`` one crop at a time.
public protocol BatchTileClassifying: TileClassifying {
    func classify(_ crops: [TileCrop]) async throws -> [TileFaceHypothesis]
}

public extension BatchTileClassifying {
    func classify(_ crop: TileCrop) async throws -> TileFaceHypothesis {
        try await classify([crop]).first ?? .rejected
    }
}

/// Every possible classifier output: one of the 42 playable faces, or a
/// face-down tile. There is deliberately no `.unknown` case here — §7.2:
/// "unknown is derived ... not a class." Low-confidence/out-of-distribution
/// results are expressed through `TileFaceHypothesis.rejectionScore`/`topFace == nil`.
public enum TileFace: Hashable, Sendable {
    case tile(Tile)
    case back
}

/// Why a crop did not produce an automatically usable face. The face itself
/// remains a model output; these reasons explain the product decision without
/// inventing an `unknown` face class.
public enum TileFaceRejectionReason: String, Sendable, Hashable, Codable {
    case noModelOutput
    case belowAutoConfirmThreshold
    case lowMargin
    case invalidCrop
    case classifierFailure
    case conservationViolation
}

/// A raw, ranked model candidate retained for the review transaction.
public struct TileFaceCandidate: Sendable, Hashable {
    public var face: TileFace
    public var confidence: Float

    public init(face: TileFace, confidence: Float) {
        self.face = face
        self.confidence = confidence
    }
}

/// Scalar-only evidence captured from the same inference that produced the
/// hypothesis. No pixels or filesystem information are retained here.
public struct TileFaceDiagnosticMetadata: Sendable, Hashable {
    public var rawTopCandidates: [TileFaceCandidate]
    public var cropPixelWidth: Int?
    public var cropPixelHeight: Int?
    public var validity: Float?
    public var inferenceDuration: TimeInterval?

    public init(rawTopCandidates: [TileFaceCandidate] = [],
                cropPixelWidth: Int? = nil,
                cropPixelHeight: Int? = nil,
                validity: Float? = nil,
                inferenceDuration: TimeInterval? = nil) {
        self.rawTopCandidates = rawTopCandidates
        self.cropPixelWidth = cropPixelWidth
        self.cropPixelHeight = cropPixelHeight
        self.validity = validity
        self.inferenceDuration = inferenceDuration
    }
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
    public var rejectionReason: TileFaceRejectionReason?
    public var diagnostics: TileFaceDiagnosticMetadata

    public init(probabilities: [TileFace: Float] = [:],
                topFace: TileFace? = nil,
                confidence: Float = 0,
                margin: Float = 0,
                rejectionScore: Float = 1,
                rejectionReason: TileFaceRejectionReason? = nil,
                diagnostics: TileFaceDiagnosticMetadata = .init()) {
        self.probabilities = probabilities
        self.topFace = topFace
        self.confidence = confidence
        self.margin = margin
        self.rejectionScore = rejectionScore
        self.rejectionReason = rejectionReason
        self.diagnostics = diagnostics
    }

    /// No usable signal at all (empty/failed crop) — maximal rejection, no top face.
    public static let rejected = TileFaceHypothesis(
        rejectionScore: 1,
        rejectionReason: .noModelOutput
    )

    public static func rejected(_ reason: TileFaceRejectionReason,
                                diagnostics: TileFaceDiagnosticMetadata = .init())
        -> TileFaceHypothesis {
        TileFaceHypothesis(rejectionScore: 1,
                           rejectionReason: reason,
                           diagnostics: diagnostics)
    }
}

/// A native tile crop handed to the classifier, plus the frame it came from
/// (§5.1: every downstream projection must trace back to one `ARFrame`).
public struct TileCrop: Sendable {
    /// The already-cropped image. This must never be the original full frame.
    public var frame: RecognizerFrame
    public var frameID: FrameID
    /// Box in the source frame's normalized oriented-image coordinates.
    public var sourceBox: TileBoundingBox?

    public init(frame: RecognizerFrame, frameID: FrameID,
                sourceBox: TileBoundingBox? = nil) {
        self.frame = frame
        self.frameID = frameID
        self.sourceBox = sourceBox
    }
}
