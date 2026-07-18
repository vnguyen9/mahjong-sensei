import Foundation
import MahjongCore
import Recognition

/// Feeds one already-parsed `.frames.jsonl` stream through a fresh
/// `TableTracker`, in file order, with no wall clock anywhere — every
/// timestamp comes straight from `FrameRecord.t`. This is the single replay
/// path shared by the `track-replay` executable and `HarnessKitTests`'s
/// negative-control golden test, so the CLI and the test can never quietly
/// diverge on what "replaying a stream" means.
///
/// `TrackerConfig()` defaults throughout, and `TrackerConfig.winPredicate`
/// is deliberately left `nil`: this harness lives outside `Packages/` and
/// has no reason to depend on `ScoringEngine` for a win check the tracker
/// plan itself treats as an app/CLI-injected seam (`TrackerConfig.swift`'s
/// own doc — "Recognition never imports ScoringEngine").
public enum TrackReplay {
    /// Runs one already-decoded stream to completion and returns everything
    /// the CLI/tests need: the full event log, the final published state,
    /// any still-pending hand-end proposal, and live/tentative/missing
    /// counts.
    public static func replay(header: FrameStreamHeader, frames: [FrameRecord],
                              mySeatWind: Wind, roundWind: Wind,
                              config: TrackerConfig = TrackerConfig()) -> ReplayResult {
        let tracker = TableTracker(config: config)
        tracker.beginSession(mySeatWind: mySeatWind, roundWind: roundWind, at: frames.first?.t ?? 0)
        for record in frames {
            let region = record.region.flatMap(MotionRegion.init(rawValue:))
            let motion = MotionSample(t: record.t, level: record.motion, dominantRegion: region)
            tracker.ingest(record.tiles, at: record.t, motion: motion)
        }
        return ReplayResult(header: header, frameCount: frames.count, events: tracker.events,
                            finalState: tracker.state, pendingHandEnd: tracker.pendingHandEnd,
                            diagnostics: tracker.diagnostics)
    }

    /// Convenience: reads `url` with `FrameStream.read`, then replays it.
    public static func replay(contentsOf url: URL, mySeatWind: Wind, roundWind: Wind,
                              config: TrackerConfig = TrackerConfig()) throws -> ReplayResult {
        let (header, frames) = try FrameStream.read(contentsOf: url)
        return replay(header: header, frames: frames, mySeatWind: mySeatWind, roundWind: roundWind, config: config)
    }
}

/// Everything one replay run produced — the CLI prints/writes it, the golden
/// test asserts bounds on it.
public struct ReplayResult: Sendable {
    public var header: FrameStreamHeader
    public var frameCount: Int
    public var events: [GameEvent]
    public var finalState: TrackedTableState
    public var pendingHandEnd: HandEndProposal?
    public var diagnostics: TrackerDiagnostics

    public init(header: FrameStreamHeader, frameCount: Int, events: [GameEvent],
               finalState: TrackedTableState, pendingHandEnd: HandEndProposal?,
               diagnostics: TrackerDiagnostics) {
        self.header = header
        self.frameCount = frameCount
        self.events = events
        self.finalState = finalState
        self.pendingHandEnd = pendingHandEnd
        self.diagnostics = diagnostics
    }

    /// Count of `handEndProposed` events emitted this run — the negative-
    /// control test's headline number.
    public var handEndProposedCount: Int {
        events.reduce(0) { count, event in
            if case .handEndProposed = event.kind { return count + 1 }
            return count
        }
    }
}
