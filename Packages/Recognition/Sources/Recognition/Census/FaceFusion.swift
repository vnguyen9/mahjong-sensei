import Foundation
import MahjongCore

/// Separates a detector's useful localization signal from the much stricter
/// evidence required to name a physical tile. Suggestions use a short recent
/// window; authoritative publication requires repeated strong observations.
enum FaceFusion {
    enum Outcome {
        case none
        case published
        case conflict
    }

    /// Folds one observation into recent suggestion support. Sub-threshold
    /// reads are useful suggestions but can never publish or clear a face.
    @discardableResult
    static func absorb(
        hypothesis: TileFaceHypothesis?,
        observationConfidence: Float,
        into track: inout PhysicalTrack,
        config: CensusConfig
    ) -> Outcome {
        guard !track.isPinned else { return .none }
        guard let hypothesis, let topFace = hypothesis.topFace else { return .none }

        let confidence = min(
            1,
            max(0, min(hypothesis.confidence, observationConfidence))
        )
        guard confidence > 0 else { return .none }

        appendSuggestionEvidence(
            face: topFace,
            confidence: confidence,
            into: &track,
            window: max(1, config.faceSuggestionWindow)
        )

        guard confidence >= config.facePublicationConfidenceThreshold else {
            return .none
        }

        if track.strongFaceCandidate == topFace {
            track.strongFaceReadCount += 1
            track.strongFaceConfidence = min(track.strongFaceConfidence, confidence)
        } else {
            track.strongFaceCandidate = topFace
            track.strongFaceReadCount = 1
            track.strongFaceConfidence = confidence
        }

        let requiredReads = max(1, config.requiredStrongFaceReads)
        guard track.strongFaceReadCount >= requiredReads else { return .none }
        guard !track.requiresManualFaceResolution else { return .none }

        switch track.publishedFace {
        case nil:
            track.publishedFace = topFace
            track.publishedFaceConfidence = track.strongFaceConfidence
            return .published

        case .some(let current) where current == topFace:
            track.publishedFaceConfidence = max(
                track.publishedFaceConfidence,
                track.strongFaceConfidence
            )
            return .none

        case .some:
            // Never silently switch an authoritative gameplay face. A second
            // strong, contradictory agreement makes uncertainty explicit and
            // leaves the resolution to the physical-tile editor.
            track.publishedFace = nil
            track.publishedFaceConfidence = 0
            track.requiresManualFaceResolution = true
            return .conflict
        }
    }

    /// A user correction publishes immediately and remains authoritative for
    /// this physical identity until retirement.
    static func pin(_ face: TileFace, on track: inout PhysicalTrack) {
        track.publishedFace = face
        track.publishedFaceConfidence = 1
        track.faceSuggestion = CensusFaceSuggestion(face: face, confidence: 1)
        track.strongFaceCandidate = face
        track.strongFaceReadCount = 0
        track.strongFaceConfidence = 1
        track.requiresManualFaceResolution = false
        track.isPinned = true
    }

    private static func appendSuggestionEvidence(
        face: TileFace,
        confidence: Float,
        into track: inout PhysicalTrack,
        window: Int
    ) {
        track.recentFaceEvidence.append(
            PhysicalTrack.FaceEvidenceSample(face: face, confidence: confidence)
        )
        if track.recentFaceEvidence.count > window {
            track.recentFaceEvidence.removeFirst(
                track.recentFaceEvidence.count - window
            )
        }

        var support: [TileFace: Float] = [:]
        var peak: [TileFace: Float] = [:]
        for sample in track.recentFaceEvidence {
            support[sample.face, default: 0] += sample.confidence
            peak[sample.face] = max(peak[sample.face, default: 0], sample.confidence)
        }
        track.faceSupport = support

        let winner = support.keys.min { lhs, rhs in
            let lhsSupport = support[lhs, default: 0]
            let rhsSupport = support[rhs, default: 0]
            if lhsSupport != rhsSupport { return lhsSupport > rhsSupport }
            let lhsPeak = peak[lhs, default: 0]
            let rhsPeak = peak[rhs, default: 0]
            if lhsPeak != rhsPeak { return lhsPeak > rhsPeak }
            return faceRank(lhs) < faceRank(rhs)
        }
        track.faceSuggestion = winner.map {
            CensusFaceSuggestion(face: $0, confidence: peak[$0, default: 0])
        }
    }

    private static func faceRank(_ face: TileFace) -> Int {
        switch face {
        case .back:
            return -1
        case .tile(let tile):
            return tile.classIndex
        }
    }
}
