import simd

/// §9.1: deterministic gated matching of one batch's observations to the
/// existing physical tracks. Ownership is never part of the cost — it is
/// derived later, purely from geometry (see `Ownership.swift`).
///
/// This is a greedy matcher over globally-sorted, gate-filtered candidates
/// with a fully deterministic tie-break, not a true optimal assignment. The
/// doc allows either for the small-N case (§9.1: "normally fewer than 80
/// visible tiles"). If dense scenes start showing greedy mis-assignments,
/// swap this for a proper Hungarian/Jonker-Volgenant solve — the gate +
/// cost function can stay exactly as-is; only the assignment step changes.
enum TrackAssociator {
    struct Match {
        var trackIndex: Int
        var observationIndex: Int
    }

    struct Result {
        var matches: [Match]
        var unmatchedTrackIndices: [Int]
        var unmatchedObservationIndices: [Int]
    }

    static func associate(tracks: [PhysicalTrack], observations: [TileObservation],
                          config: CensusConfig) -> Result {
        struct Candidate {
            var trackIndex: Int
            var observationIndex: Int
            var cost: Float
        }

        var candidates: [Candidate] = []
        for (trackIndex, track) in tracks.enumerated() {
            for (observationIndex, observation) in observations.enumerated() {
                guard let cost = matchCost(track: track, observation: observation, config: config) else { continue }
                candidates.append(Candidate(trackIndex: trackIndex, observationIndex: observationIndex, cost: cost))
            }
        }

        // Deterministic ordering: cheapest first, ties broken by stable track
        // identity then observation index — never insertion order alone.
        candidates.sort { a, b in
            if a.cost != b.cost { return a.cost < b.cost }
            let idA = tracks[a.trackIndex].id, idB = tracks[b.trackIndex].id
            if idA != idB { return idA < idB }
            return a.observationIndex < b.observationIndex
        }

        var matchedTracks: Set<Int> = []
        var matchedObservations: Set<Int> = []
        var matches: [Match] = []
        for candidate in candidates {
            guard !matchedTracks.contains(candidate.trackIndex),
                  !matchedObservations.contains(candidate.observationIndex) else { continue }
            matches.append(Match(trackIndex: candidate.trackIndex, observationIndex: candidate.observationIndex))
            matchedTracks.insert(candidate.trackIndex)
            matchedObservations.insert(candidate.observationIndex)
        }

        let unmatchedTrackIndices = tracks.indices.filter { !matchedTracks.contains($0) }
        let unmatchedObservationIndices = observations.indices.filter { !matchedObservations.contains($0) }
        return Result(matches: matches, unmatchedTrackIndices: unmatchedTrackIndices,
                     unmatchedObservationIndices: unmatchedObservationIndices)
    }

    /// `nil` means a hard gate rejected the pair as physically impossible.
    private static func matchCost(track: PhysicalTrack, observation: TileObservation,
                                  config: CensusConfig) -> Float? {
        var centerCost: Float = 0
        var footprintCost: Float = 0

        if let obsCenter = observation.footprintCenter {
            let obsRadius = observation.footprintRadius ?? track.footprintRadius
            let combinedRadius = track.footprintRadius + obsRadius
            let distance = simd_distance(track.anchorCenter, obsCenter)
            let gate = max(config.gateCenterDistance, combinedRadius * config.gateRadiusMultiplier)
                     + config.gateCenterSlack
            guard distance <= gate else { return nil } // physically impossible — hard reject

            centerCost = distance / (combinedRadius + CensusConfig.epsilon)
            let overlap = max(0, 1 - distance / (combinedRadius + CensusConfig.epsilon))
            footprintCost = 1 - min(1, overlap)
        } else {
            // No anchor-local projection on this observation yet: fall back
            // to image-space continuity only, gated on requiring *some*
            // image overlap so unrelated tiles elsewhere in frame can never
            // pair up on face similarity alone.
            guard iou(track.imageBox, observation.box) > 0 else { return nil }
        }

        let imageCost = 1 - iou(track.imageBox, observation.box)
        let faceCost = faceDistributionCost(track: track, observation: observation)

        return config.centerCostWeight * centerCost
             + config.footprintCostWeight * footprintCost
             + config.imageCostWeight * imageCost
             + config.faceCostWeight * faceCost
    }

    /// Similarity between the track's accumulated face-probability
    /// distribution and this observation's hypothesis. Neutral (zero cost)
    /// whenever either side has no evidence yet — this term should only
    /// penalize genuine disagreement, not the absence of a classifier
    /// opinion.
    private static func faceDistributionCost(track: PhysicalTrack, observation: TileObservation) -> Float {
        guard let hypothesis = observation.faceHypothesis, !hypothesis.probabilities.isEmpty else { return 0 }
        let trackDistribution = normalizedDistribution(from: track.faceLogProbs)
        guard !trackDistribution.isEmpty else { return 0 }
        let similarity = cosineSimilarity(trackDistribution, hypothesis.probabilities)
        return 1 - max(0, min(1, similarity))
    }

    private static func normalizedDistribution(from logProbs: [TileFace: Float]) -> [TileFace: Float] {
        guard let maxLogProb = logProbs.values.max() else { return [:] }
        var exponentiated: [TileFace: Float] = [:]
        var sum: Float = 0
        for (face, logProb) in logProbs {
            let e = exp(logProb - maxLogProb) // shifted for numerical stability
            exponentiated[face] = e
            sum += e
        }
        guard sum > 0 else { return [:] }
        return exponentiated.mapValues { $0 / sum }
    }

    private static func cosineSimilarity(_ a: [TileFace: Float], _ b: [TileFace: Float]) -> Float {
        var dot: Float = 0
        for (face, valueA) in a {
            if let valueB = b[face] { dot += valueA * valueB }
        }
        let normA = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let normB = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB)
    }

    private static func iou(_ a: TileBoundingBox, _ b: TileBoundingBox) -> Float {
        let ax0 = a.x, ay0 = a.y, ax1 = a.x + a.width, ay1 = a.y + a.height
        let bx0 = b.x, by0 = b.y, bx1 = b.x + b.width, by1 = b.y + b.height
        let ix0 = max(ax0, bx0), iy0 = max(ay0, by0)
        let ix1 = min(ax1, bx1), iy1 = min(ay1, by1)
        let intersectionWidth = max(0, ix1 - ix0)
        let intersectionHeight = max(0, iy1 - iy0)
        let intersectionArea = intersectionWidth * intersectionHeight
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return Float(intersectionArea / unionArea)
    }
}
