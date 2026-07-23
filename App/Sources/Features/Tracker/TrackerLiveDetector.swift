import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Observation
import QuartzCore
import UIKit
import MahjongCore
import Recognition

enum TrackerCaptureIntent: Sendable, Equatable {
    case table
    case hand
}

enum TrackerLiveDetectorError: Error, LocalizedError {
    case modelUnavailable
    case cameraNotReady
    case staleResult
    case imageCreationFailed
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "The Medium tile detector is unavailable."
        case .cameraNotReady:
            return "The camera is still preparing."
        case .staleResult:
            return "No fresh tile reading is available yet."
        case .imageCreationFailed:
            return "The review image could not be created."
        case .inferenceFailed:
            return "The tile detector could not read this frame."
        }
    }
}

/// An immutable pairing of one preview frame and the exact detections produced
/// from it. Tracker review never combines geometry from one frame with pixels
/// from another.
struct TrackerLiveSnapshot: @unchecked Sendable {
    var id: UUID
    var image: UIImage
    var detections: [RawTileDetection]
    var orientedPixelSize: CGSize
    var sequenceNumber: UInt64
    var timestamp: TimeInterval
    var completedAt: TimeInterval
    var orientation: CGImagePropertyOrientation
    var lens: CameraLens
    var inferenceDuration: TimeInterval
    var intent: TrackerCaptureIntent

    var visibleDetections: [RawTileDetection] {
        detections.filter {
            $0.confidence >= TrackerLiveDetectorPolicy.reviewFloor
                && TileFace(detectorLabel: $0.label) != nil
        }
    }
}

struct TrackerLiveTuning: Sendable, Equatable {
    var autoConfirmThreshold = 0.72
    var nmsIoUThreshold = 0.55

    static let defaults = TrackerLiveTuning()
    static let reviewFloor = 0.30
}

enum TrackerLiveDetectorPolicy {
    static let resourceName = DetectorModel.mediumV3.rawValue
    static let decodeFloor = 0.05
    static let reviewFloor = 0.30
    static let autoConfirmThreshold = TrackerLiveTuning.defaults.autoConfirmThreshold
    static let nmsIoUThreshold = 0.55
    static let freshSnapshotAge: TimeInterval = 0.250
    static let snapshotTimeout: TimeInterval = 0.500
}

/// Owns the fixed production Medium model. There is deliberately no fallback:
/// a missing model is a typed Tracker failure rather than a different model
/// silently changing the user's result.
actor TrackerMediumDetectorEngine {
    private var recognizer: VisionRecognizer?

    func prepare() throws {
        guard recognizer == nil else { return }
        do {
            var loaded = try VisionRecognizer(
                bundledModelNamed: TrackerLiveDetectorPolicy.resourceName,
                confidenceThreshold: TrackerLiveDetectorPolicy.decodeFloor
            )
            loaded.nmsIoUThreshold = TrackerLiveDetectorPolicy.nmsIoUThreshold
            recognizer = loaded
        } catch {
            throw TrackerLiveDetectorError.modelUnavailable
        }
    }

    func detect(_ frame: RecognizerFrame,
                nmsIoUThreshold: Double = TrackerLiveDetectorPolicy.nmsIoUThreshold)
        async throws -> [RawTileDetection] {
        try prepare()
        guard var tuned = recognizer else { throw TrackerLiveDetectorError.modelUnavailable }
        tuned.nmsIoUThreshold = nmsIoUThreshold
        recognizer = tuned
        do {
            return try await tuned.detectRawBoxes(
                frame,
                minimumConfidence: TrackerLiveDetectorPolicy.decodeFloor
            )
        } catch {
            throw TrackerLiveDetectorError.inferenceFailed(String(describing: error))
        }
    }
}

/// Main-actor presentation adapter around the serial detector engine. It keeps
/// at most one inference in flight and always jumps to the newest camera frame,
/// matching the working Debug Model Lab behavior.
@Observable
@MainActor
final class TrackerLiveDetectorController {
    private struct CompletedResult: @unchecked Sendable {
        var frame: CameraFrame
        var detections: [RawTileDetection]
        var orientedPixelSize: CGSize
        var inferenceDuration: TimeInterval
        var completedAt: TimeInterval
    }

    let camera: CameraCapture
    private let engine: TrackerMediumDetectorEngine

    private(set) var detections: [RawTileDetection] = []
    private(set) var orientedImageSize: CGSize = .zero
    /// The `imageOrientation` the current `detections`/`orientedImageSize`
    /// were produced with. Published alongside them (never read from
    /// `camera.imageOrientation` directly) so an overlay drawn a moment after
    /// a rotation can't pair stale detections with the new orientation.
    private(set) var frameOrientation: CGImagePropertyOrientation = .right
    private(set) var inferenceMilliseconds = 0.0
    private(set) var framesPerSecond = 0.0
    private(set) var isReady = false
    private(set) var errorMessage: String?
    private(set) var isPaused = false
    var nmsIoUThreshold = TrackerLiveDetectorPolicy.nmsIoUThreshold

    private var latestResult: CompletedResult?
    private var loopTask: Task<Void, Never>?
    private var lastSequence: UInt64 = 0

    init(camera: CameraCapture, engine: TrackerMediumDetectorEngine = .init()) {
        self.camera = camera
        self.engine = engine
    }

    func start() {
        isPaused = false
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isPaused = true
    }

    func pause() { isPaused = true }
    func resume() {
        isPaused = false
        start()
    }

    /// Returns a stable table snapshot. If the current result is stale, waits
    /// briefly for the next live inference rather than re-running another model
    /// path at shutter time.
    func captureTableSnapshot(
        maxAge: TimeInterval = TrackerLiveDetectorPolicy.freshSnapshotAge,
        timeout: TimeInterval = TrackerLiveDetectorPolicy.snapshotTimeout,
        newerThan sequence: UInt64? = nil
    ) async throws -> TrackerLiveSnapshot {
        resume()
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() <= deadline {
            if let result = latestResult,
               sequence.map({ result.frame.sequenceNumber > $0 }) ?? true,
               CACurrentMediaTime() - result.completedAt <= maxAge {
                return try makeSnapshot(from: result, intent: .table)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        throw latestResult == nil
            ? TrackerLiveDetectorError.cameraNotReady
            : TrackerLiveDetectorError.staleResult
    }

    /// Hand Scan intentionally reuses Score's native crop operation. The model
    /// sees only the wide hand band, and review boxes are normalized to that
    /// cropped image so editing remains exact.
    func captureHandSnapshot(
        roi: TileBoundingBox,
        margin: Double = 0.04
    ) async throws -> TrackerLiveSnapshot {
        guard let frame = camera.latestFrame else {
            throw TrackerLiveDetectorError.cameraNotReady
        }
        let expanded = Self.expanded(roi, margin: margin)
        guard let croppedFrame = ScanView.croppedFrame(
            from: frame.pixelBuffer,
            roiNormalized: roi,
            orientation: frame.imageOrientation,
            margin: margin
        ) else {
            throw TrackerLiveDetectorError.imageCreationFailed
        }
        let started = CACurrentMediaTime()
        let reads = try await engine.detect(croppedFrame,
                                            nmsIoUThreshold: nmsIoUThreshold)
        let duration = CACurrentMediaTime() - started
        guard let fullImage = ScanView.photo(
            from: frame.pixelBuffer,
            orientation: frame.imageOrientation
        ), let fullCG = fullImage.cgImage else {
            throw TrackerLiveDetectorError.imageCreationFailed
        }
        let rect = CGRect(
            x: expanded.x * Double(fullCG.width),
            y: expanded.y * Double(fullCG.height),
            width: expanded.width * Double(fullCG.width),
            height: expanded.height * Double(fullCG.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: fullCG.width, height: fullCG.height))
        guard rect.width >= 2, rect.height >= 2,
              let crop = fullCG.cropping(to: rect) else {
            throw TrackerLiveDetectorError.imageCreationFailed
        }
        return TrackerLiveSnapshot(
            id: UUID(), image: UIImage(cgImage: crop), detections: reads,
            orientedPixelSize: CGSize(width: crop.width, height: crop.height),
            sequenceNumber: frame.sequenceNumber, timestamp: frame.timestamp,
            completedAt: CACurrentMediaTime(), orientation: .up,
            lens: frame.cameraLens, inferenceDuration: duration, intent: .hand
        )
    }

    private func runLoop() async {
        var lastCompletedAt = CACurrentMediaTime()
        do {
            try await engine.prepare()
            isReady = true
            errorMessage = nil
        } catch {
            isReady = false
            errorMessage = error.localizedDescription
            return
        }

        while !Task.isCancelled {
            guard !isPaused,
                  let frame = camera.latestFrame,
                  frame.sequenceNumber != lastSequence else {
                try? await Task.sleep(for: .milliseconds(24))
                continue
            }
            lastSequence = frame.sequenceNumber
            let recognizerFrame = RecognizerFrame.buffer(
                frame.pixelBuffer,
                orientation: frame.imageOrientation
            )
            let started = CACurrentMediaTime()
            do {
                let reads = try await engine.detect(
                    recognizerFrame,
                    nmsIoUThreshold: nmsIoUThreshold
                )
                let completed = CACurrentMediaTime()
                let duration = completed - started
                let delta = completed - lastCompletedAt
                lastCompletedAt = completed
                latestResult = CompletedResult(
                    frame: frame, detections: reads,
                    orientedPixelSize: recognizerFrame.orientedPixelSize,
                    inferenceDuration: duration, completedAt: completed
                )
                detections = reads
                orientedImageSize = recognizerFrame.orientedPixelSize
                frameOrientation = frame.imageOrientation
                let milliseconds = duration * 1_000
                inferenceMilliseconds = inferenceMilliseconds == 0
                    ? milliseconds : inferenceMilliseconds * 0.8 + milliseconds * 0.2
                let instantFPS = delta > 0 ? 1 / delta : 0
                framesPerSecond = framesPerSecond == 0
                    ? instantFPS : framesPerSecond * 0.8 + instantFPS * 0.2
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            await Task.yield()
        }
    }

    private func makeSnapshot(
        from result: CompletedResult,
        intent: TrackerCaptureIntent
    ) throws -> TrackerLiveSnapshot {
        guard let image = ScanView.photo(
            from: result.frame.pixelBuffer,
            orientation: result.frame.imageOrientation
        ) else {
            throw TrackerLiveDetectorError.imageCreationFailed
        }
        return TrackerLiveSnapshot(
            id: UUID(), image: image, detections: result.detections,
            orientedPixelSize: result.orientedPixelSize,
            sequenceNumber: result.frame.sequenceNumber,
            timestamp: result.frame.timestamp,
            completedAt: result.completedAt,
            orientation: .up, lens: result.frame.cameraLens,
            inferenceDuration: result.inferenceDuration, intent: intent
        )
    }

    private static func expanded(_ roi: TileBoundingBox, margin: Double) -> TileBoundingBox {
        let mx = roi.width * max(0, margin)
        let my = roi.height * max(0, margin)
        let x = max(0, roi.x - mx)
        let y = max(0, roi.y - my)
        let maxX = min(1, roi.x + roi.width + mx)
        let maxY = min(1, roi.y + roi.height + my)
        return TileBoundingBox(x: x, y: y, width: maxX - x, height: maxY - y)
    }
}

enum TrackerLiveEvidenceBuilder {
    static func payload(from snapshot: TrackerLiveSnapshot,
                        guideROI: TileBoundingBox,
                        tuning: TrackerLiveTuning) -> TrackerReviewPayload {
        let mapped = snapshot.detections.map {
            TrackerDirectDetection(
                label: $0.label,
                confidence: $0.confidence,
                box: $0.box
            )
        }
        let direct = mapped.filter { guideROI.containsCenter(of: $0.box) }
        let outsideGuide = mapped.filter { !guideROI.containsCenter(of: $0.box) }
        var evidence = TrackerDirectEvidenceFusion.makeEvidence(
            canonicalFrameID: FrameID(Int(clamping: snapshot.sequenceNumber)),
            detections: direct,
            displayFloor: TrackerLiveTuning.reviewFloor,
            suggestionThreshold: TrackerLiveTuning.reviewFloor,
            autoConfirmThreshold: tuning.autoConfirmThreshold
        )
        evidence.outsideGuideDetections = outsideGuide
        let all = evidence.tiles + evidence.discardedTiles.map(\.tile)
        let decisions = Dictionary(grouping: all, by: \.decisionReason)
            .map { TrackerDiagnosticCount(name: $0.key.rawValue, count: $0.value.count) }
            .sorted { $0.name < $1.name }
        evidence.diagnostics = TrackerScanDiagnostics(
            deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            cameraProfile: snapshot.lens.rawValue,
            detector: TrackerDetectorDescriptor(
                resourceName: TrackerLiveDetectorPolicy.resourceName,
                embeddedName: "mjss-m-v3",
                embeddedVersion: "V3",
                inputName: "preview frame",
                outputName: "1 × 300 × 6"
            ),
            previewPixelWidth: Int(snapshot.orientedPixelSize.width),
            previewPixelHeight: Int(snapshot.orientedPixelSize.height),
            canonicalPixelWidth: Int(snapshot.image.size.width),
            canonicalPixelHeight: Int(snapshot.image.size.height),
            canonicalFormat: "Preview snapshot",
            photoQualityPriority: "live video frame",
            recognitionROI: guideROI,
            captureTimestamp: snapshot.timestamp,
            canonicalOrientation: "up (baked from preview)",
            detectorPass: TrackerDirectPassDiagnostics(
                rawTensorRowCount: 300,
                positiveCandidateCount: snapshot.detections.count,
                validBoxCount: snapshot.detections.count,
                nmsAcceptedCount: snapshot.detections.count,
                insideGuideCount: direct.count,
                outsideGuideCount: outsideGuide.count,
                unmappedLabelCount: direct.filter {
                    TileFace(detectorLabel: $0.label) == nil
                }.count
            ),
            timings: TrackerStageTimingDiagnostics(
                detectorInference: snapshot.inferenceDuration,
                total: snapshot.inferenceDuration
            ),
            confirmedTileCount: evidence.tiles.filter { $0.status == .confirmed }.count,
            reviewTileCount: evidence.tiles.filter { $0.status == .needsReview }.count,
            suggestionTileCount: evidence.tiles.filter {
                $0.status == .needsReview && $0.faceSuggestion != nil
            }.count,
            reviewWithoutSuggestionTileCount: evidence.tiles.filter {
                $0.status == .needsReview && $0.faceSuggestion == nil
            }.count,
            discardedBelowDisplayFloorCount: evidence.discardedTiles.count,
            conservationViolationCount: evidence.tiles.filter {
                $0.decisionReason == .conservationViolation
            }.count,
            decisionCounts: decisions,
            confidenceBandCounts: confidenceBands(all),
            displayFloor: TrackerLiveTuning.reviewFloor,
            suggestionThreshold: TrackerLiveTuning.reviewFloor,
            autoConfirmThreshold: tuning.autoConfirmThreshold,
            nmsIoUThreshold: tuning.nmsIoUThreshold
        )
        return TrackerReviewPayload(
            evidence: evidence,
            previewImage: snapshot.image,
            image: snapshot.image,
            detectorInputImage: nil,
            canonicalData: nil,
            canonicalFormat: "Preview snapshot",
            recognitionROI: guideROI
        )
    }

    private static func confidenceBands(
        _ tiles: [TrackerTileEvidence]
    ) -> [TrackerDiagnosticCount] {
        let bands: [(String, Range<Double>)] = [
            ("0.05–0.30", 0.05..<0.30),
            ("0.30–0.50", 0.30..<0.50),
            ("0.50–0.70", 0.50..<0.70),
            ("0.70–0.72", 0.70..<TrackerDirectEvidencePolicy.autoConfirmThreshold),
            ("≥0.72", TrackerDirectEvidencePolicy.autoConfirmThreshold..<Double.greatestFiniteMagnitude),
        ]
        return bands.map { name, range in
            TrackerDiagnosticCount(
                name: name,
                count: tiles.filter { range.contains($0.detectionConfidence) }.count
            )
        }
    }
}

private extension TileBoundingBox {
    func containsCenter(of box: TileBoundingBox) -> Bool {
        box.centerX >= x && box.centerX <= x + width
            && box.centerY >= y && box.centerY <= y + height
    }
}
