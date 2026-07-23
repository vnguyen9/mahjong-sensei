import CoreGraphics
import CoreML
import Foundation
import Recognition

protocol TrackerDirectDetecting: Sendable {
    func prepare() async throws
    func detect(_ image: CGImage) async throws -> TrackerDirectDetectionResult
}

struct TrackerDirectDetectorTimings: Sendable, Hashable {
    var letterboxRendering: TimeInterval
    var inference: TimeInterval
    var tensorDecode: TimeInterval
    var nms: TimeInterval
}

struct TrackerDirectDetectionResult: @unchecked Sendable {
    var detections: [TrackerDirectDetection]
    var descriptor: TrackerDetectorDescriptor
    var letterbox: UltralyticsLetterboxGeometry
    var detectorInputImage: CGImage
    var rawTensorRowCount: Int
    var positiveCandidateCount: Int
    var validBoxCount: Int
    var unmappedLabelCount: Int
    var timings: TrackerDirectDetectorTimings
}

enum TrackerDirectDetectorError: Error, LocalizedError {
    case modelNotFound(String)
    case imageInputNotFound
    case tensorOutputNotFound
    case invalidTensorShape([Int])
    case warmupImageCreationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name): return "The bundled \(name) model is unavailable."
        case .imageInputNotFound: return "The Pro detector has no image input."
        case .tensorOutputNotFound: return "The Pro detector returned no detection tensor."
        case .invalidTensorShape(let shape):
            return "The Pro detector returned an unsupported tensor shape: \(shape)."
        case .warmupImageCreationFailed: return "The Pro detector could not be prepared."
        }
    }
}

/// Tracker's sole recognition model. It owns preprocessing and calls Core ML
/// directly; Vision never gets an opportunity to rescale or repad the still.
actor TrackerDirectDetector: TrackerDirectDetecting {
    static let resourceName = "MahjongTileDetectorProV3"
    static let nmsIoUThreshold = 0.55

    private var model: MLModel?
    private var descriptor: TrackerDetectorDescriptor?

    func prepare() async throws {
        guard model == nil else { return }
        guard let url = Bundle.main.url(forResource: Self.resourceName,
                                        withExtension: "mlmodelc") else {
            throw TrackerDirectDetectorError.modelNotFound(Self.resourceName)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        let resolvedDescriptor = try Self.makeDescriptor(for: loaded)
        model = loaded
        descriptor = resolvedDescriptor

        // Force graph compilation/model placement before the shutter is enabled.
        guard let image = Self.warmupImage() else {
            model = nil
            descriptor = nil
            throw TrackerDirectDetectorError.warmupImageCreationFailed
        }
        let rendered = try UltralyticsLetterboxRenderer.render(image)
        _ = try Self.predict(model: loaded, descriptor: resolvedDescriptor,
                             pixelBuffer: rendered.pixelBuffer)
    }

    func detect(_ image: CGImage) async throws -> TrackerDirectDetectionResult {
        if model == nil { try await prepare() }
        guard let model, let descriptor else {
            throw TrackerDirectDetectorError.modelNotFound(Self.resourceName)
        }

        let letterboxStart = ContinuousClock.now
        let rendered = try UltralyticsLetterboxRenderer.render(image)
        let letterboxDuration = letterboxStart.duration(to: .now).timeInterval

        let inferenceStart = ContinuousClock.now
        let tensor = try Self.predict(model: model, descriptor: descriptor,
                                      pixelBuffer: rendered.pixelBuffer)
        let inferenceDuration = inferenceStart.duration(to: .now).timeInterval

        let decodeStart = ContinuousClock.now
        let decoded = try Self.decode(tensor, geometry: rendered.geometry)
        let decodeDuration = decodeStart.duration(to: .now).timeInterval

        let nmsStart = ContinuousClock.now
        let detections = Self.suppressingOverlaps(
            decoded.detections,
            iouThreshold: Self.nmsIoUThreshold
        )
        let nmsDuration = nmsStart.duration(to: .now).timeInterval

        return TrackerDirectDetectionResult(
            detections: detections,
            descriptor: descriptor,
            letterbox: rendered.geometry,
            detectorInputImage: rendered.image,
            rawTensorRowCount: decoded.rawRowCount,
            positiveCandidateCount: decoded.positiveCandidateCount,
            validBoxCount: decoded.detections.count,
            unmappedLabelCount: decoded.unmappedLabelCount,
            timings: TrackerDirectDetectorTimings(
                letterboxRendering: letterboxDuration,
                inference: inferenceDuration,
                tensorDecode: decodeDuration,
                nms: nmsDuration
            )
        )
    }

    struct DecodedTensor {
        var detections: [TrackerDirectDetection]
        var rawRowCount: Int
        var positiveCandidateCount: Int
        var unmappedLabelCount: Int
    }

    static func decode(_ tensor: MLMultiArray,
                       geometry: UltralyticsLetterboxGeometry) throws -> DecodedTensor {
        let shape = tensor.shape.map(\.intValue)
        guard shape == [1, 300, 6] else {
            throw TrackerDirectDetectorError.invalidTensorShape(shape)
        }
        let rows = shape[1]
        let rowStride = tensor.strides[1].intValue
        let columnStride = tensor.strides[2].intValue
        var detections: [TrackerDirectDetection] = []
        var positive = 0
        var unmapped = 0

        for rowIndex in 0..<rows {
            let row = rowIndex * rowStride
            func value(_ column: Int) -> Double {
                tensor[row + column * columnStride].doubleValue
            }
            let confidence = value(4)
            guard confidence.isFinite, confidence > 0 else { continue }
            positive += 1
            let coordinates = [value(0), value(1), value(2), value(3)]
            guard coordinates.allSatisfy(\.isFinite) else { continue }
            let classValue = value(5)
            guard classValue.isFinite else { continue }
            let classIndex = Int(classValue.rounded())
            guard HKDetectorLabels.ordered.indices.contains(classIndex) else {
                unmapped += 1
                continue
            }
            let label = HKDetectorLabels.ordered[classIndex]
            let box = geometry.normalizedCanonicalBox(
                x1: coordinates[0], y1: coordinates[1],
                x2: coordinates[2], y2: coordinates[3]
            )
            guard box.width > 0, box.height > 0 else { continue }
            let face = TileFace(detectorLabel: label)
            if face == nil { unmapped += 1 }
            detections.append(TrackerDirectDetection(
                label: label, face: face, confidence: confidence, box: box
            ))
        }
        return DecodedTensor(detections: detections, rawRowCount: rows,
                             positiveCandidateCount: positive,
                             unmappedLabelCount: unmapped)
    }

    static func suppressingOverlaps(_ detections: [TrackerDirectDetection],
                                    iouThreshold: Double = 0.55)
        -> [TrackerDirectDetection] {
        let ranked = detections.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.box.y != $1.box.y { return $0.box.y < $1.box.y }
            if $0.box.x != $1.box.x { return $0.box.x < $1.box.x }
            return $0.label < $1.label
        }
        var kept: [TrackerDirectDetection] = []
        for detection in ranked where kept.allSatisfy({
            Self.iou($0.box, detection.box) <= iouThreshold
        }) {
            kept.append(detection)
        }
        return kept
    }

    private static func iou(_ first: TileBoundingBox,
                            _ second: TileBoundingBox) -> Double {
        let width = max(0, min(first.x + first.width, second.x + second.width)
                        - max(first.x, second.x))
        let height = max(0, min(first.y + first.height, second.y + second.height)
                         - max(first.y, second.y))
        let intersection = width * height
        let union = first.width * first.height + second.width * second.height - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func makeDescriptor(for model: MLModel) throws
        -> TrackerDetectorDescriptor {
        guard let input = model.modelDescription.inputDescriptionsByName.first(where: {
            $0.value.type == .image
        }) else {
            throw TrackerDirectDetectorError.imageInputNotFound
        }
        guard let output = model.modelDescription.outputDescriptionsByName.first(where: {
            $0.value.type == .multiArray
        }) else {
            throw TrackerDirectDetectorError.tensorOutputNotFound
        }
        let metadata = model.modelDescription.metadata
        let creator = metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        let embeddedName = creator["model_name"]
            ?? creator["name"]
            ?? creator["model"]
            ?? "mjss-l-v3"
        let version = creator["version"]
            ?? creator["ultralytics_version"]
            ?? (metadata[.versionString] as? String)
            ?? "Unknown"
        return TrackerDetectorDescriptor(
            resourceName: resourceName,
            embeddedName: embeddedName,
            embeddedVersion: version,
            inputName: input.key,
            outputName: output.key
        )
    }

    private static func predict(model: MLModel, descriptor: TrackerDetectorDescriptor,
                                pixelBuffer: CVPixelBuffer) throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            descriptor.inputName: MLFeatureValue(pixelBuffer: pixelBuffer),
        ])
        let prediction = try model.prediction(from: provider)
        guard let tensor = prediction.featureValue(
            for: descriptor.outputName
        )?.multiArrayValue else {
            throw TrackerDirectDetectorError.tensorOutputNotFound
        }
        return tensor
    }

    private static func warmupImage() -> CGImage? {
        guard let context = CGContext(
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let gray = CGFloat(UltralyticsLetterboxRenderer.paddingValue) / 255
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let value = components
        return TimeInterval(value.seconds)
            + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}
