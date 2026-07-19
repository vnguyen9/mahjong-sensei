import XCTest
import MahjongCore
import Recognition
@testable import HarnessKit

/// `FrameStream` is the wire format between `video-dump` (producer) and
/// `track-replay`/`HarnessKitTests`'s golden test (consumers) — a round-trip
/// break here would silently corrupt every downstream replay, so it gets
/// its own direct coverage independent of any real fixture.
final class FrameStreamTests: XCTestCase {
    func testHeaderEncodeDecodeRoundTrip() throws {
        let header = FrameStreamHeader(video: "clip.mov", width: 1080, height: 1920,
                                       sourceFPS: 29.97, sampledFPS: 10,
                                       model: "MahjongTileDetectorNanoV3", threshold: 0.3)
        let line = try FrameStream.line(header)
        XCTAssertTrue(line.last == 0x0A, "each line must be newline-terminated")

        let decoded = try FrameStream.makeDecoder().decode(FrameStreamHeader.self, from: line)
        XCTAssertEqual(decoded, header)
    }

    func testFrameEncodeDecodeRoundTrip() throws {
        let tile = DetectedTile(tile: .m(3), confidence: 0.82,
                                box: TileBoundingBox(x: 0.1, y: 0.2, width: 0.05, height: 0.08))
        let record = FrameRecord(t: 1.5, motion: 0.02, region: "left", tiles: [tile])

        let line = try FrameStream.line(record)
        let decoded = try FrameStream.makeDecoder().decode(FrameRecord.self, from: line)

        XCTAssertEqual(decoded.kind, "frame")
        XCTAssertEqual(decoded.t, record.t)
        XCTAssertEqual(decoded.motion, record.motion)
        XCTAssertEqual(decoded.region, record.region)
        XCTAssertEqual(decoded.tiles.map(\.tile), record.tiles.map(\.tile))
        XCTAssertEqual(decoded.tiles.map(\.confidence), record.tiles.map(\.confidence))
        XCTAssertEqual(decoded.tiles.map(\.box), record.tiles.map(\.box))
    }

    func testFrameRegionDefaultsToNil() throws {
        let record = FrameRecord(t: 0, motion: 0, tiles: [])
        let line = try FrameStream.line(record)
        let decoded = try FrameStream.makeDecoder().decode(FrameRecord.self, from: line)
        XCTAssertNil(decoded.region)
    }

    /// The full producer/consumer path: write a header + N frames to a real
    /// temp file exactly the way `video-dump` does, then read it back with
    /// `FrameStream.read(contentsOf:)` exactly the way `track-replay` does.
    func testFileRoundTrip() throws {
        let header = FrameStreamHeader(video: "clip.mov", width: 100, height: 200,
                                       sourceFPS: 30, sampledFPS: 10, model: "Mock", threshold: 0.3)
        let frames = (0..<5).map { i -> FrameRecord in
            let tile = DetectedTile(tile: .p(i + 1), confidence: 0.9,
                                    box: TileBoundingBox(x: 0, y: 0, width: 0.05, height: 0.05))
            return FrameRecord(t: Double(i) * 0.1, motion: 0.01 * Double(i),
                               region: i.isMultiple(of: 2) ? nil : "right", tiles: [tile])
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-stream-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = try FrameStream.line(header)
        for frame in frames { data += try FrameStream.line(frame) }
        try data.write(to: url)

        let (readHeader, readFrames) = try FrameStream.read(contentsOf: url)
        XCTAssertEqual(readHeader, header)
        XCTAssertEqual(readFrames, frames)
    }

    func testReadMissingHeaderThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-stream-no-header-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = FrameRecord(t: 0, motion: 0, tiles: [])
        try (try FrameStream.line(frame)).write(to: url)

        XCTAssertThrowsError(try FrameStream.read(contentsOf: url)) { error in
            guard case .some(.missingHeader) = error as? FrameStreamError else {
                XCTFail("expected FrameStreamError.missingHeader, got \(error)")
                return
            }
        }
    }
}
