import Foundation
import Recognition

/// JSONL frame-stream schema written by `video-dump` and (eventually) consumed
/// by `track-replay` / `ReplayFixtureTests`. One JSON object per line: a single
/// `header` line, then one `frame` line per sampled frame. Versioned via
/// `schema` so future field additions stay additive and old files keep decoding.
public enum FrameStreamSchema {
    public static let mjFrames1 = "mj-frames/1"
}

/// First line of a `<video>.frames.jsonl` file.
public struct FrameStreamHeader: Codable, Sendable, Equatable {
    public var schema: String
    public var kind: String
    public var video: String
    public var width: Int
    public var height: Int
    public var sourceFPS: Double
    public var sampledFPS: Double
    public var model: String
    public var threshold: Double

    public init(video: String, width: Int, height: Int, sourceFPS: Double,
                sampledFPS: Double, model: String, threshold: Double) {
        self.schema = FrameStreamSchema.mjFrames1
        self.kind = "header"
        self.video = video
        self.width = width
        self.height = height
        self.sourceFPS = sourceFPS
        self.sampledFPS = sampledFPS
        self.model = model
        self.threshold = threshold
    }
}

/// One sampled frame.
///
/// `motion` is a relative frame-to-frame luma-change score, `0` for the first
/// sampled frame (no prior reference to diff against). `region` is the
/// dominant-motion quadrant; it is always `nil` for now — see
/// `SimpleMotionEstimator`'s doc comment — but is part of the schema already so
/// wiring in the real per-region computation later is a producer-only change.
public struct FrameRecord: Codable, Sendable, Equatable {
    public var kind: String
    public var t: Double
    public var motion: Double
    public var region: String?
    public var tiles: [DetectedTile]

    public init(t: Double, motion: Double, region: String? = nil, tiles: [DetectedTile]) {
        self.kind = "frame"
        self.t = t
        self.motion = motion
        self.region = region
        self.tiles = tiles
    }
}

/// Encodes/decodes the `.frames.jsonl` line format (compact, one record per line,
/// sorted keys for deterministic/diffable output).
public enum FrameStream {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    /// Encodes one record as a single compact, newline-terminated JSON line.
    public static func line<T: Encodable>(_ record: T, encoder: JSONEncoder = FrameStream.makeEncoder()) throws -> Data {
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    /// Reads a `.frames.jsonl` file into its header + ordered frame records.
    public static func read(contentsOf url: URL) throws -> (header: FrameStreamHeader, frames: [FrameRecord]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = FrameStream.makeDecoder()
        var header: FrameStreamHeader?
        var frames: [FrameRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            let kind = try decoder.decode(KindProbe.self, from: data).kind
            switch kind {
            case "header": header = try decoder.decode(FrameStreamHeader.self, from: data)
            case "frame": frames.append(try decoder.decode(FrameRecord.self, from: data))
            default: continue
            }
        }
        guard let header else { throw FrameStreamError.missingHeader }
        return (header, frames)
    }

    private struct KindProbe: Decodable { var kind: String }
}

public enum FrameStreamError: Error, Sendable { case missingHeader }
