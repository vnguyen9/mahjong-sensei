import Foundation
import MahjongCore
import Recognition

enum CensusStateAdapter {
    static func makeBootstrapState(
        preserving legacy: TrackedTableState
    ) -> TrackedTableState {
        TrackedTableState(
            revision: legacy.revision,
            phase: legacy.phase,
            handIndex: legacy.handIndex,
            mySeatWind: legacy.mySeatWind,
            roundWind: legacy.roundWind,
            currentTurn: legacy.currentTurn,
            myHand: [],
            myBonus: [],
            myMelds: [],
            pond: [],
            opponentMelds: [:],
            unresolved: [],
            seenHistogram: Array(
                repeating: 0,
                count: Tile.baseClassCount
            ),
            unseenCount: 136,
            handTileCount: 0,
            isMyHandComplete: false
        )
    }

    static func makeState(
        snapshot: CensusSnapshot,
        preserving legacy: TrackedTableState,
        tableExtent: SIMD2<Float>,
        censusRevision: Int
    ) -> TrackedTableState {
        var hand: [TrackedTile] = []
        var bonus: [TrackedTile] = []
        var myMeld: [TrackedTile] = []
        var pond: [TrackedTile] = []
        var opponent: [RelativeSeat: [TrackedTile]] = [:]
        var unresolved: [TrackedTile] = []

        let eligible = snapshot.tracks.filter {
            $0.lifecycle != .tentative && $0.lifecycle != .retired
        }.sorted {
            if $0.tablePoint.y != $1.tablePoint.y {
                return $0.tablePoint.y < $1.tablePoint.y
            }
            if $0.tablePoint.x != $1.tablePoint.x {
                return $0.tablePoint.x < $1.tablePoint.x
            }
            return $0.id < $1.id
        }

        for track in eligible {
            guard case .tile(let tile)? = track.face else { continue }
            let life: TrackedTile.Life = track.lifecycle == .confirmed
                ? .live
                : .missing
            let nx = Double(track.tablePoint.x / tableExtent.x + 0.5)
            let nz = Double(track.tablePoint.y / tableExtent.y + 0.5)
            let box = TileBoundingBox(
                x: nx - Double(0.024 / tableExtent.x) / 2,
                y: nz - Double(0.032 / tableExtent.y) / 2,
                width: Double(0.024 / tableExtent.x),
                height: Double(0.032 / tableExtent.y)
            )
            let confidence = max(0, min(1, 1 - exp(-Double(max(0, track.faceConfidence)))))
            func makeTracked(_ zone: TileZone, seat: RelativeSeat? = nil) -> TrackedTile {
                TrackedTile(
                    id: TrackID(raw: track.id.value),
                    face: tile,
                    faceConfidence: confidence,
                    box: box,
                    zone: zone,
                    seat: seat,
                    state: life,
                    firstSeen: track.firstSeen,
                    lastSeen: track.lastSeen
                )
            }

            switch track.semanticZone {
            case .mineHand:
                if tile.isBonus { bonus.append(makeTracked(.myBonus)) }
                else { hand.append(makeTracked(.myHand)) }
            case .mineMeld:
                myMeld.append(makeTracked(.myMeld))
            case .tablePond:
                pond.append(makeTracked(.pond))
            case .tableRevealedLeft:
                opponent[.left, default: []].append(makeTracked(.opponentMeld, seat: .left))
            case .tableRevealedFar:
                opponent[.across, default: []].append(makeTracked(.opponentMeld, seat: .across))
            case .tableRevealedRight:
                opponent[.right, default: []].append(makeTracked(.opponentMeld, seat: .right))
            case .ignoredWall:
                break
            case .boundaryUnresolved:
                unresolved.append(makeTracked(.unresolved))
            }
        }

        let myMelds = myMeld.isEmpty ? [] : [myMeld]
        let opponentMelds = opponent.mapValues { $0.isEmpty ? [] : [$0] }
        var seen = Array(repeating: 0, count: Tile.baseClassCount)
        for tracked in pond + opponent.values.flatMap({ $0 })
            where !tracked.face.isBonus {
            seen[tracked.face.classIndex] += 1
        }
        let mineCount = hand.filter { !$0.face.isBonus }.count
            + myMeld.filter { !$0.face.isBonus }.count
        let unseen = max(0, 136 - mineCount - seen.reduce(0, +))

        return TrackedTableState(
            revision: legacy.revision + censusRevision,
            phase: legacy.phase,
            handIndex: legacy.handIndex,
            mySeatWind: legacy.mySeatWind,
            roundWind: legacy.roundWind,
            currentTurn: legacy.currentTurn,
            myHand: hand,
            myBonus: bonus,
            myMelds: myMelds,
            pond: pond.sorted {
                if $0.firstSeen != $1.firstSeen { return $0.firstSeen < $1.firstSeen }
                return $0.id < $1.id
            },
            opponentMelds: opponentMelds,
            unresolved: unresolved,
            seenHistogram: seen,
            unseenCount: unseen,
            handTileCount: hand.filter { !$0.face.isBonus }.count,
            isMyHandComplete: legacy.isMyHandComplete
        )
    }
}
