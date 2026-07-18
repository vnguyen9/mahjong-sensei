import Foundation
import CoreGraphics
import CoreML
import ImageIO
import MahjongCore
import Recognition

/// Offline fixture harness: runs the production ``VisionRecognizer`` — same
/// decode, letterbox inversion, and overlap suppression as the app — on still
/// photos, and writes `<photo>.boxes.json` beside each one. Those JSONs are the
/// zoner's unit-test fixtures.
///
/// Usage (from the repo root):
///   swift run --package-path Tools/detect-dump detect-dump \
///       [--model App/Sources/Resources/Models/MahjongTileDetector.mlpackage] \
///       [--threshold 0.30] <photo> [<photo> ...]
@main
struct DetectDump {
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
        var threshold = 0.30
        var photos: [String] = []
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--model": modelPath = args.removeFirst()
            case "--threshold": threshold = Double(args.removeFirst()) ?? threshold
            default: photos.append(arg)
            }
        }
        guard !photos.isEmpty else {
            fputs("usage: detect-dump [--model <mlpackage>] [--threshold 0.30] <photo>...\n", stderr)
            exit(2)
        }

        let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
        let configuration = MLModelConfiguration()
        // Override with MJ_COMPUTE=cpu|cpuGPU|all — the Mac GPU/ANE graph compiler
        // can choke on large graphs where a device wouldn't; cpu isolates that.
        switch ProcessInfo.processInfo.environment["MJ_COMPUTE"] {
        case "cpu": configuration.computeUnits = .cpuOnly
        case "cpuGPU": configuration.computeUnits = .cpuAndGPU
        case "ane": configuration.computeUnits = .cpuAndNeuralEngine   // device parity
        default: configuration.computeUnits = .all
        }
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let recognizer = try VisionRecognizer(model: model, confidenceThreshold: threshold)

        for path in photos {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                fputs("skip (unreadable): \(path)\n", stderr)
                continue
            }
            // iPhone HEIC/JPG stills carry EXIF orientation — honor it so the
            // normalized boxes land in oriented (as-viewed) coordinates.
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
                .flatMap(CGImagePropertyOrientation.init) ?? .up

            let frame = RecognizerFrame.image(image, orientation: orientation)
            let result = try await recognizer.recognize(frame)
            let size = frame.orientedPixelSize

            let dump = DetectionDump(image: url.lastPathComponent,
                                     imageWidth: Int(size.width), imageHeight: Int(size.height),
                                     threshold: threshold, tiles: result.tiles)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let out = url.deletingPathExtension().appendingPathExtension("boxes.json")
            try encoder.encode(dump).write(to: out)

            print("\(url.lastPathComponent): \(result.tiles.count) tiles → \(out.lastPathComponent)")
            for row in result.rows {
                let faces = row.map { "\($0.tile.code)@\(String(format: "%.2f", $0.confidence))" }
                print("  row: \(faces.joined(separator: " "))")
            }
        }
    }
}

/// The fixture payload — `RecognitionTests` decodes the same shape.
struct DetectionDump: Codable {
    var image: String
    var imageWidth: Int
    var imageHeight: Int
    var threshold: Double
    var tiles: [DetectedTile]
}
