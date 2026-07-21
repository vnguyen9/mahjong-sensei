import Foundation

/// A physical anchor that remains present even though recognition has not yet
/// resolved its tile face. It is safe for UI totals and correction, but carries
/// no face and therefore cannot enter scoring or conservation calculations.
public struct SpatialUnknownTile: Identifiable, Sendable, Equatable {
    public var id: TrackID
    public var zone: SemanticZoneID
    public var lifecycle: TrackLifecycleState

    public init(
        id: TrackID,
        zone: SemanticZoneID,
        lifecycle: TrackLifecycleState
    ) {
        self.id = id
        self.zone = zone
        self.lifecycle = lifecycle
    }
}

/// Face-independent physical accounting derived from one deterministic census
/// snapshot. The app combines this with its resolved gameplay adapter.
public struct CensusPhysicalPresentation: Sendable, Equatable {
    public var unknownTracks: [SpatialUnknownTile]
    public var zoneCounts: [SemanticZoneID: Int]

    public init(
        unknownTracks: [SpatialUnknownTile],
        zoneCounts: [SemanticZoneID: Int]
    ) {
        self.unknownTracks = unknownTracks
        self.zoneCounts = zoneCounts
    }

    public static func make(snapshot: CensusSnapshot) -> Self {
        let eligible = snapshot.tracks.filter {
            $0.lifecycle != .tentative
                && $0.lifecycle != .retired
                && $0.semanticZone != .ignoredWall
        }.sorted { $0.id < $1.id }
        var counts: [SemanticZoneID: Int] = [:]
        var unknown: [SpatialUnknownTile] = []
        for track in eligible {
            counts[track.semanticZone, default: 0] += 1
            if track.face == nil {
                unknown.append(SpatialUnknownTile(
                    id: TrackID(raw: track.id.value),
                    zone: track.semanticZone,
                    lifecycle: track.lifecycle
                ))
            }
        }
        return Self(unknownTracks: unknown, zoneCounts: counts)
    }
}
