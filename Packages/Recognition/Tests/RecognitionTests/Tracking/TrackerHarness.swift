import Foundation
@testable import Recognition
import MahjongCore

/// Composes `TrackStore` + `ZoneModel` + `TurnEngine` exactly the way the
/// (not-yet-built) `TableTracker` facade will, so the zone/turn tests exercise
/// the real settle-diff call order instead of a stubbed one. It *is* the
/// executable spec of "how the facade drives these chunks per ingest":
///
///   1. `store.associate(detections, at:, motion:)` — every frame, motion or not.
///   2. Update the settle gate (motion below `motionSettle` for `settleDelay`).
///   3. Only on a **settled** frame:
///        a. `zoneModel.ingestSettled(...)`  — writes zones first, so
///        b. `turnEngine.commitSettled(...)` sees current zones + the pond
///           centroid ZoneModel just updated, and the burst region that
///           preceded this settle.
///
/// Nothing commits mid-motion; that's the whole point. Deterministic: no
/// `Date()`, timestamps come straight from the frame stream.
final class TrackerHarness {
    let config: TrackerConfig
    let store: TrackStore
    let zoneModel: ZoneModel
    let turnEngine: TurnEngine

    private(set) var events: [GameEvent] = []
    private(set) var settledTimes: [TimeInterval] = []

    private var belowSince: TimeInterval?
    private var burstRegion: MotionRegion?
    var handIndex = 0

    init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
        store = TrackStore(config: config)
        zoneModel = ZoneModel(config: config)
        turnEngine = TurnEngine(config: config)
    }

    @discardableResult
    func run(_ frames: [(t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])]) -> [GameEvent] {
        for f in frames { step(f) }
        return events
    }

    func step(_ f: (t: TimeInterval, motion: MotionSample, tiles: [DetectedTile])) {
        let outcome = store.associate(f.tiles, at: f.t, motion: f.motion)

        // Remember the region of the burst that precedes a settle — attribution
        // evidence. A settled frame's own low-motion sample never overwrites it.
        if f.motion.level >= config.motionActive { burstRegion = f.motion.dominantRegion }

        guard isSettled(level: f.motion.level, at: f.t) else { return }
        settledTimes.append(f.t)
        zoneModel.ingestSettled(detections: f.tiles, outcome: outcome, store: store, at: f.t)
        events += turnEngine.commitSettled(store: store, handIndex: handIndex,
                                           motionRegion: burstRegion,
                                           pondCentroid: zoneModel.pondCentroid, at: f.t)
    }

    private func isSettled(level: Double, at t: TimeInterval) -> Bool {
        if level <= config.motionSettle {
            if belowSince == nil { belowSince = t }
        } else {
            belowSince = nil
        }
        guard let since = belowSince else { return false }
        return t - since >= config.settleDelay
    }
}
