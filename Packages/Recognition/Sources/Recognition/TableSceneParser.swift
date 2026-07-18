import Foundation
import MahjongCore

/// One whole-table frame, zoned into the two coaching buckets.
///
/// - `mine` — my concealed rank (plus an adjacent drawn tile and any displayed
///   bonus tiles). Structure feeds `Hand`.
/// - `myMelds` — exposed 3–4 tile groups at my edge of the table (pung/kong/chow
///   I've claimed). Also structural.
/// - `table` — every other face-up tile: the pond and opponents' melds. Only the
///   counts matter (each visible copy is a dead out).
/// - `unresolved` — face-up tiles near my edge the zoner couldn't place (a lone
///   far tile at hand scale, a 2-tile group…). Surfaced for confirm/correct UI.
public struct TableScene: Sendable, Hashable {
    public var mine: [DetectedTile]
    public var myMelds: [[DetectedTile]]
    public var table: [DetectedTile]
    public var unresolved: [DetectedTile]
    /// 0…1 — how sure the zoner is that `mine` really is the player's rank.
    public var confidence: Double

    public init(mine: [DetectedTile], myMelds: [[DetectedTile]], table: [DetectedTile],
                unresolved: [DetectedTile], confidence: Double) {
        self.mine = mine; self.myMelds = myMelds; self.table = table
        self.unresolved = unresolved; self.confidence = confidence
    }

    public static let empty = TableScene(mine: [], myMelds: [], table: [], unresolved: [], confidence: 0)
}

/// Splits a whole-table frame of detections into MINE / MY-MELDS / TABLE using
/// pure geometry — the human rule ("the closest, bottom-most line of tiles is
/// mine; the rest is the table's") in measurable terms:
///
/// 1. **Cluster** boxes into physical groups: two tiles neighbor when their
///    centers sit within ~2 tile-heights *and* their sizes are compatible —
///    apparent size is the depth cue, so a big near tile never chains to a
///    small far one.
/// 2. **Pick my cluster**: the bottom-most cluster of big tiles (absolute size
///    floor keeps a close-up pond from impersonating a rank).
/// 3. **Decompose it into lines and runs** along its principal axis (a handheld
///    photo rolls a few degrees — rows are diagonal in image space, so naive
///    y-banding fragments them). Longest bottom run = my rank; adjacent lone
///    tile = my draw; all-bonus runs = my displayed flowers; 3–4 tile runs =
///    my melds; anything else near my edge = unresolved.
/// 4. **Everything else is TABLE.** Walls and tile backs never appear at all
///    (the detector has no `back` class), so every input is face-up.
public enum TableSceneParser {

    public struct Config: Sendable {
        /// Neighbor reach: centers within `eps × min(heightA, heightB)`.
        public var eps: Double = 1.9
        /// Neighbor size compatibility: taller/shorter box ratio at most this.
        public var maxSizeRatio: Double = 1.55
        /// Perpendicular split into lines at gaps > this × the cluster's median height.
        public var lineGapFactor: Double = 0.7
        /// Along-axis split into runs at gaps > this × the cluster's median width.
        public var runGapFactor: Double = 1.7
        /// Other clusters count as "my edge" at ≥ this × the rank's median height…
        public var meldScaleFactor: Double = 0.72
        /// …and no further above my rank than this × its median height.
        public var depthSlackFactor: Double = 3.0
        /// A lone tile adopts into the rank within this × median width (the draw).
        public var drawnTileGapFactor: Double = 3.0
        /// Displayed bonus tiles adopt into mine only within this × the rank's
        /// median height of a rank tile — a far flower is someone else's.
        public var bonusAdoptGapFactor: Double = 2.5
        /// The rank must be at least this many tiles (4 concealed = 3 melds out).
        public var minHandCount: Int = 4
        /// Absolute floor for rank tile height (normalized). A player's-seat shot
        /// puts the rank at ~0.07–0.12 of the frame; pond tiles sit well below.
        public var minHandTileHeight: Double = 0.055
        public init() {}
    }

    public static func parse(_ tiles: [DetectedTile], config: Config = Config()) -> TableScene {
        guard !tiles.isEmpty else { return .empty }

        let clusters = cluster(tiles, config: config)
        guard let handIndex = handClusterIndex(in: clusters, config: config) else {
            // No rank in frame (pond close-up, single-tile lookup…) — counts only.
            return TableScene(mine: [], myMelds: [], table: tiles, unresolved: [], confidence: 0.2)
        }

        let hand = clusters[handIndex]
        let handMedianH = median(hand.map(\.box.height))
        let handMedianW = median(hand.map(\.box.width))

        // Decompose my cluster into lines ⊥ to its principal axis, runs along it.
        let handLines = lines(of: hand, medianHeight: handMedianH, config: config)
        let rankLineIndex = handLines.indices.max { handLines[$0].meanDepth < handLines[$1].meanDepth }!
        let rankRuns = runs(of: handLines[rankLineIndex], medianWidth: handMedianW, config: config)
        let rankIndex = rankRuns.indices.max {
            (rankRuns[$0].count, median(rankRuns[$0].map(\.box.height)))
                < (rankRuns[$1].count, median(rankRuns[$1].map(\.box.height)))
        }!

        var mine = rankRuns[rankIndex]
        var myMelds: [[DetectedTile]] = []
        var table: [DetectedTile] = []
        var unresolved: [DetectedTile] = []

        let axis = principalAxis(of: hand)
        let rankSpan = span(of: mine, along: axis.u)
        let rankTiles = mine   // adjacency reference — never the growing `mine`

        func place(run: [DetectedTile], inRankLine: Bool) {
            if run.allSatisfy({ $0.tile.isBonus }) {
                // My displayed flowers sit beside my rank; a far bonus tile is
                // another player's display — and can never be a meld either.
                let nearRank = run.contains { tile in
                    rankTiles.contains { rank in
                        let dx = tile.box.centerX - rank.box.centerX
                        let dy = tile.box.centerY - rank.box.centerY
                        return (dx * dx + dy * dy).squareRoot()
                            <= config.bonusAdoptGapFactor * handMedianH
                    }
                }
                if nearRank { mine += run } else { unresolved += run }
                return
            }
            if run.count == 1, inRankLine,
               let p = run.first.map({ project($0.box, on: axis.u) }),
               min(abs(p - rankSpan.lowerBound), abs(p - rankSpan.upperBound))
                   <= config.drawnTileGapFactor * handMedianW {
                mine += run                                                  // the drawn tile
                return
            }
            switch run.count {
            case 3...4: myMelds.append(run)
            default:    unresolved += run
            }
        }

        for (li, line) in handLines.enumerated() {
            for (ri, run) in runs(of: line, medianWidth: handMedianW, config: config).enumerated() {
                if li == rankLineIndex && ri == rankIndex { continue }
                place(run: run, inRankLine: li == rankLineIndex)
            }
        }

        // Other clusters: my-edge scale + depth → meld machinery; otherwise table.
        let rankMeanY = mine.map(\.box.centerY).reduce(0, +) / Double(max(1, mine.count))
        for (i, other) in clusters.enumerated() where i != handIndex {
            let mh = median(other.map(\.box.height))
            let cy = other.map(\.box.centerY).reduce(0, +) / Double(other.count)
            if mh >= config.meldScaleFactor * handMedianH,
               cy >= rankMeanY - config.depthSlackFactor * handMedianH {
                let mw = median(other.map(\.box.width))
                for line in lines(of: other, medianHeight: mh, config: config) {
                    for run in runs(of: line, medianWidth: mw, config: config) {
                        place(run: run, inRankLine: false)
                    }
                }
            } else {
                table += other
            }
        }

        // Confidence: penalize leftovers, an implausible concealed count, and
        // weak depth separation between my rank and the table.
        var confidence = 1.0
        if !unresolved.isEmpty { confidence *= 0.75 }
        let concealed = mine.filter { !$0.tile.isBonus }.count
        let expected = [13 - 3 * myMelds.count, 14 - 3 * myMelds.count]
        if !expected.contains(concealed) { confidence *= 0.7 }
        if !table.isEmpty, handMedianH / max(0.001, median(table.map(\.box.height))) < 1.25 {
            confidence *= 0.85
        }

        return TableScene(mine: mine, myMelds: myMelds, table: table,
                          unresolved: unresolved, confidence: confidence)
    }

    // MARK: - Clustering (union-find over the neighbor graph)

    static func cluster(_ tiles: [DetectedTile], config: Config) -> [[DetectedTile]] {
        var parent = Array(tiles.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in tiles.indices {
            for j in tiles.indices.dropFirst(i + 1) {
                let a = tiles[i].box, b = tiles[j].box
                let hMin = min(a.height, b.height), hMax = max(a.height, b.height)
                guard hMin > 0, hMax / hMin <= config.maxSizeRatio else { continue }
                let dx = a.centerX - b.centerX, dy = a.centerY - b.centerY
                guard (dx * dx + dy * dy).squareRoot() <= config.eps * hMin else { continue }
                let ri = find(i), rj = find(j)
                if ri != rj { parent[ri] = rj }
            }
        }
        var groups: [Int: [DetectedTile]] = [:]
        for i in tiles.indices { groups[find(i), default: []].append(tiles[i]) }
        return groups.keys.sorted().map { groups[$0]! }   // deterministic order
    }

    /// The bottom-most cluster of big tiles, or nil when nothing rank-like exists.
    static func handClusterIndex(in clusters: [[DetectedTile]], config: Config) -> Int? {
        clusters.indices
            .filter { clusters[$0].count >= config.minHandCount }
            .filter { median(clusters[$0].map(\.box.height)) >= config.minHandTileHeight }
            .max { score(clusters[$0]) < score(clusters[$1]) }
    }

    private static func score(_ cluster: [DetectedTile]) -> Double {
        let meanY = cluster.map(\.box.centerY).reduce(0, +) / Double(cluster.count)
        return median(cluster.map(\.box.height)) * (0.35 + meanY)   // big and near the bottom
    }

    // MARK: - Lines & runs along the principal axis

    struct Axis { var u: (x: Double, y: Double); var v: (x: Double, y: Double) }

    struct TileLine {
        var tiles: [DetectedTile]
        /// Mean projection on `v` (down-pointing) — larger = nearer the player.
        var meanDepth: Double
        var axis: Axis
    }

    /// Principal axis via the 2×2 covariance of centers. `u` points rightward
    /// along the dominant direction, `v` ⊥ downward (toward the player).
    static func principalAxis(of tiles: [DetectedTile]) -> Axis {
        let n = Double(tiles.count)
        let mx = tiles.map(\.box.centerX).reduce(0, +) / n
        let my = tiles.map(\.box.centerY).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for t in tiles {
            let dx = t.box.centerX - mx, dy = t.box.centerY - my
            sxx += dx * dx; sxy += dx * dy; syy += dy * dy
        }
        guard tiles.count >= 3, sxx + syy > 0 else {
            return Axis(u: (1, 0), v: (0, 1))
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        var u = (x: cos(theta), y: sin(theta))
        if u.x < 0 { u = (-u.x, -u.y) }
        var v = (x: -u.y, y: u.x)
        if v.y < 0 { v = (-v.x, -v.y) }
        return Axis(u: u, v: v)
    }

    static func project(_ box: TileBoundingBox, on direction: (x: Double, y: Double)) -> Double {
        box.centerX * direction.x + box.centerY * direction.y
    }

    static func span(of tiles: [DetectedTile], along u: (x: Double, y: Double)) -> ClosedRange<Double> {
        let projections = tiles.map { project($0.box, on: u) }
        return (projections.min() ?? 0)...(projections.max() ?? 0)
    }

    /// Split a cluster into parallel lines: 1-D cluster of the ⊥ projections.
    static func lines(of tiles: [DetectedTile], medianHeight: Double, config: Config) -> [TileLine] {
        let axis = principalAxis(of: tiles)
        let sorted = tiles.sorted { project($0.box, on: axis.v) < project($1.box, on: axis.v) }
        var result: [TileLine] = []
        var current: [DetectedTile] = []
        var last: Double?
        for tile in sorted {
            let p = project(tile.box, on: axis.v)
            if let last, p - last > config.lineGapFactor * medianHeight {
                result.append(makeLine(current, axis: axis)); current = []
            }
            current.append(tile)
            last = p
        }
        if !current.isEmpty { result.append(makeLine(current, axis: axis)) }
        return result
    }

    private static func makeLine(_ tiles: [DetectedTile], axis: Axis) -> TileLine {
        let depth = tiles.map { project($0.box, on: axis.v) }.reduce(0, +) / Double(tiles.count)
        return TileLine(tiles: tiles, meanDepth: depth, axis: axis)
    }

    /// Split a line into contiguous runs: 1-D cluster of the along-axis projections.
    static func runs(of line: TileLine, medianWidth: Double, config: Config) -> [[DetectedTile]] {
        let sorted = line.tiles.sorted { project($0.box, on: line.axis.u) < project($1.box, on: line.axis.u) }
        var result: [[DetectedTile]] = []
        var current: [DetectedTile] = []
        var last: Double?
        for tile in sorted {
            let p = project(tile.box, on: line.axis.u)
            if let last, p - last > config.runGapFactor * medianWidth {
                result.append(current); current = []
            }
            current.append(tile)
            last = p
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: -

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}
