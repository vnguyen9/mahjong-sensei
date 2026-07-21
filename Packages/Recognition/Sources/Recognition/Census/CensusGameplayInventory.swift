import Foundation
import MahjongCore

/// A proposed edit to one authoritative census identity. Inventory previews
/// apply this value without mutating the census or publishing a correction.
public struct CensusTrackCorrectionDraft: Sendable, Equatable {
    public var trackID: CensusTrackID
    public var face: Tile?
    public var semanticZone: SemanticZoneID

    public init(trackID: CensusTrackID, face: Tile?, semanticZone: SemanticZoneID) {
        self.trackID = trackID
        self.face = face
        self.semanticZone = semanticZone
    }
}

/// A pure, read-only gameplay inventory projected from physical census tracks.
///
/// Held lifecycle states remain present until depth-proven retirement. Tracks
/// in ignored wall/back geometry are intentionally absent, and face-unknown
/// tracks are disclosed separately rather than guessed into a histogram.
public struct CensusGameplayInventory: Sendable, Equatable {
    public private(set) var tableCounts: [Tile: Int]
    public private(set) var yoursCounts: [Tile: Int]
    public private(set) var unassignedCounts: [Tile: Int]
    public private(set) var unknownFaceTrackCount: Int

    public init(
        snapshot: CensusSnapshot,
        applying draft: CensusTrackCorrectionDraft? = nil
    ) {
        var tableCounts: [Tile: Int] = [:]
        var yoursCounts: [Tile: Int] = [:]
        var unassignedCounts: [Tile: Int] = [:]
        var unknownFaceTrackCount = 0

        for track in snapshot.tracks where track.lifecycle.contributesToGameplayInventory {
            let correction = draft.flatMap { draft in
                track.id == draft.trackID ? draft : nil
            }
            let zone = correction?.semanticZone ?? track.semanticZone
            guard zone != .ignoredWall else { continue }

            let tile: Tile?
            if let correction {
                tile = correction.face
            } else if case let .tile(resolved)? = track.face {
                tile = resolved
            } else {
                tile = nil
            }

            guard let tile else {
                unknownFaceTrackCount += 1
                continue
            }

            switch zone.inventoryGroup {
            case .table:
                tableCounts[tile, default: 0] += 1
            case .yours:
                yoursCounts[tile, default: 0] += 1
            case .unassigned:
                unassignedCounts[tile, default: 0] += 1
            case .ignored:
                break
            }
        }

        self.tableCounts = tableCounts
        self.yoursCounts = yoursCounts
        self.unassignedCounts = unassignedCounts
        self.unknownFaceTrackCount = unknownFaceTrackCount
    }

    public func tableCount(for tile: Tile) -> Int { tableCounts[tile, default: 0] }
    public func yoursCount(for tile: Tile) -> Int { yoursCounts[tile, default: 0] }
    public func unassignedCount(for tile: Tile) -> Int { unassignedCounts[tile, default: 0] }

    public var resolvedCounts: [Tile: Int] {
        tableCounts.merging(yoursCounts, uniquingKeysWith: +)
            .merging(unassignedCounts, uniquingKeysWith: +)
    }

    public func resolvedCount(for tile: Tile) -> Int {
        tableCount(for: tile) + yoursCount(for: tile) + unassignedCount(for: tile)
    }

    public func liveCount(for tile: Tile) -> Int {
        max(0, tile.physicalCopyLimit - resolvedCount(for: tile))
    }
}

private extension TrackLifecycleState {
    var contributesToGameplayInventory: Bool {
        switch self {
        case .confirmed, .stale, .temporarilyMissing:
            true
        case .tentative, .retired:
            false
        }
    }
}

private extension SemanticZoneID {
    enum InventoryGroup {
        case table, yours, unassigned, ignored
    }

    var inventoryGroup: InventoryGroup {
        switch self {
        case .tablePond, .tableRevealedLeft, .tableRevealedFar, .tableRevealedRight:
            .table
        case .mineHand, .mineMeld:
            .yours
        case .boundaryUnresolved:
            .unassigned
        case .ignoredWall:
            .ignored
        }
    }
}

private extension Tile {
    var physicalCopyLimit: Int { isBonus ? 1 : 4 }
}
