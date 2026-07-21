import Foundation
import simd
import MahjongCore

/// Tunable thresholds for the physical census (§9, §10). Like the
/// frame-quality thresholds (§6.2), these are reasonable starting points for
/// the placeholder-model pipeline, not calibrated final values — they exist
/// so tests (and, later, device calibration) can override them without
/// touching the logic that consumes them.
public struct CensusConfig: Sendable {
    // MARK: Track birth (§9.1: "births for unmatched confident observations")
    /// An observation may be decoded by the app at a lower threshold to
    /// sustain an existing identity, but it needs this stronger evidence to
    /// create a new physical tile. Coach Live uses 0.30 / 0.45 respectively.
    public var birthConfidenceThreshold: Float = 0.45

    // MARK: Tentative → confirmed (§9.2)
    public var tentativeConfirmHits: Int = 3
    public var tentativeWindow: Int = 5

    // MARK: temporarilyMissing → retired (§9.2)
    public var retireMissCount: Int = 5
    public var retireMinDuration: TimeInterval = 0.8

    // MARK: Association gate + cost weights (§9.1)
    public var gateCenterDistance: Float = 0.12 // metres, absolute floor
    public var gateCenterSlack: Float = 0.04
    public var gateRadiusMultiplier: Float = 3.0
    public var centerCostWeight: Float = 0.4
    public var footprintCostWeight: Float = 0.2
    public var imageCostWeight: Float = 0.2
    public var faceCostWeight: Float = 0.2

    // MARK: LiDAR world-space association
    /// Tile dimensions are copied from `WorldTableCalibration` when the app
    /// starts a calibrated census. Keeping a standard default makes the
    /// package source-compatible for existing callers and tests.
    public var tileDimensions: PhysicalTileDimensions = .standard
    public var worldMatchRadius: Float = 0.018
    public var staleWorldReacquisitionRadius: Float = 0.022
    public var tentativeDuplicateMergeRadius: Float = 0.010
    public var worldPositionEMAContribution: Float = 0.25

    // MARK: Face certainty (§9.3)
    public var facePublicationConfidenceThreshold: Float = 0.80
    public var requiredStrongFaceReads: Int = 2
    public var faceSuggestionWindow: Int = 5

    // MARK: Zone freshness (debug/HUD signal, independent of track lifecycle)
    public var zoneStaleAfter: TimeInterval = 1.5

    static let epsilon: Float = 1e-4

    public init() {}
}

public struct CensusDiagnostics: Sendable, Equatable {
    public var births: Int = 0
    public var matches: Int = 0
    public var qualifiedMisses: Int = 0
    public var retirements: Int = 0
    public var lowConfidenceFaceCandidates: Int = 0
    public var strongFaceReads: Int = 0
    public var facePublications: Int = 0
    public var confidentFaceConflicts: Int = 0
    public var primaryWorldMatches: Int = 0
    public var staleWorldReacquisitions: Int = 0
    public var suppressedReplacementBirths: Int = 0
    public var tentativeDuplicateMerges: Int = 0

    public init() {}
}

/// The facade over the whole physical census pipeline: association (§9.1) →
/// lifecycle (§9.2) → face fusion (§9.3) → ownership (§10.1) → conservation
/// (§10.3) → snapshot (§10.2). Platform-pure: consumes only
/// ``ObservationOutcome``s and calibrated zone polygons, never touches
/// AR/Vision/UIKit types. Not thread-safe by design, matching
/// ``FrameIDGenerator`` — the capture loop owns one instance and drives it
/// serially.
public final class PhysicalCensus {
    public var config: CensusConfig
    public private(set) var diagnostics = CensusDiagnostics()

    private(set) var tracks: [PhysicalTrack] = []
    private var nextTrackValue = 0
    private var zoneLastObservedAt: [SemanticZoneID: TimeInterval] = [:]
    private var zoneObservedArea: [SemanticZoneID: Float] = [:]

    public init(config: CensusConfig = CensusConfig()) {
        self.config = config
    }

    public var anchors: [CensusAnchor] {
        tracks.compactMap { track in
            track.worldPosition.map { CensusAnchor(id: track.id, worldPosition: $0) }
        }.sorted { $0.id < $1.id }
    }

    /// Feeds one frame's outcome into the census. Per §8's outcome table,
    /// only `.success` may add hits or explicitly depth-proven empty misses;
    /// `.skipped`/`.failed` touch nothing at all — not even a track's
    /// staleness — because they mean "we didn't look," never "we looked and
    /// it was gone." Image coverage alone is never retirement evidence.
    public func ingest(_ outcome: ObservationOutcome,
                       zones: [SemanticZoneID: [SIMD2<Float>]],
                       context: CensusFrameContext? = nil,
                       at time: TimeInterval) {
        guard case .success(let batch) = outcome else { return }

        let association = TrackAssociator.associate(tracks: tracks, observations: batch.observations, config: config)
        diagnostics.matches += association.matches.count

        for match in association.matches {
            if match.isStaleReacquisition {
                diagnostics.staleWorldReacquisitions += 1
            } else if match.usesWorldGeometry {
                diagnostics.primaryWorldMatches += 1
            }
            applyHit(trackIndex: match.trackIndex, observation: batch.observations[match.observationIndex], at: time)
        }
        for trackIndex in association.unmatchedTrackIndices {
            let before = tracks[trackIndex].state
            if applyMiss(trackIndex: trackIndex, context: context, at: time) {
                diagnostics.qualifiedMisses += 1
            }
            if before != .retired, tracks[trackIndex].state == .retired {
                diagnostics.retirements += 1
            }
        }
        mergeTentativeDuplicates()

        for observationIndex in association.unmatchedObservationIndices {
            let observation = batch.observations[observationIndex]
            if shouldSuppressReplacementBirth(for: observation) {
                diagnostics.suppressedReplacementBirths += 1
            } else if birth(from: observation, at: time) {
                diagnostics.births += 1
            }
        }

        if let context {
            for i in tracks.indices {
                guard let world = tracks[i].worldPosition else { continue }
                tracks[i].anchorCenter = Self.tablePoint(
                    for: world,
                    worldToTable: context.worldToTable
                )
            }
        }

        // Automatic ownership votes only on actual observations. Replaying an
        // unchanged anchor while it is offscreen must not satisfy the
        // three-consecutive-observation switch rule.
        for i in tracks.indices {
            guard tracks[i].semanticZoneOverride != nil
                    || tracks[i].lastHitAt == time else { continue }
            updateAutomaticOwnership(trackIndex: i, zones: zones)
        }

        recordCoverage(batch.coverage, at: time)

        tracks.removeAll { $0.state == .retired || TrackLifecycle.tentativeWindowExpired($0, config: config) }
    }

    public func resetTiles() {
        tracks.removeAll()
        nextTrackValue = 0
        zoneLastObservedAt.removeAll()
        zoneObservedArea.removeAll()
        diagnostics = CensusDiagnostics()
    }

    public func removeTrack(id: CensusTrackID) {
        tracks.removeAll { $0.id == id }
    }

    /// Creates a deterministic, user-confirmed census correction. This is
    /// used by the histogram editor while the census is authoritative; it
    /// must not manufacture a parallel legacy-track count.
    @discardableResult
    public func insertConfirmedTrack(
        face: TileFace,
        semanticZone: SemanticZoneID,
        tablePoint: SIMD2<Float>,
        worldPosition: SIMD3<Float>? = nil,
        at time: TimeInterval
    ) -> CensusTrackID {
        let id = CensusTrackID(nextTrackValue)
        nextTrackValue += 1
        var track = PhysicalTrack(
            id: id,
            anchorCenter: tablePoint,
            worldPosition: worldPosition,
            footprintRadius: config.tileDimensions.footprintRadius,
            imageBox: TileBoundingBox(
                x: Double(tablePoint.x),
                y: Double(tablePoint.y),
                width: 0,
                height: 0
            ),
            at: time
        )
        track.state = .confirmed
        track.recentOpportunities = Array(
            repeating: true,
            count: config.tentativeConfirmHits
        )
        track.semanticZoneOverride = semanticZone
        track.semanticZone = semanticZone
        track.bucket = OwnershipResolver.bucket(for: semanticZone)
        FaceFusion.pin(face, on: &track)
        tracks.append(track)
        diagnostics.births += 1
        return id
    }

    public func pinFace(_ face: TileFace, trackID: CensusTrackID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        FaceFusion.pin(face, on: &tracks[index])
    }

    public func overrideSemanticZone(_ zone: SemanticZoneID, trackID: CensusTrackID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].semanticZoneOverride = zone
        tracks[index].semanticZone = zone
        tracks[index].bucket = OwnershipResolver.bucket(for: zone)
    }

    /// Applies the two user-editable properties to one physical identity in a
    /// single census operation. A nil value leaves that property unchanged;
    /// this lets presentation layers stage face and ownership edits together
    /// without ever constructing an intermediate mixed correction.
    public func correct(
        trackID: CensusTrackID,
        face: TileFace? = nil,
        semanticZone: SemanticZoneID? = nil
    ) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if let face {
            FaceFusion.pin(face, on: &tracks[index])
        }
        if let semanticZone {
            tracks[index].semanticZoneOverride = semanticZone
            tracks[index].semanticZone = semanticZone
            tracks[index].bucket = OwnershipResolver.bucket(for: semanticZone)
        }
    }

    public func reassignZones(_ zones: [SemanticZoneID: [SIMD2<Float>]],
                              worldToTable: simd_float4x4) {
        for i in tracks.indices {
            if let world = tracks[i].worldPosition {
                tracks[i].anchorCenter = Self.tablePoint(for: world, worldToTable: worldToTable)
            }
            let zone = tracks[i].semanticZoneOverride
                ?? OwnershipResolver.semanticZone(
                    center: tracks[i].anchorCenter,
                    footprintRadius: tracks[i].footprintRadius,
                    zones: zones
                )
            tracks[i].semanticZone = zone
            tracks[i].bucket = OwnershipResolver.bucket(for: zone)
            tracks[i].pendingAutomaticZone = nil
            tracks[i].pendingAutomaticZoneHits = 0
        }
    }

    /// Pins a user-corrected face onto the live track nearest
    /// `anchorCenter`. Pinned faces stay published until the track retires
    /// (§9.3). A no-op if no track is close enough to plausibly be the one
    /// the user pointed at.
    public func pinFace(_ face: TileFace, nearAnchorCenter anchorCenter: SIMD2<Float>) {
        guard let index = tracks.indices.min(by: {
            simd_distance(tracks[$0].anchorCenter, anchorCenter) < simd_distance(tracks[$1].anchorCenter, anchorCenter)
        }) else { return }
        let gate = max(tracks[index].footprintRadius, config.gateCenterDistance)
        guard simd_distance(tracks[index].anchorCenter, anchorCenter) <= gate else { return }
        FaceFusion.pin(face, on: &tracks[index])
    }

    /// Builds the current published state (§10.2). Read-only: never mutates
    /// track storage. Conservation (§10.3) is re-evaluated fresh on every
    /// call, over this call's placements only, so a track's *stored* bucket
    /// stays purely geometric (§10.1) even while conservation downgrades what
    /// a given snapshot reports.
    public func snapshot(at time: TimeInterval) -> CensusSnapshot {
        // Once confirmed, a tile remains counted while stale or temporarily
        // missing. Counts change only at confirmed birth or qualified
        // visible-empty retirement—not merely because the camera looked away.
        let confirmed = tracks.filter {
            $0.state == .confirmed || $0.state == .temporarilyMissing || $0.state == .stale
        }

        struct Placed { var track: PhysicalTrack; var tile: Tile }
        var placedMine: [Placed] = []
        var placedTable: [Placed] = []
        var unresolved: [UnresolvedTile] = []

        for track in confirmed {
            switch track.bucket {
            case .mine, .table:
                switch track.publishedFace {
                case .tile(let tile)?:
                    if track.bucket == .mine {
                        placedMine.append(Placed(track: track, tile: tile))
                    } else {
                        placedTable.append(Placed(track: track, tile: tile))
                    }
                case .back?:
                    break // a known face-down tile: deliberately excluded, not unresolved.
                case nil:
                    unresolved.append(UnresolvedTile(trackID: track.id, reason: .faceUnresolved,
                                                      anchorCenter: track.anchorCenter,
                                                      candidateFace: track.faceSuggestion?.face))
                }
            case .ignored:
                break // opponents' concealed backs: deliberately excluded, never enumerated.
            case .unresolved:
                unresolved.append(UnresolvedTile(trackID: track.id, reason: .ownershipUnresolved,
                                                  anchorCenter: track.anchorCenter,
                                                  candidateFace: track.publishedFace ?? track.faceSuggestion?.face))
            }
        }

        let allPlaced = placedMine + placedTable
        let downgraded = Conservation.violatingTrackIDs(among: allPlaced,
                                                        tile: { $0.tile },
                                                        id: { $0.track.id },
                                                        confidence: { $0.track.publishedFaceConfidence })

        var mine = TileMultiset()
        for placed in placedMine {
            if downgraded.contains(placed.track.id) {
                unresolved.append(UnresolvedTile(trackID: placed.track.id, reason: .conservationConflict,
                                                  anchorCenter: placed.track.anchorCenter, candidateFace: placed.track.publishedFace))
            } else {
                mine.add(placed.tile)
            }
        }
        var table = TileMultiset()
        for placed in placedTable {
            if downgraded.contains(placed.track.id) {
                unresolved.append(UnresolvedTile(trackID: placed.track.id, reason: .conservationConflict,
                                                  anchorCenter: placed.track.anchorCenter, candidateFace: placed.track.publishedFace))
            } else {
                table.add(placed.tile)
            }
        }

        let zoneFreshness = Dictionary(uniqueKeysWithValues: SemanticZoneID.allCases.map { zone -> (SemanticZoneID, ZoneFreshness) in
            let lastObserved = zoneLastObservedAt[zone]
            let isStale = lastObserved.map { time - $0 > config.zoneStaleAfter } ?? true
            return (zone, ZoneFreshness(lastObservedAt: lastObserved, isStale: isStale))
        })
        let coverage = Dictionary(uniqueKeysWithValues: SemanticZoneID.allCases.map { zone in
            (zone, min(1, zoneObservedArea[zone] ?? 0))
        })

        unresolved.sort { $0.trackID < $1.trackID } // deterministic output order

        let trackSnapshots = tracks.sorted { $0.id < $1.id }.map {
            CensusTrackSnapshot(
                id: $0.id,
                worldPosition: $0.worldPosition,
                tablePoint: $0.anchorCenter,
                face: $0.publishedFace,
                faceConfidence: $0.publishedFaceConfidence,
                faceSuggestion: $0.faceSuggestion,
                strongFaceReadCount: $0.strongFaceReadCount,
                faceIsUserPinned: $0.isPinned,
                requiresManualFaceResolution: $0.requiresManualFaceResolution,
                semanticZone: $0.semanticZone,
                semanticZoneIsUserOverridden: $0.semanticZoneOverride != nil,
                lifecycle: $0.state,
                firstSeen: $0.createdAt,
                lastSeen: $0.lastHitAt
            )
        }

        return CensusSnapshot(mine: mine, table: table, unresolved: unresolved,
                              zoneFreshness: zoneFreshness, coverage: coverage,
                              confidence: Self.confidence(resolved: mine.total + table.total, unresolved: unresolved.count),
                              generatedAt: time, tracks: trackSnapshots)
    }

    // MARK: - Ingest helpers

    private func applyHit(trackIndex: Int, observation: TileObservation, at time: TimeInterval) {
        if let observedWorld = observation.worldPosition {
            if let oldWorld = tracks[trackIndex].worldPosition {
                let contribution = max(0, min(1, config.worldPositionEMAContribution))
                tracks[trackIndex].worldPosition = oldWorld * (1 - contribution) + observedWorld * contribution
            } else {
                tracks[trackIndex].worldPosition = observedWorld
            }
        }
        if let measuredDepth = observation.measuredSurfaceDepth {
            tracks[trackIndex].measuredSurfaceDepth = measuredDepth
        }
        if let center = observation.footprintCenter {
            tracks[trackIndex].anchorCenter = center
            if let radius = observation.footprintRadius { tracks[trackIndex].footprintRadius = radius }
        }
        tracks[trackIndex].imageBox = observation.box
        TrackLifecycle.recordHit(on: &tracks[trackIndex], at: time, config: config)
        recordFaceEvidence(observation, into: &tracks[trackIndex])
    }

    @discardableResult
    private func applyMiss(trackIndex: Int,
                           context: CensusFrameContext?, at time: TimeInterval) -> Bool {
        // A qualified miss is explicitly supplied by the AR/depth layer.
        // Coverage alone cannot prove a tile was removed: it may be hidden by
        // a hand, another tile, poor depth, a frame transition, or a failed
        // recognizer. Absence of a context is therefore deliberately safe.
        let isQualified = context?.qualifiedEmptyTrackIDs.contains(tracks[trackIndex].id) ?? false
        if isQualified {
            TrackLifecycle.recordQualifiedMiss(on: &tracks[trackIndex], at: time, config: config)
            return true
        } else {
            TrackLifecycle.recordCoverageLoss(on: &tracks[trackIndex])
            return false
        }
    }

    @discardableResult
    private func birth(from observation: TileObservation, at time: TimeInterval) -> Bool {
        guard observation.confidence >= config.birthConfidenceThreshold else { return false }
        // Degenerate fallback for a not-yet-projected observation: use the
        // image-box center so a track still exists to accumulate evidence.
        // Real callers project `footprintCenter` before `ingest` (§5.1);
        // this only matters for locator-only integration/tests.
        let center = observation.footprintCenter
            ?? SIMD2<Float>(Float(observation.box.centerX), Float(observation.box.centerY))
        let radius = observation.footprintRadius ?? config.tileDimensions.footprintRadius

        let id = CensusTrackID(nextTrackValue)
        nextTrackValue += 1
        var track = PhysicalTrack(id: id, anchorCenter: center,
                                  worldPosition: observation.worldPosition,
                                  measuredSurfaceDepth: observation.measuredSurfaceDepth,
                                  footprintRadius: radius,
                                  imageBox: observation.box, at: time)
        recordFaceEvidence(observation, into: &track)
        TrackLifecycle.recordHit(on: &track, at: time, config: config) // first sighting = first opportunity
        tracks.append(track)
        return true
    }

    /// A stale world anchor is deliberately given a slightly wider recovery
    /// gate. If an observation remains plausible for such an identity but was
    /// not selected by the global one-to-one assignment, birthing a second
    /// identity is more harmful than waiting for the next still frame.
    private func shouldSuppressReplacementBirth(for observation: TileObservation) -> Bool {
        guard observation.confidence >= config.birthConfidenceThreshold else { return false }
        for track in tracks where track.state == .stale || track.state == .temporarilyMissing {
            if let trackWorld = track.worldPosition,
               let observationWorld = observation.worldPosition {
                let radius = min(
                    config.staleWorldReacquisitionRadius,
                    config.tileDimensions.width * 0.95
                )
                if simd_distance(trackWorld, observationWorld) <= radius {
                    return true
                }
            } else if let center = observation.footprintCenter {
                let gate = max(
                    config.gateCenterDistance,
                    track.footprintRadius + (observation.footprintRadius ?? config.tileDimensions.footprintRadius)
                ) + config.gateCenterSlack
                if simd_distance(track.anchorCenter, center) <= gate {
                    return true
                }
            }
        }
        return false
    }

    /// Old depth views can create two tentative identities for the same tile
    /// before either has enough hits to become visible. Merge only tentative
    /// pairs inside a sub-tile radius; confirmed neighboring tiles are never
    /// considered for this cleanup.
    private func mergeTentativeDuplicates() {
        let radius = min(
            config.tentativeDuplicateMergeRadius,
            config.tileDimensions.width * 0.45
        )
        guard radius > 0 else { return }

        var merged = true
        while merged {
            merged = false
            outer: for left in tracks.indices {
                guard tracks[left].state == .tentative else { continue }
                for right in tracks.indices.dropFirst(left + 1) {
                    guard tracks[right].state == .tentative,
                          tentativeDistance(tracks[left], tracks[right]) <= radius else { continue }
                    mergeTentative(trackAt: left, with: right)
                    diagnostics.tentativeDuplicateMerges += 1
                    merged = true
                    break outer
                }
            }
        }
    }

    private func tentativeDistance(_ lhs: PhysicalTrack, _ rhs: PhysicalTrack) -> Float {
        if let leftWorld = lhs.worldPosition, let rightWorld = rhs.worldPosition {
            return simd_distance(leftWorld, rightWorld)
        }
        return simd_distance(lhs.anchorCenter, rhs.anchorCenter)
    }

    private func mergeTentative(trackAt firstIndex: Int, with secondIndex: Int) {
        let (retainedIndex, duplicateIndex): (Int, Int) = tracks[firstIndex].id < tracks[secondIndex].id
            ? (firstIndex, secondIndex)
            : (secondIndex, firstIndex)
        let duplicate = tracks[duplicateIndex]
        var retained = tracks[retainedIndex]

        if let duplicateWorld = duplicate.worldPosition {
            if let retainedWorld = retained.worldPosition {
                retained.worldPosition = (retainedWorld + duplicateWorld) * 0.5
            } else {
                retained.worldPosition = duplicateWorld
            }
        }
        retained.anchorCenter = (retained.anchorCenter + duplicate.anchorCenter) * 0.5
        retained.footprintRadius = max(retained.footprintRadius, duplicate.footprintRadius)
        retained.lastHitAt = max(retained.lastHitAt, duplicate.lastHitAt)
        retained.createdAt = min(retained.createdAt, duplicate.createdAt)
        retained.recentOpportunities = Array(
            (retained.recentOpportunities + duplicate.recentOpportunities)
                .suffix(config.tentativeWindow)
        )
        retained.recentFaceEvidence = Array(
            (retained.recentFaceEvidence + duplicate.recentFaceEvidence)
                .suffix(config.faceSuggestionWindow)
        )
        retained.faceSupport = [:]
        for evidence in retained.recentFaceEvidence {
            retained.faceSupport[evidence.face, default: 0] += evidence.confidence
        }
        if let best = retained.faceSupport.max(by: { lhs, rhs in
            lhs.value == rhs.value
                ? String(describing: lhs.key) > String(describing: rhs.key)
                : lhs.value < rhs.value
        }) {
            let peakConfidence = retained.recentFaceEvidence
                .filter { $0.face == best.key }
                .map(\.confidence)
                .max() ?? 0
            retained.faceSuggestion = CensusFaceSuggestion(
                face: best.key,
                confidence: min(1, max(0, peakConfidence))
            )
        }
        tracks[retainedIndex] = retained
        tracks.remove(at: duplicateIndex)
    }

    private func recordFaceEvidence(
        _ observation: TileObservation,
        into track: inout PhysicalTrack
    ) {
        if let hypothesis = observation.faceHypothesis, hypothesis.topFace != nil {
            let effectiveConfidence = min(
                max(0, hypothesis.confidence),
                max(0, observation.confidence)
            )
            if !observation.faceEvidenceQualifiesForPublication
                || effectiveConfidence < config.facePublicationConfidenceThreshold {
                diagnostics.lowConfidenceFaceCandidates += 1
            }
        }

        switch FaceFusion.absorb(
            hypothesis: observation.faceHypothesis,
            observationConfidence: observation.confidence,
            passID: observation.faceEvidencePassID
                ?? UInt64(max(0, observation.frameID.value)),
            qualifiesForPublication: observation.faceEvidenceQualifiesForPublication,
            observedAt: observation.faceEvidenceTimestamp,
            into: &track,
            config: config
        ) {
        case .none:
            break
        case .strongRead:
            diagnostics.strongFaceReads += 1
        case .published:
            diagnostics.strongFaceReads += 1
            diagnostics.facePublications += 1
        case .conflict:
            diagnostics.strongFaceReads += 1
            diagnostics.confidentFaceConflicts += 1
        }
    }

    private func updateAutomaticOwnership(
        trackIndex: Int,
        zones: [SemanticZoneID: [SIMD2<Float>]]
    ) {
        if let override = tracks[trackIndex].semanticZoneOverride {
            tracks[trackIndex].semanticZone = override
            tracks[trackIndex].bucket = OwnershipResolver.bucket(for: override)
            return
        }
        let proposed = OwnershipResolver.semanticZone(
            center: tracks[trackIndex].anchorCenter,
            footprintRadius: tracks[trackIndex].footprintRadius,
            zones: zones
        )
        let current = tracks[trackIndex].semanticZone

        if current == .boundaryUnresolved || proposed == current {
            if proposed != .boundaryUnresolved {
                tracks[trackIndex].semanticZone = proposed
                tracks[trackIndex].bucket = OwnershipResolver.bucket(for: proposed)
            }
            tracks[trackIndex].pendingAutomaticZone = nil
            tracks[trackIndex].pendingAutomaticZoneHits = 0
            return
        }

        // A brief boundary result is measurement jitter, not evidence that a
        // physical tile changed owner. A concrete different polygon must be
        // seen in three consecutive observations before ownership moves.
        guard proposed != .boundaryUnresolved else { return }
        if tracks[trackIndex].pendingAutomaticZone == proposed {
            tracks[trackIndex].pendingAutomaticZoneHits += 1
        } else {
            tracks[trackIndex].pendingAutomaticZone = proposed
            tracks[trackIndex].pendingAutomaticZoneHits = 1
        }
        guard tracks[trackIndex].pendingAutomaticZoneHits >= 3 else { return }
        tracks[trackIndex].semanticZone = proposed
        tracks[trackIndex].bucket = OwnershipResolver.bucket(for: proposed)
        tracks[trackIndex].pendingAutomaticZone = nil
        tracks[trackIndex].pendingAutomaticZoneHits = 0
    }

    private func recordCoverage(_ coverage: CoverageMask, at time: TimeInterval) {
        for region in coverage.regions {
            zoneLastObservedAt[region.zoneID] = max(zoneLastObservedAt[region.zoneID] ?? -.infinity, time)
            zoneObservedArea[region.zoneID, default: 0] += Self.polygonArea(region.vertices)
        }
    }

    /// Shoelace formula. An approximation of true zone coverage fraction
    /// (sums observed-crop area without clipping against the calibrated
    /// zone polygon or de-duplicating overlaps across frames). This is a
    /// diagnostic signal only, never a count or retirement input.
    private static func polygonArea(_ vertices: [SIMD2<Float>]) -> Float {
        guard vertices.count >= 3 else { return 0 }
        var sum: Float = 0
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            sum += (vertices[j].x + vertices[i].x) * (vertices[j].y - vertices[i].y)
            j = i
        }
        return abs(sum) / 2
    }

    private static func confidence(resolved: Int, unresolved: Int) -> CensusConfidence {
        let total = resolved + unresolved
        guard total > 0 else { return .low }
        let ratio = Float(resolved) / Float(total)
        if ratio >= 0.9 { return .high }
        if ratio >= 0.6 { return .medium }
        return .low
    }

    private static func tablePoint(for world: SIMD3<Float>,
                                   worldToTable: simd_float4x4) -> SIMD2<Float> {
        let local = worldToTable * SIMD4<Float>(world, 1)
        return SIMD2<Float>(local.x, local.z)
    }
}
