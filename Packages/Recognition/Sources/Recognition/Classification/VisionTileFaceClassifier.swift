import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO

public struct TileClassifierCalibration: Sendable, Hashable, Codable {
    public var minimumConfidence: Float
    public var minimumMargin: Float
    public var minimumValidity: Float
    public var temperature: Float

    public init(minimumConfidence: Float = 0.80,
                minimumMargin: Float = 0.15,
                minimumValidity: Float = 0.75,
                temperature: Float = 1) {
        self.minimumConfidence = minimumConfidence
        self.minimumMargin = minimumMargin
        self.minimumValidity = minimumValidity
        self.temperature = max(0.01, temperature)
    }
}

public enum TileFaceClassifierError: Error, Sendable {
    case invalidInputImage
    case missingOutput(String)
    case unexpectedFaceCount(Int)
}

/// Dedicated 192×192 two-head Core ML classifier. The model produces a
/// 43-value `faceProbabilities` tensor plus `validProbability`; confidence,
/// margin, and validity gates derive unknown/rejected without inventing an
/// additional face class.
public actor VisionTileFaceClassifier: BatchTileClassifying {
    public static let modelName = "MahjongTileFaceClassifierV1"
    public static let inputName = "image"
    public static let faceOutputName = "faceProbabilities"
    public static let validityOutputName = "validProbability"
    public static let inputSize = 192
    public static let batchSize = 16

    private let model: MLModel
    private let calibration: TileClassifierCalibration
    private let context = CIContext(options: [.cacheIntermediates: true])

    public init(model: MLModel, calibration: TileClassifierCalibration = .init()) {
        self.model = model
        self.calibration = calibration
    }

    public init(bundledModelNamed name: String = modelName,
                in bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw RecognizerError.modelNotFound(name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)
        if let calibrationURL = bundle.url(forResource: "TileClassifierCalibration", withExtension: "json"),
           let data = try? Data(contentsOf: calibrationURL),
           let decoded = try? JSONDecoder().decode(TileClassifierCalibration.self, from: data) {
            calibration = decoded
        } else {
            calibration = .init()
        }
    }

    public func classify(_ crops: [TileCrop]) async throws -> [TileFaceHypothesis] {
        guard !crops.isEmpty else { return [] }
        var results: [TileFaceHypothesis] = []
        results.reserveCapacity(crops.count)
        for start in stride(from: 0, to: crops.count, by: Self.batchSize) {
            let end = min(crops.count, start + Self.batchSize)
            let chunk = Array(crops[start..<end])
            results.append(contentsOf: try classifyChunk(chunk))
        }
        return results
    }

    private func classifyChunk(_ crops: [TileCrop]) throws -> [TileFaceHypothesis] {
        var providers: [any MLFeatureProvider] = []
        var validIndices: [Int] = []
        providers.reserveCapacity(crops.count)
        validIndices.reserveCapacity(crops.count)
        var results = [TileFaceHypothesis](
            repeating: .rejected(.invalidCrop),
            count: crops.count
        )
        for (index, crop) in crops.enumerated() {
            guard let buffer = resizedBuffer(for: crop.frame) else {
                continue
            }
            providers.append(try MLDictionaryFeatureProvider(dictionary: [
                Self.inputName: MLFeatureValue(pixelBuffer: buffer)
            ]))
            validIndices.append(index)
        }
        guard !providers.isEmpty else { return results }
        let batch = MLArrayBatchProvider(array: providers)
        let outputs = try model.predictions(fromBatch: batch)
        guard outputs.count == validIndices.count else {
            throw TileFaceClassifierError.unexpectedFaceCount(outputs.count)
        }
        for outputIndex in 0..<outputs.count {
            let cropIndex = validIndices[outputIndex]
            results[cropIndex] = decode(outputs.features(at: outputIndex),
                                        crop: crops[cropIndex])
        }
        return results
    }

    private func decode(_ output: any MLFeatureProvider,
                        crop: TileCrop) -> TileFaceHypothesis {
        let size = crop.frame.orientedPixelSize
        let cropWidth = Int(size.width.rounded())
        let cropHeight = Int(size.height.rounded())
        guard let array = output.featureValue(for: Self.faceOutputName)?.multiArrayValue,
              array.count == HKDetectorLabels.ordered.count else {
            return .rejected(.noModelOutput, diagnostics: .init(
                cropPixelWidth: cropWidth,
                cropPixelHeight: cropHeight
            ))
        }

        var raw = (0..<array.count).map { Float(truncating: array[$0]) }
        let sum = raw.reduce(0, +)
        if raw.contains(where: { $0 < 0 }) || abs(sum - 1) > 0.02 {
            raw = Self.softmax(raw, temperature: calibration.temperature)
        }
        let ranked = raw.indices.sorted {
            if raw[$0] != raw[$1] { return raw[$0] > raw[$1] }
            return $0 < $1
        }
        guard let best = ranked.first,
              let face = TileFace(detectorLabel: HKDetectorLabels.ordered[best]) else {
            return .rejected(.noModelOutput, diagnostics: .init(
                cropPixelWidth: cropWidth,
                cropPixelHeight: cropHeight
            ))
        }
        let confidence = raw[best]
        let runnerUp = ranked.dropFirst().first.map { raw[$0] } ?? 0
        let margin = confidence - runnerUp
        let validity = Self.scalar(
            output.featureValue(for: Self.validityOutputName)
        ) ?? 0
        let accepted = validity >= calibration.minimumValidity
            && confidence >= calibration.minimumConfidence
            && margin >= calibration.minimumMargin
        let rejectionReason: TileFaceRejectionReason?
        if accepted {
            rejectionReason = nil
        } else if validity < calibration.minimumValidity {
            rejectionReason = .invalidCrop
        } else if confidence < calibration.minimumConfidence {
            rejectionReason = .belowAutoConfirmThreshold
        } else {
            rejectionReason = .lowMargin
        }

        var probabilities: [TileFace: Float] = [:]
        for index in raw.indices {
            if let candidate = TileFace(detectorLabel: HKDetectorLabels.ordered[index]) {
                probabilities[candidate] = raw[index]
            }
        }
        return TileFaceHypothesis(
            probabilities: probabilities,
            topFace: accepted ? face : nil,
            confidence: confidence,
            margin: margin,
            rejectionScore: 1 - validity,
            rejectionReason: rejectionReason,
            diagnostics: TileFaceDiagnosticMetadata(
                rawTopCandidates: ranked.prefix(5).compactMap { index in
                    guard let candidate = TileFace(
                        detectorLabel: HKDetectorLabels.ordered[index]
                    ) else { return nil }
                    return TileFaceCandidate(face: candidate,
                                             confidence: raw[index])
                },
                cropPixelWidth: cropWidth,
                cropPixelHeight: cropHeight,
                validity: validity
            )
        )
    }

    private func resizedBuffer(for frame: RecognizerFrame) -> CVPixelBuffer? {
        let image: CIImage
        switch frame {
        case let .cgImage(cgImage, orientation):
            image = CIImage(cgImage: cgImage).oriented(orientation)
        case let .pixelBuffer(buffer, orientation):
            image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = CGFloat(Self.inputSize) / max(extent.width, extent.height)
        let resized = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let outputExtent = resized.extent
        let x = (outputExtent.width - CGFloat(Self.inputSize)) / 2
        let y = (outputExtent.height - CGFloat(Self.inputSize)) / 2
        let square = resized.cropped(to: CGRect(x: x, y: y,
                                                width: CGFloat(Self.inputSize),
                                                height: CGFloat(Self.inputSize)))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))

        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Self.inputSize, Self.inputSize,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                  &output) == kCVReturnSuccess,
              let output else { return nil }
        context.render(square, to: output, bounds: CGRect(x: 0, y: 0,
                                                          width: Self.inputSize,
                                                          height: Self.inputSize),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    private static func scalar(_ value: MLFeatureValue?) -> Float? {
        if let array = value?.multiArrayValue, array.count > 0 {
            return Float(truncating: array[0])
        }
        if value?.type == .double { return Float(value?.doubleValue ?? 0) }
        if value?.type == .int64 { return Float(value?.int64Value ?? 0) }
        return nil
    }

    private static func softmax(_ values: [Float], temperature: Float) -> [Float] {
        guard let maximum = values.max() else { return [] }
        let exponentials = values.map { exp(($0 - maximum) / temperature) }
        let denominator = max(Float.leastNonzeroMagnitude, exponentials.reduce(0, +))
        return exponentials.map { $0 / denominator }
    }
}
