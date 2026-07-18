import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import AVFoundation
import HarnessKit
import Recognition

/// Offline video harness: decodes a recorded clip with `AVAssetReader`,
/// decimates to a requested sample rate on the PTS grid, and runs the
/// production `VisionRecognizer` — the same detector the app uses — on each
/// kept frame, writing `<video>.frames.jsonl` beside the input.
///
/// Usage (from the repo root):
///   swift run --package-path Tools/detect-dump video-dump \
///       [--model App/Sources/Resources/Models/MahjongTileDetector.mlpackage] \
///       [--fps 10] [--threshold 0.30] [--start <s> --duration <s>] \
///       <video> [<video> ...]
@main
struct VideoDump {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var modelPath = "App/Sources/Resources/Models/MahjongTileDetector.mlpackage"
        var fps = 10.0
        var threshold = 0.30
        var start: Double?
        var duration: Double?
        var videos: [String] = []
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--model": modelPath = args.removeFirst()
            case "--fps": fps = Double(args.removeFirst()) ?? fps
            case "--threshold": threshold = Double(args.removeFirst()) ?? threshold
            case "--start": start = Double(args.removeFirst())
            case "--duration": duration = Double(args.removeFirst())
            default: videos.append(arg)
            }
        }
        guard !videos.isEmpty else {
            fputs("""
            usage: video-dump [--model <mlpackage>] [--fps 10] [--threshold 0.30] \
            [--start <s> --duration <s>] <video>...\n
            """, stderr)
            exit(2)
        }
        guard fps > 0 else {
            fputs("error: --fps must be > 0\n", stderr)
            exit(2)
        }

        let recognizer = try await HarnessModel.loadRecognizer(modelPath: modelPath, threshold: threshold)
        let modelName = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent

        for path in videos {
            do {
                try await dump(videoPath: path, recognizer: recognizer, modelName: modelName,
                                threshold: threshold, fps: fps, start: start, duration: duration)
            } catch {
                fputs("error dumping \(path): \(error)\n", stderr)
            }
        }
    }

    // MARK: - Per-video pipeline

    static func dump(videoPath: String, recognizer: VisionRecognizer, modelName: String,
                     threshold: Double, fps: Double, start: Double?, duration: Double?) async throws {
        let url = URL(fileURLWithPath: videoPath)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            fputs("skip (no video track): \(videoPath)\n", stderr)
            return
        }

        let transform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let assetDuration = try await asset.load(.duration)

        let orientation = CGImagePropertyOrientation(videoTransform: transform)
        let orientedSize = orientation.isSideways
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(trackOutput) else {
            throw VideoDumpError.cannotAddOutput(videoPath)
        }
        reader.add(trackOutput)

        let startOffset = start ?? 0
        if start != nil || duration != nil {
            let startTime = CMTime(seconds: startOffset, preferredTimescale: 600)
            let requestedDuration = duration.map { CMTime(seconds: $0, preferredTimescale: 600) }
                ?? (assetDuration - startTime)
            reader.timeRange = CMTimeRange(start: startTime, duration: requestedDuration)
        }

        guard reader.startReading() else {
            throw VideoDumpError.readerFailed(videoPath, reader.error)
        }

        let base = url.deletingPathExtension().lastPathComponent
        let outURL = url.deletingLastPathComponent().appendingPathComponent("\(base).frames.jsonl")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outURL.path) else {
            throw VideoDumpError.cannotOpenOutput(outURL.path)
        }
        defer { try? handle.close() }

        let header = FrameStreamHeader(
            video: url.lastPathComponent,
            width: Int(orientedSize.width), height: Int(orientedSize.height),
            sourceFPS: Double(nominalFrameRate), sampledFPS: fps,
            model: modelName, threshold: threshold)
        try handle.write(contentsOf: FrameStream.line(header))

        print("[\(url.lastPathComponent)] \(Int(orientedSize.width))x\(Int(orientedSize.height)) " +
              "source ~\(String(format: "%.2f", nominalFrameRate))fps, orientation=\(orientation) " +
              "→ sampling at \(fps)fps")

        let motionEstimator = SimpleMotionEstimator()
        let step = 1.0 / fps
        var nextGrid = 0.0
        var keptCount = 0
        var totalTiles = 0
        let progressEvery = 20
        let started = ContinuousClock.now

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid, !pts.isIndefinite else { continue }
            let t = pts.seconds - startOffset
            guard t >= nextGrid else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            let motion = motionEstimator.sample(pixelBuffer)
            let result = try await recognizer.recognize(.buffer(pixelBuffer, orientation: orientation))
            let record = FrameRecord(t: t, motion: motion, tiles: result.tiles)
            try handle.write(contentsOf: FrameStream.line(record))

            keptCount += 1
            totalTiles += result.tiles.count
            nextGrid += step
            while nextGrid <= t { nextGrid += step }

            if keptCount % progressEvery == 0 {
                print("  [\(url.lastPathComponent)] frame \(keptCount)  t=\(String(format: "%.1f", t))s  " +
                      "tiles=\(result.tiles.count)  motion=\(String(format: "%.3f", motion))")
                fflush(stdout)
            }
        }

        if reader.status == .failed {
            throw VideoDumpError.readerFailed(videoPath, reader.error)
        }

        let elapsed = ContinuousClock.now - started
        let meanTiles = keptCount > 0 ? Double(totalTiles) / Double(keptCount) : 0
        print("[\(url.lastPathComponent)] kept \(keptCount) frames, \(totalTiles) total detections " +
              "(mean \(String(format: "%.1f", meanTiles))/frame) in \(elapsed) → \(outURL.lastPathComponent)")
    }
}

enum VideoDumpError: Error, CustomStringConvertible {
    case cannotAddOutput(String)
    case cannotOpenOutput(String)
    case readerFailed(String, Error?)

    var description: String {
        switch self {
        case let .cannotAddOutput(path): return "could not add track output for \(path)"
        case let .cannotOpenOutput(path): return "could not open output file \(path)"
        case let .readerFailed(path, error):
            return "AVAssetReader failed for \(path): \(error?.localizedDescription ?? "unknown error")"
        }
    }
}
