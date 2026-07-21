import simd

/// §9.1: deterministic globally-optimal one-to-one matching of one batch's
/// observations to physical tracks. The small census size makes a Hungarian
/// solve inexpensive, and avoids the order-dependent swaps a greedy matcher
/// can make in a dense pond.
enum TrackAssociator {
    struct Match {
        var trackIndex: Int
        var observationIndex: Int
        var usesWorldGeometry: Bool
        var isStaleReacquisition: Bool
    }

    struct Result {
        var matches: [Match]
        var unmatchedTrackIndices: [Int]
        var unmatchedObservationIndices: [Int]
    }

    private struct Candidate {
        var trackIndex: Int
        var observationIndex: Int
        var cost: Float
        var usesWorldGeometry: Bool
        var isStaleReacquisition: Bool
    }

    static func associate(tracks: [PhysicalTrack], observations: [TileObservation],
                          config: CensusConfig) -> Result {
        guard !tracks.isEmpty, !observations.isEmpty else {
            return Result(
                matches: [],
                unmatchedTrackIndices: Array(tracks.indices),
                unmatchedObservationIndices: Array(observations.indices)
            )
        }

        var candidates: [Candidate] = []
        for (trackIndex, track) in tracks.enumerated() {
            for (observationIndex, observation) in observations.enumerated() {
                guard let candidate = matchCandidate(
                    track: track,
                    trackIndex: trackIndex,
                    observation: observation,
                    observationIndex: observationIndex,
                    config: config
                ) else { continue }
                candidates.append(candidate)
            }
        }

        // A wider stale-track gate may only recover an unambiguous mutual-best
        // pairing. It must never let a stale anchor steal a nearby observation
        // from an actively visible neighboring tile.
        let admissible = candidates.filter { candidate in
            guard candidate.isStaleReacquisition else { return true }
            return isMutualBest(candidate, among: candidates, tracks: tracks)
        }

        let selected = minimumCostMaximumCardinalityMatching(
            candidates: admissible,
            trackCount: tracks.count,
            observationCount: observations.count,
            tracks: tracks
        )
        let matchedTracks = Set(selected.map(\.trackIndex))
        let matchedObservations = Set(selected.map(\.observationIndex))
        return Result(
            matches: selected.sorted {
                if $0.trackIndex != $1.trackIndex { return $0.trackIndex < $1.trackIndex }
                return $0.observationIndex < $1.observationIndex
            },
            unmatchedTrackIndices: tracks.indices.filter { !matchedTracks.contains($0) },
            unmatchedObservationIndices: observations.indices.filter { !matchedObservations.contains($0) }
        )
    }

    private static func isMutualBest(
        _ candidate: Candidate,
        among candidates: [Candidate],
        tracks: [PhysicalTrack]
    ) -> Bool {
        func orderedBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            let lhsID = tracks[lhs.trackIndex].id
            let rhsID = tracks[rhs.trackIndex].id
            if lhsID != rhsID { return lhsID < rhsID }
            return lhs.observationIndex < rhs.observationIndex
        }
        let bestForTrack = candidates
            .filter { $0.trackIndex == candidate.trackIndex }
            .min(by: orderedBefore)
        let bestForObservation = candidates
            .filter { $0.observationIndex == candidate.observationIndex }
            .min(by: orderedBefore)
        return bestForTrack?.observationIndex == candidate.observationIndex
            && bestForObservation?.trackIndex == candidate.trackIndex
    }

    /// Finds the minimum-cost assignment while giving every valid pair a
    /// substantially lower cost than a dummy "unmatched" column. This first
    /// maximizes match cardinality and then minimizes geometric cost. The
    /// input is rectangular, so each track gets its own dummy column.
    private static func minimumCostMaximumCardinalityMatching(
        candidates: [Candidate],
        trackCount: Int,
        observationCount: Int,
        tracks: [PhysicalTrack]
    ) -> [Match] {
        guard !candidates.isEmpty else { return [] }
        let columnCount = observationCount + trackCount
        let forbidden: Double = 1_000_000
        let unmatched: Double = 1_000
        var costs = Array(
            repeating: Array(repeating: forbidden, count: columnCount),
            count: trackCount
        )
        for trackIndex in 0..<trackCount {
            costs[trackIndex][observationCount + trackIndex] = unmatched
        }
        var candidateForPair: [Pair: Candidate] = [:]
        for candidate in candidates {
            let pair = Pair(track: candidate.trackIndex, observation: candidate.observationIndex)
            let existing = candidateForPair[pair]
            if existing == nil || deterministicCandidateOrder(candidate, existing!, tracks: tracks) {
                candidateForPair[pair] = candidate
                // Add a tiny deterministic term so exact-cost ties are stable
                // across platforms and compiler optimization levels.
                costs[candidate.trackIndex][candidate.observationIndex] =
                    Double(candidate.cost) + Double(candidate.observationIndex) * 1e-8
            }
        }

        let assignedColumns = hungarian(costs)
        return assignedColumns.enumerated().compactMap { trackIndex, column in
            guard column >= 0, column < observationCount,
                  let candidate = candidateForPair[Pair(track: trackIndex, observation: column)] else {
                return nil
            }
            return Match(
                trackIndex: trackIndex,
                observationIndex: column,
                usesWorldGeometry: candidate.usesWorldGeometry,
                isStaleReacquisition: candidate.isStaleReacquisition
            )
        }
    }

    private struct Pair: Hashable {
        var track: Int
        var observation: Int
    }

    private static func deterministicCandidateOrder(
        _ lhs: Candidate,
        _ rhs: Candidate,
        tracks: [PhysicalTrack]
    ) -> Bool {
        if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
        let lhsID = tracks[lhs.trackIndex].id
        let rhsID = tracks[rhs.trackIndex].id
        if lhsID != rhsID { return lhsID < rhsID }
        return lhs.observationIndex < rhs.observationIndex
    }

    /// Hungarian algorithm for n rows and m columns where m >= n. Returns a
    /// column index for every row. Costs are finite because every row gets a
    /// private dummy column.
    private static func hungarian(_ costs: [[Double]]) -> [Int] {
        let n = costs.count
        let m = costs.first?.count ?? 0
        guard n > 0, m >= n else { return Array(repeating: -1, count: n) }
        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: m + 1)
        var p = Array(repeating: 0, count: m + 1)
        var way = Array(repeating: 0, count: m + 1)

        for row in 1...n {
            p[0] = row
            var column0 = 0
            var minValue = Array(repeating: Double.infinity, count: m + 1)
            var used = Array(repeating: false, count: m + 1)
            repeat {
                used[column0] = true
                let row0 = p[column0]
                var delta = Double.infinity
                var column1 = 0
                for column in 1...m where !used[column] {
                    let value = costs[row0 - 1][column - 1] - u[row0] - v[column]
                    if value < minValue[column] {
                        minValue[column] = value
                        way[column] = column0
                    }
                    if minValue[column] < delta {
                        delta = minValue[column]
                        column1 = column
                    }
                }
                for column in 0...m {
                    if used[column] {
                        u[p[column]] += delta
                        v[column] -= delta
                    } else {
                        minValue[column] -= delta
                    }
                }
                column0 = column1
            } while p[column0] != 0

            repeat {
                let column1 = way[column0]
                p[column0] = p[column1]
                column0 = column1
            } while column0 != 0
        }

        var result = Array(repeating: -1, count: n)
        for column in 1...m where p[column] != 0 {
            result[p[column] - 1] = column - 1
        }
        return result
    }

    private static func matchCandidate(
        track: PhysicalTrack,
        trackIndex: Int,
        observation: TileObservation,
        observationIndex: Int,
        config: CensusConfig
    ) -> Candidate? {
        if let trackWorld = track.worldPosition, let observationWorld = observation.worldPosition {
            let distance = simd_distance(trackWorld, observationWorld)
            let primaryRadius = min(config.worldMatchRadius, config.tileDimensions.width * 0.75)
            let staleRadius = min(
                config.staleWorldReacquisitionRadius,
                config.tileDimensions.width * 0.95
            )
            let isEligibleForReacquisition = track.state == .stale || track.state == .temporarilyMissing
            let isStaleReacquisition = distance > primaryRadius
                && distance <= staleRadius
                && isEligibleForReacquisition
            guard distance <= primaryRadius || isStaleReacquisition else { return nil }
            let gate = isStaleReacquisition ? staleRadius : primaryRadius
            let worldCost = distance / max(gate, CensusConfig.epsilon)
            let imageCost = 1 - iou(track.imageBox, observation.box)
            let faceCost = faceDistributionCost(track: track, observation: observation)
            return Candidate(
                trackIndex: trackIndex,
                observationIndex: observationIndex,
                cost: 0.8 * worldCost + 0.1 * imageCost + 0.1 * faceCost,
                usesWorldGeometry: true,
                isStaleReacquisition: isStaleReacquisition
            )
        }

        var centerCost: Float = 0
        var footprintCost: Float = 0
        if let obsCenter = observation.footprintCenter {
            let obsRadius = observation.footprintRadius ?? track.footprintRadius
            let combinedRadius = track.footprintRadius + obsRadius
            let distance = simd_distance(track.anchorCenter, obsCenter)
            let gate = max(config.gateCenterDistance, combinedRadius * config.gateRadiusMultiplier)
                + config.gateCenterSlack
            guard distance <= gate else { return nil }
            centerCost = distance / (combinedRadius + CensusConfig.epsilon)
            let overlap = max(0, 1 - distance / (combinedRadius + CensusConfig.epsilon))
            footprintCost = 1 - min(1, overlap)
        } else {
            guard iou(track.imageBox, observation.box) > 0 else { return nil }
        }

        let imageCost = 1 - iou(track.imageBox, observation.box)
        let faceCost = faceDistributionCost(track: track, observation: observation)
        return Candidate(
            trackIndex: trackIndex,
            observationIndex: observationIndex,
            cost: config.centerCostWeight * centerCost
                + config.footprintCostWeight * footprintCost
                + config.imageCostWeight * imageCost
                + config.faceCostWeight * faceCost,
            usesWorldGeometry: false,
            isStaleReacquisition: false
        )
    }

    private static func faceDistributionCost(track: PhysicalTrack, observation: TileObservation) -> Float {
        guard let hypothesis = observation.faceHypothesis, !hypothesis.probabilities.isEmpty else { return 0 }
        let trackDistribution = normalizedDistribution(from: track.faceSupport)
        guard !trackDistribution.isEmpty else { return 0 }
        let similarity = cosineSimilarity(trackDistribution, hypothesis.probabilities)
        return 1 - max(0, min(1, similarity))
    }

    private static func normalizedDistribution(from support: [TileFace: Float]) -> [TileFace: Float] {
        let sum = support.values.reduce(0, +)
        guard sum > 0 else { return [:] }
        return support.mapValues { $0 / sum }
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
