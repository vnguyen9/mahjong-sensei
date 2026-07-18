import Foundation
import MahjongCore

/// The single place that turns a handful of tile faces into a scored
/// `Meld` — pung/kong (an all-equal triplet/quad) or chow (3 consecutive
/// same-suit ranks). Used by `TurnEngine` (labeling a claim, and building the
/// `[Meld]` handed to the injected win predicate), `ZoneModel` (the
/// table-subdivision meld-shape test that splits an opponent's cluster out
/// of the pond), and — via the `TrackedTableState` extension below — the
/// `TableTracker` facade and, eventually, the app's scoring/efficiency seams.
///
/// One implementation, everywhere: before this chunk, `TurnEngine` carried a
/// private, near-identical `inferMeldKind` free function that `ZoneModel`
/// also reached into, plus a separate private `proximityGroups` box-clusterer
/// used only to build the win-predicate's `[Meld]` list. Both are
/// consolidated here without changing behavior at either call site (same
/// shape test, same clustering rule, same results — `TurnEngineTests` and
/// `ZoneModelTests` stay green unmodified).
public enum MeldClassifier {

    /// Order-independent shape test: 3 equal faces → pung, 4 equal → kong,
    /// 3 same-suit consecutive ranks (sorted internally, so caller order
    /// never matters) → chow. Anything else — wrong count, mixed suits, a
    /// rank gap, a bonus tile, honors that aren't a triplet — → nil, not a
    /// meld. (This is exactly the old module-internal `inferMeldKind`'s
    /// logic, unchanged, just renamed and made public.)
    public static func classify(_ faces: [Tile]) -> MeldKind? {
        guard faces.count == 3 || faces.count == 4, let first = faces.first else { return nil }
        if faces.allSatisfy({ $0 == first }) { return faces.count == 4 ? .kong : .pung }
        guard faces.count == 3 else { return nil }
        let sorted = faces.sorted()
        guard let s0 = sorted[0].suit, sorted[1].suit == s0, sorted[2].suit == s0,
              let r0 = sorted[0].rank, let r1 = sorted[1].rank, let r2 = sorted[2].rank,
              r1 == r0 + 1, r2 == r1 + 1 else { return nil }
        return .chow
    }

    /// Groups a flat set of same-owner tracks (e.g. every `.myMeld`- or one
    /// seat's `.opponentMeld`-zoned tracks) into physical clusters by box
    /// proximity — the same "within ~2 tile-heights, compatible size"
    /// neighbor rule `TableSceneParser`/`ZoneModel` already use, via a
    /// lightweight union-find (reuses `sceneConfig`'s `eps`/`maxSizeRatio` so
    /// tuning one tunes all three consistently). What `TableTracker` needs to
    /// populate `TrackedTableState.myMelds`/`.opponentMelds` (raw
    /// `[TrackedTile]` groups, before scoring), and what `melds(groupingTracks:)`
    /// below builds on to go all the way to `[Meld]`.
    public static func physicalGroups(of tracks: [TrackedTile],
                                      sceneConfig: TableSceneParser.Config = TableSceneParser.Config()) -> [[TrackedTile]] {
        var parent = Array(tracks.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in tracks.indices {
            for j in tracks.indices.dropFirst(i + 1) {
                let a = tracks[i].box, b = tracks[j].box
                let hMin = min(a.height, b.height), hMax = max(a.height, b.height)
                guard hMin > 0, hMax / hMin <= sceneConfig.maxSizeRatio else { continue }
                let dx = a.centerX - b.centerX, dy = a.centerY - b.centerY
                guard (dx * dx + dy * dy).squareRoot() <= sceneConfig.eps * hMin else { continue }
                let ri = find(i), rj = find(j)
                if ri != rj { parent[ri] = rj }
            }
        }
        var groups: [Int: [TrackedTile]] = [:]
        for i in tracks.indices { groups[find(i), default: []].append(tracks[i]) }
        return groups.keys.sorted().map { groups[$0]! }
    }

    /// `physicalGroups(of:sceneConfig:)` followed by `classify` on each
    /// cluster's *voted* faces (steadier than a single frame's raw
    /// detections) — clusters that don't form a valid meld shape (a
    /// transiently half-formed group, mid-claim) are silently dropped rather
    /// than surfaced as garbage. `isConcealed` is a flat stamp: the detector
    /// never sees concealed kongs (no `back` class), so every meld this
    /// pipeline ever sees is physically exposed; callers pass `false`.
    public static func melds(groupingTracks tracks: [TrackedTile],
                             sceneConfig: TableSceneParser.Config = TableSceneParser.Config(),
                             isConcealed: Bool = false) -> [Meld] {
        physicalGroups(of: tracks, sceneConfig: sceneConfig).compactMap { group in
            let faces = group.map(\.face).sorted()
            guard let kind = classify(faces) else { return nil }
            return Meld(kind: kind, tiles: faces, isConcealed: isConcealed)
        }
    }
}

// MARK: - TrackedTableState conveniences (deferred by chunk 1 — see its NOTE
// comment in TrackingModels.swift, which points here explicitly)

public extension TrackedTableState {
    /// My exposed melds as scored `Meld`s — each `myMelds` group's voted
    /// faces run through `MeldClassifier.classify`. A group that doesn't
    /// classify (a transiently malformed cluster) is dropped rather than
    /// surfaced as garbage; in steady state every group here classifies,
    /// since `TableTracker` builds `myMelds` via `MeldClassifier` in the
    /// first place.
    var meldsAsMelds: [Meld] {
        myMelds.compactMap { group in
            let faces = group.map(\.face)
            guard let kind = MeldClassifier.classify(faces) else { return nil }
            return Meld(kind: kind, tiles: faces, isConcealed: false)
        }
    }

    /// The scoring-ready `Hand` for the injected rule engines (win predicate,
    /// wait-impact math): my concealed rank + `meldsAsMelds` + bonus tiles —
    /// faces only, tracking metadata dropped, matching `Hand`'s own shape.
    /// `winningTile` is left nil here (the caller scoring an actual win knows
    /// which tile completed it; this is the general-purpose snapshot).
    func hand(isSelfDraw: Bool) -> Hand {
        Hand(concealedTiles: myHand.map(\.face),
             melds: meldsAsMelds,
             bonusTiles: myBonus.map(\.face),
             winningTile: nil,
             isSelfDraw: isSelfDraw)
    }
}
