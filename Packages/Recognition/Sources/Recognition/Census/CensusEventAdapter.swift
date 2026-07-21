import Foundation
import MahjongCore
import simd

/// The exact census-owned projection consumed by the existing settle-diff
/// turn/event engine. Identity, lifecycle, and semantic ownership are carried
/// through explicitly; sending these through the legacy image-space
/// association/zone model would create a second, contradictory source of
/// truth.
public struct CensusEventTrack: Sendable, Hashable {
    public var id: TrackID
    public var face: Tile
    public var faceConfidence: Double
    public var box: TileBoundingBox
    public var zone: TileZone
    public var seat: RelativeSeat?
    public var life: TrackedTile.Life
    public var firstSeen: TimeInterval
    public var lastSeen: TimeInterval

    public init(
        id: TrackID,
        face: Tile,
        faceConfidence: Double,
        box: TileBoundingBox,
        zone: TileZone,
        seat: RelativeSeat?,
        life: TrackedTile.Life,
        firstSeen: TimeInterval,
        lastSeen: TimeInterval
    ) {
        self.id = id
        self.face = face
        self.faceConfidence = faceConfidence
        self.box = box
        self.zone = zone
        self.seat = seat
        self.life = life
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Converts the authoritative physical census into stable table-space tracks
/// consumed by the existing turn/event engine. It does not recognize,
/// associate, infer ownership, or publish counts.
public enum CensusEventAdapter {
    public static func tracks(
        from snapshot: CensusSnapshot,
        tableExtent: SIMD2<Float>
    ) -> [CensusEventTrack] {
        guard tableExtent.x > 0, tableExtent.y > 0 else { return [] }

        return snapshot.tracks.compactMap { track in
            guard track.lifecycle != .tentative,
                  track.lifecycle != .retired,
                  case .tile(let tile)? = track.face else {
                return nil
            }
            let width = Double(0.024 / tableExtent.x)
            let height = Double(0.032 / tableExtent.y)
            let centerX = Double(track.tablePoint.x / tableExtent.x + 0.5)
            let centerY = Double(track.tablePoint.y / tableExtent.y + 0.5)
            let confidence = max(0, min(1, Double(track.faceConfidence)))
            let ownership = eventOwnership(
                for: track.semanticZone,
                tile: tile
            )
            guard let ownership else { return nil }
            return CensusEventTrack(
                id: TrackID(raw: track.id.value),
                face: tile,
                faceConfidence: confidence,
                box: TileBoundingBox(
                    x: centerX - width * 0.5,
                    y: centerY - height * 0.5,
                    width: width,
                    height: height
                ),
                zone: ownership.zone,
                seat: ownership.seat,
                life: track.lifecycle == .confirmed ? .live : .missing,
                firstSeen: track.firstSeen,
                lastSeen: track.lastSeen
            )
        }.sorted {
            if $0.box.centerY != $1.box.centerY {
                return $0.box.centerY < $1.box.centerY
            }
            if $0.box.centerX != $1.box.centerX {
                return $0.box.centerX < $1.box.centerX
            }
            return $0.id < $1.id
        }
    }

    private static func eventOwnership(
        for semanticZone: SemanticZoneID,
        tile: Tile
    ) -> (zone: TileZone, seat: RelativeSeat?)? {
        switch semanticZone {
        case .mineHand:
            return (tile.isBonus ? .myBonus : .myHand, nil)
        case .mineMeld:
            return (.myMeld, nil)
        case .tablePond:
            return (.pond, nil)
        case .tableRevealedLeft:
            return (.opponentMeld, .left)
        case .tableRevealedFar:
            return (.opponentMeld, .across)
        case .tableRevealedRight:
            return (.opponentMeld, .right)
        case .ignoredWall:
            return nil
        case .boundaryUnresolved:
            return (.unresolved, nil)
        }
    }
}
