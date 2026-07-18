import Foundation
@testable import Recognition
import MahjongCore

/// A tiny, fast, seedable PRNG (splitmix64, public-domain algorithm by
/// Sebastiano Vigna) — deliberately NOT `SystemRandomNumberGenerator`.
/// `ScriptedGame` must produce a byte-identical detection stream for a given
/// seed across runs and machines, which system randomness can never
/// guarantee. Conforms to `RandomNumberGenerator` so it drops straight into
/// `Double.random(in:using:)` etc.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Fixed table geometry a `ScriptedGame` places tiles into, in normalized
/// oriented-image coordinates (same convention as `TileBoundingBox`). The
/// hand row, bonus row, and per-seat pond/meld anchors mirror the builders
/// in `TableSceneParserTests` (rank at y≈0.84 h 0.08, pond tiles ~0.026×0.04
/// mid-frame, meld clusters near each seat's table edge) so a generated
/// stream parses through `TableSceneParser` exactly like the real fixtures
/// do.
struct TableLayout {
    // My concealed rank — mirrors TableSceneParserTests.rank(...).
    var handStartX = 0.125
    var handPitch = 0.052
    var handY = 0.84
    var handTileWidth = 0.05
    var handTileHeight = 0.08

    // My displayed bonus tiles — mirrors testBonusRowJoinsMine.
    var bonusStartX = 0.125
    var bonusPitch = 0.052
    var bonusY = 0.72
    var bonusTileWidth = 0.045
    var bonusTileHeight = 0.07

    // Discard pond — mirrors TableSceneParserTests.pond(...) scale, split
    // into one small grid per seat so geometry can plausibly attribute a
    // discard to its seat later (TurnEngine, a later chunk).
    var pondTileWidth = 0.026
    var pondTileHeight = 0.04
    var pondPitch = 0.03
    var pondPerRow = 3

    // Opponent/my melds — mirrors the topMeld/sideMeld builders in
    // testOpponentMeldsAndPondGoToTable and the beside-rank meld in
    // testMeldSplitFromRankRow.
    var meldTileWidth = 0.047
    var meldTileHeight = 0.075

    static let playerSeat = TableLayout()

    func handSlotBox(index: Int) -> TileBoundingBox {
        Self.centerBox(cx: handStartX + Double(index) * handPitch, cy: handY,
                       w: handTileWidth, h: handTileHeight)
    }

    func bonusSlotBox(index: Int) -> TileBoundingBox {
        Self.centerBox(cx: bonusStartX + Double(index) * bonusPitch, cy: bonusY,
                       w: bonusTileWidth, h: bonusTileHeight)
    }

    /// Table-center-relative anchor for a seat's discard pond. `me` sits
    /// just above my own rank; `right`/`across`/`left` sit toward that
    /// seat's edge — the quadrant convention `ZoneModel` (a later chunk)
    /// uses to attribute an opponent cluster by displacement from the pond
    /// centroid (dx<0 → left, dx>0 → right, dy<0 → across, dy>0 → me).
    func pondAnchor(for seat: RelativeSeat) -> (x: Double, y: Double) {
        switch seat {
        case .me:     return (0.50, 0.64)
        case .right:  return (0.64, 0.50)
        case .across: return (0.50, 0.36)
        case .left:   return (0.36, 0.50)
        }
    }

    func pondSlotBox(seat: RelativeSeat, index: Int) -> TileBoundingBox {
        let anchor = pondAnchor(for: seat)
        let row = index / pondPerRow, col = index % pondPerRow
        let cx = anchor.x + (Double(col) - Double(pondPerRow - 1) / 2) * pondPitch
        let cy = anchor.y + Double(row) * pondPitch
        return Self.centerBox(cx: cx, cy: cy, w: pondTileWidth, h: pondTileHeight)
    }

    func meldAnchor(for seat: RelativeSeat) -> (x: Double, y: Double) {
        switch seat {
        case .me:     return (0.80, 0.84)   // beside my rank, like testMeldSplitFromRankRow
        case .right:  return (0.94, 0.50)   // mirrors the sideMeld edge, opposite side
        case .across: return (0.50, 0.12)   // mirrors topMeld
        case .left:   return (0.06, 0.50)   // mirrors sideMeld
        }
    }

    /// `groupIndex` staggers a seat's 2nd+ meld group further from the
    /// anchor so multiple claimed melds never overlap the same tiles.
    func meldSlotBox(seat: RelativeSeat, groupIndex: Int, index: Int, of total: Int) -> TileBoundingBox {
        let anchor = meldAnchor(for: seat)
        let groupOffset = Double(groupIndex) * meldTileHeight * 1.4
        let along = (Double(index) - Double(total - 1) / 2) * meldTileWidth * 1.05
        switch seat {
        case .across:
            return Self.centerBox(cx: anchor.x + along, cy: anchor.y - groupOffset,
                                  w: meldTileWidth, h: meldTileHeight)
        case .left:
            return Self.centerBox(cx: anchor.x - groupOffset, cy: anchor.y + along,
                                  w: meldTileWidth, h: meldTileHeight)
        case .right:
            return Self.centerBox(cx: anchor.x + groupOffset, cy: anchor.y + along,
                                  w: meldTileWidth, h: meldTileHeight)
        case .me:
            return Self.centerBox(cx: anchor.x + Double(index) * meldTileWidth * 1.05, cy: anchor.y + groupOffset,
                                  w: meldTileWidth, h: meldTileHeight)
        }
    }

    private static func centerBox(cx: Double, cy: Double, w: Double, h: Double) -> TileBoundingBox {
        TileBoundingBox(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

/// `ScriptedGame`'s synthetic detector noise. Applied only at `frames()`
/// render time — building the script (`deal`/`discard`/…) is pure geometry.
struct NoiseModel {
    /// Gaussian box jitter, × tile size (applied independently to x using
    /// `width` and y using `height`).
    var boxJitter = 0.15
    /// Per-tile per-frame miss probability while the scene is settled.
    var dropoutIdle = 0.06
    /// Per-tile per-frame miss probability during an action window/occlusion.
    var dropoutAction = 0.5
    /// Probability a rendered tile's face swaps to a confusable lookalike
    /// (7s↔8s, GD↔8s, RD↔1m).
    var faceFlicker = 0.05
    var confidenceRange = 0.35...0.97

    static let `default` = NoiseModel()
}

/// Seeded synthetic detection-stream generator — the offline test double for
/// "a camera watching a real game". A test scripts a sequence of dated table
/// events (`deal`, `discard`, `claim`, `myDraw`, `myDiscard`, `nudge`,
/// `occlude`, `clearTable`) against a fixed `TableLayout`, then `frames()`
/// renders that script into a `[DetectedTile]` stream at a chosen frame
/// rate, with injected noise standing in for the real detector's jitter,
/// misses, and lookalike confusion.
///
/// Determinism is the whole point (later chunks — TrackStore, ZoneModel,
/// TurnEngine — are tested against these streams, and `ReplayFixtureTests`
/// needs byte-identical replays): every random decision at render time comes
/// from a `SplitMix64` seeded from `seed`, and `frames()` reseeds a *local*
/// generator on every call (never mutates a stored one), so calling it twice
/// on the same instance — or constructing two instances with the same seed
/// and script — always returns the same stream.
///
/// Script-building itself needs no randomness at all: every mutating method
/// places tiles at fixed `TableLayout` slots, so WHERE something appears is
/// a pure function of the script, not the seed. Only the render-time noise
/// (jitter/dropout/flicker/confidence/detection ids) depends on `seed`.
struct ScriptedGame {
    private let seed: UInt64
    private let layout: TableLayout

    private var placedTiles: [PlacedTile] = []
    private var actionWindows: [ActionWindow] = []
    private var scriptEnd: TimeInterval = 0

    private var handSlotCount = 0
    private var bonusSlotCount = 0
    private var pondSlotCount: [RelativeSeat: Int] = [:]
    private var meldGroupCount: [RelativeSeat: Int] = [:]

    /// Every scripted event injects this long an action window (elevated
    /// motion + dropout, dominant region set to the acting seat's side) —
    /// exercises exactly the settle-diff machinery `TurnEngine` (a later
    /// chunk) relies on.
    private static let actionWindowDuration: TimeInterval = 1.2
    /// Trailing settled time appended after the last scripted event so its
    /// aftermath is actually observable in `frames()`.
    private static let settleTail: TimeInterval = 1.5
    /// Floor on the generated timeline so a bare `deal()`-only script still
    /// yields a few settled frames.
    private static let minimumTimeline: TimeInterval = 1.0

    init(seed: UInt64, layout: TableLayout = .playerSeat) {
        self.seed = seed
        self.layout = layout
    }

    // MARK: - Scripting

    /// The starting, settled layout at t=0: non-bonus tiles fill the rank
    /// row in the given (reading) order, bonus tiles fill the bonus row.
    mutating func deal(myHand: [Tile]) {
        for tile in myHand {
            if tile.isBonus {
                placedTiles.append(PlacedTile(face: tile, zone: .myBonus, seat: .me,
                                              baseBox: layout.bonusSlotBox(index: bonusSlotCount), appearsAt: 0))
                bonusSlotCount += 1
            } else {
                placedTiles.append(PlacedTile(face: tile, zone: .myHand, seat: .me,
                                              baseBox: layout.handSlotBox(index: handSlotCount), appearsAt: 0))
                handSlotCount += 1
            }
        }
    }

    /// `seat` discards `tile`: a new pond track appears at `seat`'s pond
    /// slot at time `t`.
    mutating func discard(_ seat: RelativeSeat, _ tile: Tile, at t: TimeInterval) {
        let index = pondSlotCount[seat, default: 0]
        pondSlotCount[seat] = index + 1
        placedTiles.append(PlacedTile(face: tile, zone: .pond, seat: seat,
                                      baseBox: layout.pondSlotBox(seat: seat, index: index), appearsAt: t))
        registerActionWindow(at: t, region: seat.scriptedMotionRegion)
    }

    /// `seat` claims a meld: `tiles` appear together as a new cluster at
    /// `seat`'s meld anchor, and the most recently discarded still-visible
    /// pond tile matching one of `tiles` vanishes (it physically became
    /// part of the meld) — mirrors the real detector losing that pond track
    /// the instant the claim lands. Each call appends a *new* meld group for
    /// `seat`; scripting a pung→kong upgrade in place (same group gaining a
    /// 4th tile) is out of this primitive's scope.
    mutating func claim(_ kind: MeldKind, by seat: RelativeSeat, tiles: [Tile], at t: TimeInterval) {
        if let claimedIdx = placedTiles.indices
            .filter({ placedTiles[$0].zone == .pond && placedTiles[$0].isVisible(at: t)
                     && tiles.contains(placedTiles[$0].face) })
            .max(by: { placedTiles[$0].appearsAt < placedTiles[$1].appearsAt }) {
            placedTiles[claimedIdx].disappearsAt = t
        }
        let zone: TileZone = seat == .me ? .myMeld : .opponentMeld
        let groupIndex = meldGroupCount[seat, default: 0]
        meldGroupCount[seat] = groupIndex + 1
        for (i, face) in tiles.enumerated() {
            placedTiles.append(PlacedTile(face: face, zone: zone, seat: seat,
                                          baseBox: layout.meldSlotBox(seat: seat, groupIndex: groupIndex,
                                                                       index: i, of: tiles.count),
                                          appearsAt: t))
        }
        registerActionWindow(at: t, region: seat.scriptedMotionRegion)
    }

    /// I draw `tile`: it joins my hand (rank row) or bonus row as a 14th /
    /// extra displayed tile.
    mutating func myDraw(_ tile: Tile, at t: TimeInterval) {
        if tile.isBonus {
            placedTiles.append(PlacedTile(face: tile, zone: .myBonus, seat: .me,
                                          baseBox: layout.bonusSlotBox(index: bonusSlotCount), appearsAt: t))
            bonusSlotCount += 1
        } else {
            placedTiles.append(PlacedTile(face: tile, zone: .myHand, seat: .me,
                                          baseBox: layout.handSlotBox(index: handSlotCount), appearsAt: t))
            handSlotCount += 1
        }
        registerActionWindow(at: t, region: RelativeSeat.me.scriptedMotionRegion)
    }

    /// I discard `tile`: one matching, currently-visible hand track retires
    /// (no event of its own — the moved tile is one *new* pond track,
    /// mirroring `TurnEngine`'s rule for linking a hand-loss to a pond-birth
    /// as a single `myDiscard`).
    mutating func myDiscard(_ tile: Tile, at t: TimeInterval) {
        if let idx = placedTiles.indices.first(where: {
            placedTiles[$0].zone == .myHand && placedTiles[$0].face == tile && placedTiles[$0].isVisible(at: t)
        }) {
            placedTiles[idx].disappearsAt = t
        }
        let index = pondSlotCount[.me, default: 0]
        pondSlotCount[.me] = index + 1
        placedTiles.append(PlacedTile(face: tile, zone: .pond, seat: .me,
                                      baseBox: layout.pondSlotBox(seat: .me, index: index), appearsAt: t))
        registerActionWindow(at: t, region: RelativeSeat.me.scriptedMotionRegion)
    }

    /// Shifts the box of the `index`-th tile currently visible in `zone`
    /// (insertion order) by `dx` along x, starting at `t` — for exercising
    /// "a tile got bumped/nudged" scenarios (rebirth radius, intra-zone
    /// moves are never events) without creating or destroying a track.
    mutating func nudge(_ zone: TileZone, index: Int, by dx: Double, at t: TimeInterval) {
        let candidates = placedTiles.indices.filter { placedTiles[$0].zone == zone && placedTiles[$0].isVisible(at: t) }
        guard candidates.indices.contains(index) else { return }
        let target = candidates[index]
        var box = placedTiles[target].box(at: t)
        box.x += dx
        placedTiles[target].boxKeyframes.append((at: t, box: box))
        registerActionWindow(at: t, region: nil)
    }

    /// Hides a deterministic, evenly-spread `fraction` of the currently
    /// visible tiles (across every zone) for `[t, t+duration)`, simulating
    /// an arm/hand sweeping across part of the table. Which specific tiles
    /// are hidden doesn't matter for what this drives (mass-disappearance /
    /// occlusion-grace tests), so the subset is chosen by stride rather than
    /// by drawing from the seed — keeps `occlude` itself free of RNG state.
    mutating func occlude(fraction: Double, from t: TimeInterval, duration: TimeInterval) {
        let visible = placedTiles.indices.filter { placedTiles[$0].isVisible(at: t) }
        if !visible.isEmpty {
            let hideCount = min(visible.count, Int((fraction * Double(visible.count)).rounded()))
            for k in 0..<hideCount {
                let pos = (k * visible.count) / max(1, hideCount)
                placedTiles[visible[pos]].hiddenWindows.append((from: t, until: t + duration))
            }
        }
        registerActionWindow(at: t, region: nil, duration: duration)
    }

    /// The hand ends: every currently visible tile disappears at `t` — for
    /// `HandBoundaryDetector` (a later chunk) mass-disappearance tests.
    mutating func clearTable(at t: TimeInterval) {
        for i in placedTiles.indices where placedTiles[i].isVisible(at: t) {
            placedTiles[i].disappearsAt = t
        }
        registerActionWindow(at: t, region: nil)
    }

    // MARK: - Rendering

    /// Renders the script into a detection stream sampled at `fps`, with
    /// `noise` applied. Non-mutating and reseeds a local generator every
    /// call: `frames()` called twice on the same (or an identically-seeded
    /// and identically-scripted) instance always returns the same result.
    func frames(fps: Double = 8, noise: NoiseModel = .default) -> [(t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])] {
        var rng = SplitMix64(seed: seed)
        let end = max(scriptEnd + Self.settleTail, Self.minimumTimeline)
        let step = 1.0 / fps
        var result: [(t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])] = []

        var t = 0.0
        while t <= end + 1e-9 {
            let window = activeWindow(at: t)
            let dropoutP = window.isActive ? noise.dropoutAction : noise.dropoutIdle

            var tiles: [DetectedTile] = []
            for tile in placedTiles where tile.isVisible(at: t) {
                if Double.random(in: 0...1, using: &rng) < dropoutP { continue }

                var face = tile.face
                if Double.random(in: 0...1, using: &rng) < noise.faceFlicker,
                   let alternatives = Self.confusable[face], let picked = alternatives.randomElement(using: &rng) {
                    face = picked
                }

                let confidence = Double.random(in: noise.confidenceRange, using: &rng)
                var box = tile.box(at: t)
                box.x += gaussian(&rng, stdDev: noise.boxJitter * box.width)
                box.y += gaussian(&rng, stdDev: noise.boxJitter * box.height)

                tiles.append(DetectedTile(id: nextUUID(&rng), tile: face, confidence: confidence, box: box))
            }

            let idleJitter = Double.random(in: 0...0.01, using: &rng)
            let level = (window.isActive ? 0.3 : 0.0) + idleJitter
            let motion = MotionSample(t: t, level: level, dominantRegion: window.region)
            result.append((t: t, motion: motion, tiles: tiles))
            t += step
        }
        return result
    }

    // MARK: - Action windows

    private struct ActionWindow {
        var start: TimeInterval
        var end: TimeInterval
        var region: MotionRegion?
    }

    private mutating func registerActionWindow(at t: TimeInterval, region: MotionRegion?, duration: TimeInterval? = nil) {
        let end = t + (duration ?? Self.actionWindowDuration)
        actionWindows.append(ActionWindow(start: t, end: end, region: region))
        scriptEnd = max(scriptEnd, end)
    }

    /// Most-recently-started window wins the region when several overlap.
    private func activeWindow(at t: TimeInterval) -> (isActive: Bool, region: MotionRegion?) {
        guard let latest = actionWindows.filter({ $0.start <= t && t < $0.end }).max(by: { $0.start < $1.start }) else {
            return (false, nil)
        }
        return (true, latest.region)
    }

    // MARK: - Confusable faces (noise)

    private static let confusable: [Tile: [Tile]] = [
        .s(7): [.s(8)],
        .s(8): [.s(7), .greenDragon],
        .greenDragon: [.s(8)],
        .redDragon: [.m(1)],
        .m(1): [.redDragon],
    ]

    // MARK: - RNG helpers

    private func gaussian(_ rng: inout SplitMix64, stdDev: Double) -> Double {
        guard stdDev > 0 else { return 0 }
        let u1 = Double.random(in: .leastNonzeroMagnitude...1, using: &rng)
        let u2 = Double.random(in: 0...1, using: &rng)
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2) * stdDev
    }

    /// A fully seed-derived UUID (never `UUID()`, which draws system
    /// entropy) — `DetectedTile.id` still has to be *some* UUID, but it must
    /// be reproducible for `frames()` to be byte-identical across runs.
    private func nextUUID(_ rng: inout SplitMix64) -> UUID {
        let hi = rng.next(), lo = rng.next()
        let bytes = withUnsafeBytes(of: hi.bigEndian) { Array($0) } + withUnsafeBytes(of: lo.bigEndian) { Array($0) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// One tile placed into the script's world. Lifetime and box are both
/// piecewise-constant functions of time: `appearsAt`/`disappearsAt` (plus
/// temporary `hiddenWindows` from `occlude`) gate visibility, and
/// `boxKeyframes` (written by `nudge`) gate position — the box in effect at
/// time `t` is the most recent keyframe at/before `t`, or `baseBox` if none
/// yet. Purely internal bookkeeping for `ScriptedGame`; never exposed —
/// `frames()` only ever returns raw `DetectedTile`s.
private struct PlacedTile {
    let face: Tile
    let zone: TileZone
    let seat: RelativeSeat?
    let baseBox: TileBoundingBox
    let appearsAt: TimeInterval
    var disappearsAt: TimeInterval?
    var hiddenWindows: [(from: TimeInterval, until: TimeInterval)] = []
    var boxKeyframes: [(at: TimeInterval, box: TileBoundingBox)] = []

    func isVisible(at t: TimeInterval) -> Bool {
        guard appearsAt <= t else { return false }
        if let disappearsAt, t >= disappearsAt { return false }
        if hiddenWindows.contains(where: { $0.from <= t && t < $0.until }) { return false }
        return true
    }

    func box(at t: TimeInterval) -> TileBoundingBox {
        boxKeyframes.last(where: { $0.at <= t })?.box ?? baseBox
    }
}

private extension RelativeSeat {
    /// `ScriptedGame`'s own convention for mapping an acting seat to the
    /// coarse `MotionRegion` bucket its action window should report. `.me`
    /// has no dedicated bucket (the real detector only reports four coarse
    /// regions — see `MotionRegion`), so self-actions register as
    /// `.center`. This is scripting convenience, not a claim about how the
    /// real `MotionDetector`/`TurnEngine` (later chunks) derive or consume
    /// regions.
    var scriptedMotionRegion: MotionRegion {
        switch self {
        case .me:     return .center
        case .right:  return .right
        case .across: return .top
        case .left:   return .left
        }
    }
}
