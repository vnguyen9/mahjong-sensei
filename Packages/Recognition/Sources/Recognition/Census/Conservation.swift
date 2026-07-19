import MahjongCore

/// §10.3: physical constraints applied after association and face fusion —
/// diagnostic signals for duplicate association or misclassification, never
/// data to silently clamp. Generic over a caller-supplied "placed track"
/// shape so it stays a pure, independently testable function instead of
/// reaching into ``PhysicalCensus`` internals.
enum Conservation {
    /// At most 4 copies of a suited/honor tile, 1 of a flower/season, across
    /// confirmed MINE + TABLE.
    static func maxCopies(of tile: Tile) -> Int {
        switch tile {
        case .flower, .season: return 1
        case .suited, .wind, .dragon: return 4
        }
    }

    /// Returns the IDs of the tracks that must be downgraded to `.unresolved`
    /// to bring every tile's count back under its physical cap. When a tile
    /// is over-count, the *lowest*-confidence conflicting track(s) are
    /// downgraded first; ties break on ascending `CensusTrackID` so re-running
    /// on identical input always downgrades the same tracks (§10.3: violations
    /// downgrade "the lowest-confidence conflicting track").
    static func violatingTrackIDs<T>(among tracks: [T],
                                     tile: (T) -> Tile,
                                     id: (T) -> CensusTrackID,
                                     confidence: (T) -> Float) -> Set<CensusTrackID> {
        var toDowngrade: Set<CensusTrackID> = []
        let grouped = Dictionary(grouping: tracks, by: tile)
        for (facedTile, group) in grouped {
            let cap = maxCopies(of: facedTile)
            guard group.count > cap else { continue }
            let ordered = group.sorted { a, b in
                let confidenceA = confidence(a), confidenceB = confidence(b)
                if confidenceA != confidenceB { return confidenceA < confidenceB } // lowest confidence first
                return id(a) < id(b) // deterministic tie-break
            }
            let excess = group.count - cap
            for track in ordered.prefix(excess) { toDowngrade.insert(id(track)) }
        }
        return toDowngrade
    }
}
