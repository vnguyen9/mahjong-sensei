import Foundation
import CoreGraphics
import CoreVideo
import CoreML
@preconcurrency import Vision
import MahjongCore

/// Live tile detector: runs the bundled YOLO26 Core ML model through Vision on
/// the Neural Engine and maps detections into a ``RecognitionResult``.
///
/// The model is **end-to-end / NMS-free**, so its Core ML output is a raw
/// `[1, 300, 6]` tensor (rows of `[x1, y1, x2, y2, confidence, classIndex]` in the
/// model's 640-px LETTERBOXED input space). We invert the letterbox back to
/// oriented-image coordinates, drop duplicate boxes, and hand off ordered tiles.
///
/// Swapping in a bigger/better model is just replacing the bundled `.mlpackage`;
/// the 43-class label contract is fixed (see ``HKDetectorLabels``).
public struct VisionRecognizer: Recognizer {
    /// Conservative product-wide detector gate. Low-light wood grain and
    /// shadows frequently score in the former 0.30-0.49 band, so an editable
    /// unknown tile is preferable to a confident-looking false face.
    public static let defaultConfidenceThreshold = 0.50

    private let model: VNCoreMLModel
    /// Detections below this score are dropped.
    public var confidenceThreshold: Double

    /// Wrap an already-loaded `MLModel`.
    public init(
        model mlModel: MLModel,
        confidenceThreshold: Double = VisionRecognizer.defaultConfidenceThreshold
    ) throws {
        self.model = try VNCoreMLModel(for: mlModel)
        self.confidenceThreshold = confidenceThreshold
    }

    /// Load the bundled compiled detector (`<name>.mlmodelc`). Throws
    /// ``RecognizerError/modelNotFound(_:)`` when the resource is absent — callers
    /// use `try?` to fall back to ``MockRecognizer`` before the model is bundled.
    public init(bundledModelNamed name: String = "MahjongTileDetectorNanoV3",
                in bundle: Bundle = .main,
                confidenceThreshold: Double = VisionRecognizer.defaultConfidenceThreshold) throws {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw RecognizerError.modelNotFound(name)
        }
        let configuration = MLModelConfiguration()
        // ANE + CPU, deliberately NOT the GPU: the GPU's MPSGraph compiler aborts
        // on-device (`MLIR pass manager failed`) for these YOLO26 graphs, and a
        // conv detector gains nothing from the GPU path anyway. `.all` would let
        // Core ML pick the GPU and crash mid-inference.
        configuration.computeUnits = .cpuAndNeuralEngine
        let mlModel = try MLModel(contentsOf: url, configuration: configuration)
        try self.init(model: mlModel, confidenceThreshold: confidenceThreshold)
    }

    public func recognize(_ frame: RecognizerFrame) async throws -> RecognitionResult {
        let model = self.model
        let threshold = self.confidenceThreshold
        let geometry = LetterboxGeometry(orientedImageSize: frame.orientedPixelSize)
        return try await withCheckedThrowingContinuation { continuation in
            // Vision's `perform` is synchronous/blocking — keep it off the caller
            // (which is typically the main actor).
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNCoreMLRequest(model: model)
                    request.imageCropAndScaleOption = .scaleFit   // letterbox, matches training
                    try frame.makeHandler().perform([request])
                    let tiles = VisionRecognizer.decodeTiles(from: request.results,
                                                             threshold: threshold, geometry: geometry)
                    continuation.resume(returning: RecognitionResult(tiles: tiles))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Decoding the end-to-end tensor

    /// Pull the raw output tensor out of Vision's feature-value observation.
    static func decodeTiles(from results: [VNObservation]?, threshold: Double,
                            geometry: LetterboxGeometry) -> [DetectedTile] {
        guard let array = results?
            .lazy
            .compactMap({ ($0 as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue })
            .first else { return [] }
        return decodeTiles(from: array, threshold: threshold, geometry: geometry)
    }

    /// Decode the end-to-end (NMS-free) YOLO26 output. Each of the N rows is
    /// `[x1, y1, x2, y2, confidence, classIndex]` in the model's 640-px letterbox
    /// space; `geometry` inverts the letterbox to normalized oriented-image coords.
    /// Overlapping duplicates (two labels on one physical tile) are then suppressed.
    static func decodeTiles(from array: MLMultiArray, threshold: Double,
                            geometry: LetterboxGeometry) -> [DetectedTile] {
        guard array.shape.count == 3, array.shape[2].intValue >= 6 else { return [] }
        let rows = array.shape[1].intValue
        let rowStride = array.strides[1].intValue
        let colStride = array.strides[2].intValue

        var raw: [DetectedTile] = []
        array.withUnsafeBufferPointer(ofType: Float32.self) { buf in
            for i in 0..<rows {
                let row = i * rowStride
                let confidence = Double(buf[row + 4 * colStride])
                guard confidence >= threshold else { continue }
                let classIndex = Int(buf[row + 5 * colStride].rounded())
                guard classIndex >= 0, classIndex < HKDetectorLabels.ordered.count,
                      let tile = HKDetectorLabels.tile(for: HKDetectorLabels.ordered[classIndex])
                else { continue }   // unknown label or `back` → skip
                let box = geometry.normalizedBox(
                    x1: Double(buf[row + 0 * colStride]), y1: Double(buf[row + 1 * colStride]),
                    x2: Double(buf[row + 2 * colStride]), y2: Double(buf[row + 3 * colStride]))
                raw.append(DetectedTile(tile: tile, confidence: confidence, box: box))
            }
        }
        return suppressingOverlaps(raw)
    }

    // MARK: - Overlap suppression (class-agnostic)

    /// Intersection-over-union of two normalized boxes.
    static func iou(_ a: TileBoundingBox, _ b: TileBoundingBox) -> Double {
        let interW = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let interH = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let intersection = interW * interH
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }

    /// Greedy NMS: keep the highest-confidence box, drop any later box overlapping
    /// a kept one beyond `iouThreshold`. Class-agnostic — the failure mode is two
    /// *different* labels stacked on one tile, which the model's own NMS misses.
    static func suppressingOverlaps(_ tiles: [DetectedTile], iouThreshold: Double = 0.55) -> [DetectedTile] {
        let ranked = tiles.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.box.x < $1.box.x
        }
        var kept: [DetectedTile] = []
        for tile in ranked where kept.allSatisfy({ iou($0.box, tile.box) <= iouThreshold }) {
            kept.append(tile)
        }
        return kept
    }
}

/// Converts YOLO letterbox-space pixel boxes back to normalized oriented-image
/// coordinates. Ultralytics letterboxes centered, so padding is split evenly
/// (`anchor = 0.5`). If on-device QA shows Vision anchors the image top-left,
/// flip ``padAnchor`` to 0 — that's the only change needed.
struct LetterboxGeometry: Equatable {
    let scale: Double
    let padX: Double
    let padY: Double
    let imageW: Double
    let imageH: Double

    static let padAnchor = 0.5

    init(orientedImageSize size: CGSize, inputSize: Double = 640, anchor: Double = LetterboxGeometry.padAnchor) {
        let w = max(1, Double(size.width)), h = max(1, Double(size.height))
        let s = inputSize / max(w, h)
        scale = s
        padX = (inputSize - w * s) * anchor
        padY = (inputSize - h * s) * anchor
        imageW = w
        imageH = h
    }

    /// Map a letterbox-space box (pixels in the 640 input) to normalized [0,1]
    /// oriented-image coordinates, origin top-left.
    func normalizedBox(x1: Double, y1: Double, x2: Double, y2: Double) -> TileBoundingBox {
        TileBoundingBox(
            x: clamp01((min(x1, x2) - padX) / scale / imageW),
            y: clamp01((min(y1, y2) - padY) / scale / imageH),
            width: clamp01(abs(x2 - x1) / scale / imageW),
            height: clamp01(abs(y2 - y1) / scale / imageH)
        )
    }
}

private func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

extension RecognizerFrame {
    /// The pixel size of the image *after* its orientation is applied (w/h swap
    /// for the four 90°-rotating orientations). Used to invert the letterbox.
    public var orientedPixelSize: CGSize {
        let raw: CGSize
        let orientation: CGImagePropertyOrientation
        switch self {
        case let .cgImage(image, o):
            raw = CGSize(width: image.width, height: image.height); orientation = o
        case let .pixelBuffer(buffer, o):
            raw = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)); orientation = o
        }
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: raw.height, height: raw.width)
        default:
            return raw
        }
    }

    /// Build the Vision request handler for this frame (still image or pixel buffer).
    func makeHandler() -> VNImageRequestHandler {
        switch self {
        case let .cgImage(image, orientation):
            return VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        case let .pixelBuffer(buffer, orientation):
            return VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        }
    }
}

// MARK: - Raw box detection (retains `back`/unmapped boxes for the v2.5 locator)

/// One raw detector box: geometry + confidence + the model's own label
/// string, independent of whether that label maps to a playable ``Tile``.
/// The trusted Scan-Score path (``Recognizer/recognize(_:)``) intentionally
/// drops `back` (face-down) and unrecognized labels because
/// ``DetectedTile/tile`` is not optional; the v2.5 locator needs every
/// physical tile, face-down or not, so it reads this parallel, additive
/// decode path instead.
public struct RawTileDetection: Sendable, Hashable {
    public var label: String
    public var confidence: Double
    public var box: TileBoundingBox

    public init(label: String, confidence: Double, box: TileBoundingBox) {
        self.label = label
        self.confidence = confidence
        self.box = box
    }
}

/// Recognizers that can additionally expose every raw detector box, including
/// ones whose label has no ``Tile`` mapping (`back`). The v2.5 prototype
/// locator/classifier adapters look for this via `as?` and fall back to the
/// plain ``Recognizer/recognize(_:)`` path (which cannot see `back`) when a
/// wrapped recognizer doesn't implement it — e.g. ``MockRecognizer`` in tests.
public protocol RawBoxDetecting: Sendable {
    func detectRawBoxes(_ frame: RecognizerFrame) async throws -> [RawTileDetection]
}

extension VisionRecognizer: RawBoxDetecting {
    /// Same inference call as ``recognize(_:)``, decoded WITHOUT dropping
    /// boxes whose label has no ``Tile`` mapping (`back`). ``recognize(_:)``
    /// itself is untouched — this is a fully additive decode path sharing the
    /// same model, threshold, and letterbox geometry.
    public func detectRawBoxes(_ frame: RecognizerFrame) async throws -> [RawTileDetection] {
        let model = self.model
        let threshold = self.confidenceThreshold
        let geometry = LetterboxGeometry(orientedImageSize: frame.orientedPixelSize)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNCoreMLRequest(model: model)
                    request.imageCropAndScaleOption = .scaleFit
                    try frame.makeHandler().perform([request])
                    let raw = VisionRecognizer.decodeRawBoxes(from: request.results,
                                                               threshold: threshold, geometry: geometry)
                    continuation.resume(returning: raw)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Pull the raw output tensor and decode every row above `threshold`,
    /// regardless of whether its label maps to a ``Tile`` (mirrors
    /// ``decodeTiles(from:threshold:geometry:)`` but keeps `back`).
    static func decodeRawBoxes(from results: [VNObservation]?, threshold: Double,
                               geometry: LetterboxGeometry) -> [RawTileDetection] {
        guard let array = results?
            .lazy
            .compactMap({ ($0 as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue })
            .first else { return [] }
        return decodeRawBoxes(from: array, threshold: threshold, geometry: geometry)
    }

    static func decodeRawBoxes(from array: MLMultiArray, threshold: Double,
                               geometry: LetterboxGeometry) -> [RawTileDetection] {
        guard array.shape.count == 3, array.shape[2].intValue >= 6 else { return [] }
        let rows = array.shape[1].intValue
        let rowStride = array.strides[1].intValue
        let colStride = array.strides[2].intValue

        var raw: [RawTileDetection] = []
        array.withUnsafeBufferPointer(ofType: Float32.self) { buf in
            for i in 0..<rows {
                let row = i * rowStride
                let confidence = Double(buf[row + 4 * colStride])
                guard confidence >= threshold else { continue }
                let classIndex = Int(buf[row + 5 * colStride].rounded())
                guard classIndex >= 0, classIndex < HKDetectorLabels.ordered.count else { continue }
                let label = HKDetectorLabels.ordered[classIndex]
                let box = geometry.normalizedBox(
                    x1: Double(buf[row + 0 * colStride]), y1: Double(buf[row + 1 * colStride]),
                    x2: Double(buf[row + 2 * colStride]), y2: Double(buf[row + 3 * colStride]))
                raw.append(RawTileDetection(label: label, confidence: confidence, box: box))
            }
        }
        return suppressingRawOverlaps(raw)
    }

    /// Same class-agnostic greedy NMS as ``suppressingOverlaps(_:iouThreshold:)``,
    /// operating on ``RawTileDetection`` so `back` boxes get the identical
    /// duplicate-suppression treatment as mapped ones.
    static func suppressingRawOverlaps(_ detections: [RawTileDetection],
                                       iouThreshold: Double = 0.55) -> [RawTileDetection] {
        let ranked = detections.sorted {
            $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.box.x < $1.box.x
        }
        var kept: [RawTileDetection] = []
        for detection in ranked where kept.allSatisfy({ iou($0.box, detection.box) <= iouThreshold }) {
            kept.append(detection)
        }
        return kept
    }
}
