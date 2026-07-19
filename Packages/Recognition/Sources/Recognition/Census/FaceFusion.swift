import Foundation
import MahjongCore

/// §9.3 face fusion: accumulates log-probabilities from accepted views,
/// publishes only past a minimum-evidence + margin bar, and requires
/// *stronger* evidence to move an already-published face than to publish one
/// for the first time — so a track never frame-flips between two candidate
/// faces just because the last observation happened to favor one of them.
enum FaceFusion {
    /// Folds one accepted hypothesis into `track`'s accumulated evidence and
    /// re-evaluates what (if anything) should be published. A no-op for a
    /// pinned track (§9.3: "keep user corrections pinned until the physical
    /// track retires") or a hypothesis with no usable signal.
    static func absorb(hypothesis: TileFaceHypothesis?, observationConfidence: Float,
                       into track: inout PhysicalTrack, config: CensusConfig) {
        guard !track.isPinned else { return }
        guard let hypothesis, hypothesis.topFace != nil, !hypothesis.probabilities.isEmpty else { return }

        // Placeholder-model proxy for "classifier calibration and crop
        // quality" (§9.3): both stages' own reported confidence, floored so
        // a single very-low-confidence view can't erase prior evidence.
        let weight = max(config.minFaceWeight, min(1, hypothesis.confidence))
                   * max(config.minFaceWeight, min(1, observationConfidence))

        for (face, probability) in hypothesis.probabilities {
            let p = max(probability, CensusConfig.epsilon)
            track.faceLogProbs[face, default: 0] += weight * Foundation.log(p)
        }
        track.faceEvidenceCount += 1

        republish(&track, config: config)
    }

    /// A user correction: publishes immediately and pins the face so future
    /// evidence can't move it until the track retires.
    static func pin(_ face: TileFace, on track: inout PhysicalTrack) {
        track.publishedFace = face
        track.isPinned = true
        track.publishedFaceMargin = .greatestFiniteMagnitude
    }

    private static func republish(_ track: inout PhysicalTrack, config: CensusConfig) {
        let ranked = track.faceLogProbs.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return faceRank(lhs.key) < faceRank(rhs.key) // deterministic tie-break, dictionary order isn't
        }
        guard let best = ranked.first else { return }

        // No competing candidate at all: nothing to be confused with, so
        // don't let the (always-negative, magnitude-dependent) raw log-prob
        // stand in for margin.
        let margin = ranked.count > 1 ? best.value - ranked[1].value : Float.greatestFiniteMagnitude
        track.publishedFaceMargin = margin

        guard track.faceEvidenceCount >= config.minFaceEvidence else { return }

        switch track.publishedFace {
        case nil:
            if margin >= config.publishMargin { track.publishedFace = best.key }
            // else: leave nil — surfaces as `.faceUnresolved` in the
            // snapshot; conflicting strong views never frame-flip a count
            // that was never published in the first place.
        case .some(let current) where current != best.key:
            if margin >= config.switchMargin { track.publishedFace = best.key }
            // else: sticky — not enough to overturn the standing call.
        default:
            break // reaffirming the same face; margin bookkeeping above already ran.
        }
    }

    private static func faceRank(_ face: TileFace) -> Int {
        switch face {
        case .back: return -1
        case .tile(let tile): return tile.classIndex
        }
    }
}
