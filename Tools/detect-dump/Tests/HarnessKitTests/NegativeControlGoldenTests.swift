import XCTest
import MahjongCore
import Recognition
import HarnessKit

/// Negative-control golden, scoped to this harness slice (tracker plan
/// §6.2's regression-fixture idea, applied to a clip that isn't gameplay):
/// `Planning/Mahjong Tables/Videos/IMG_6249.frames.jsonl` is footage of the
/// table being *set up* — tiles being built into the wall, not a hand being
/// played — so the one hard assertion this test can make is behavioral, not
/// an exact golden: a tracker tuned against real video should never mistake
/// wall-building for a hand ending.
///
/// The event *count* is a softer signal. Tiles briefly resting in pond-ish
/// positions between motion bursts while the wall is built can read as
/// spurious discards (a known, documented tracker limitation — see the
/// tracker plan §8's mitigation table); that's a tuning problem for
/// `TrackerConfig`, not something this harness slice owns or should fail a
/// build over. So the event count is asserted as a frozen *ceiling*
/// (`eventCountCeiling`) rather than an exact number — see that constant's
/// own doc.
final class NegativeControlGoldenTests: XCTestCase {
    /// Regression ceiling for `IMG_6249.frames.jsonl`'s total event count,
    /// measured against the tracker at the time this test was written
    /// (`TrackerConfig()` defaults, seat/round both East):
    /// `swift run --package-path Tools/detect-dump track-replay
    /// "Planning/Mahjong Tables/Videos/IMG_6249.frames.jsonl"` produced
    /// exactly 4 events — 1 `handStarted` plus 3 phantom `discard`s (`GD`,
    /// `7s`, `1s`, all around t=8.5–8.6s, confidences 0.67–0.80, seats
    /// across/left/me) from tiles the wall-building motion briefly left in
    /// pond-ish positions between bursts. Frozen high-water mark: fewer
    /// events after a future retune is fine (and expected — see the type
    /// doc), more means some new mechanism is now firing phantom events on
    /// non-gameplay footage and this test should catch it rather than
    /// silently pass.
    static let eventCountCeiling = 4

    func testIMG6249IsWallBuildingNotGameplay() throws {
        let url = try Self.resolveFixtureURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture not present: \(url.path)")
        }

        let result = try TrackReplay.replay(contentsOf: url, mySeatWind: .east, roundWind: .east)

        // The hard bound: wall-building must never look like a hand ending.
        XCTAssertNil(result.pendingHandEnd,
                     "IMG_6249 is wall-building/setup footage — no hand-end proposal should survive to the end of the clip")
        XCTAssertEqual(result.handEndProposedCount, 0,
                       "no handEndProposed event should fire on non-gameplay footage")

        // The soft bound: a frozen regression ceiling, not a golden count —
        // see the type doc and `eventCountCeiling`'s own doc.
        XCTAssertLessThanOrEqual(result.events.count, Self.eventCountCeiling,
                                 "event count regression ceiling exceeded (\(result.events.count) > " +
                                 "\(Self.eventCountCeiling)) — see eventCountCeiling's doc")

        // Not an assertion — surfaced so a human reading `swift test` output
        // (or CI logs) sees the measured number and a few sample lines
        // without having to re-run the CLI by hand.
        print("[NegativeControlGoldenTests] IMG_6249: \(result.frameCount) frames → " +
              "\(result.events.count) events (ceiling \(Self.eventCountCeiling)), " +
              "0 hand-end proposals, pendingHandEnd=\(String(describing: result.pendingHandEnd))")
        for event in result.events.prefix(10) {
            print("[NegativeControlGoldenTests]   \(String(format: "%.1f", event.at))s  \(event.kind)")
        }
    }

    /// `Planning/Mahjong Tables/Videos/IMG_6249.frames.jsonl`, resolved
    /// relative to this file's own location (`#filePath`) rather than the
    /// process's current working directory — `swift test` can be invoked
    /// from anywhere, `#filePath` can't.
    private static func resolveFixtureURL() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../Tools/detect-dump/Tests/HarnessKitTests/NegativeControlGoldenTests.swift
        //   -> HarnessKitTests -> Tests -> detect-dump -> Tools -> repo root
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("Planning")
        url.appendPathComponent("Mahjong Tables")
        url.appendPathComponent("Videos")
        url.appendPathComponent("IMG_6249.frames.jsonl")
        return url
    }
}
