import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UIKit
import Recognition

struct TrackerReviewPayload: Identifiable {
    var evidence: TrackerScanEvidence
    /// Preview-resolution comparison image. Never used for inference.
    var previewImage: UIImage?
    /// Upright, full-resolution source of truth for markers and review.
    var image: UIImage
    /// The exact 640×640 model input created by our Ultralytics renderer.
    var detectorInputImage: UIImage?
    var canonicalData: Data?
    var canonicalFormat: String
    var recognitionROI: TileBoundingBox?
    var id: UUID { evidence.scanID }
}

enum TrackerScanProgress: Sendable {
    case preparing
    case takingPhoto
    case readingTiles
    case preparingReview
}

enum TrackerPresentationOutcome {
    case review(TrackerReviewPayload)
    case failed(TrackerScanFailure)
}

actor TrackerScanPipeline {
    static let shared = TrackerScanPipeline()

    private let detector: any TrackerDirectDetecting
    private let logger = Logger(subsystem: "com.lumiodatalabs.MahjongSensei",
                                category: "TrackerScanV4")
    private var modelsPrepared = false

    init(detector: any TrackerDirectDetecting = TrackerDirectDetector()) {
        self.detector = detector
    }

    func prepare() async throws {
        guard !modelsPrepared else { return }
        try await detector.prepare()
        modelsPrepared = true
    }

    func analyze(
        _ capture: TrackerStillCapture,
        progress: (@Sendable (TrackerScanProgress) async -> Void)? = nil
    ) async -> TrackerPresentationOutcome {
        let analysisStart = ContinuousClock.now
        do {
            let modelStart = ContinuousClock.now
            let wasCold = !modelsPrepared
            if wasCold { await progress?(.preparing) }
            try await prepare()
            let modelPreparation = modelStart.duration(to: .now).timeInterval

            await progress?(.readingTiles)
            let orientationStart = ContinuousClock.now
            let canonical = try UltralyticsLetterboxRenderer.bakeOrientation(
                capture.image,
                orientation: capture.imageOrientation
            )
            let orientationDuration = orientationStart.duration(to: .now).timeInterval
            let display = UIImage(cgImage: canonical)
            let preview = capture.previewImage.map(UIImage.init(cgImage:))

            let detectorResult = try await detector.detect(canonical)

            let guideStart = ContinuousClock.now
            let insideGuide: [TrackerDirectDetection]
            let outsideGuide: [TrackerDirectDetection]
            if let roi = capture.roi {
                insideGuide = detectorResult.detections.filter {
                    Self.containsCenter($0.box, in: roi)
                }
                outsideGuide = detectorResult.detections.filter {
                    !Self.containsCenter($0.box, in: roi)
                }
            } else {
                insideGuide = detectorResult.detections
                outsideGuide = []
            }
            let guideDuration = guideStart.duration(to: .now).timeInterval

            guard !detectorResult.detections.isEmpty else {
                return .failed(.noTilesFound)
            }
            guard insideGuide.contains(where: {
                $0.confidence >= TrackerDirectEvidencePolicy.displayFloor
            }) else {
                return .failed(capture.roi == nil ? .noTilesFound : .noDetectionsInsideGuide)
            }

            await progress?(.preparingReview)
            let reviewStart = ContinuousClock.now
            var evidence = TrackerDirectEvidenceFusion.makeEvidence(
                canonicalFrameID: FrameID(Int(clamping: Int64(
                    capture.captureTimestamp * 1_000
                ))),
                detections: insideGuide
            )
            evidence.outsideGuideDetections = outsideGuide
            guard !evidence.tiles.isEmpty else { return .failed(.noTilesFound) }
            let reviewPreparation = reviewStart.duration(to: .now).timeInterval

            let deviceClass = await MainActor.run {
                UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            }
            let analysisDuration = analysisStart.duration(to: .now).timeInterval
            let total = capture.cameraReadinessDuration
                + capture.photoDeliveryDuration
                + analysisDuration
            let geometry = detectorResult.letterbox
            let timings = TrackerStageTimingDiagnostics(
                cameraReadiness: capture.cameraReadinessDuration,
                photoDelivery: capture.photoDeliveryDuration,
                modelPreparation: modelPreparation,
                modelWasCold: wasCold,
                orientationRendering: orientationDuration,
                letterboxRendering: detectorResult.timings.letterboxRendering,
                detectorInference: detectorResult.timings.inference,
                tensorDecode: detectorResult.timings.tensorDecode,
                nms: detectorResult.timings.nms,
                guideFiltering: guideDuration,
                reviewPreparation: reviewPreparation,
                total: total
            )
            evidence.diagnostics = makeDiagnostics(
                evidence: evidence,
                deviceClass: deviceClass,
                capture: capture,
                canonical: canonical,
                detectorResult: detectorResult,
                timings: timings,
                letterbox: TrackerLetterboxDiagnostics(
                    sourcePixelWidth: geometry.sourceWidth,
                    sourcePixelHeight: geometry.sourceHeight,
                    resizedPixelWidth: geometry.resizedWidth,
                    resizedPixelHeight: geometry.resizedHeight,
                    inputPixelSize: geometry.inputSize,
                    scale: geometry.scale,
                    leftPadding: geometry.leftPadding,
                    topPadding: geometry.topPadding,
                    rightPadding: geometry.rightPadding,
                    bottomPadding: geometry.bottomPadding,
                    paddingValue: Int(UltralyticsLetterboxRenderer.paddingValue),
                    interpolation: "bilinear"
                )
            )

            logger.info("direct review ready total=\(total, format: .fixed(precision: 3))s inference=\(detectorResult.timings.inference, format: .fixed(precision: 3))s lens=\(capture.cameraLens.rawValue, privacy: .public) inside=\(insideGuide.count) outside=\(outsideGuide.count)")
            return .review(TrackerReviewPayload(
                evidence: evidence,
                previewImage: preview,
                image: display,
                detectorInputImage: UIImage(cgImage: detectorResult.detectorInputImage),
                canonicalData: capture.encodedPhotoData,
                canonicalFormat: capture.encodedFormat,
                recognitionROI: capture.roi
            ))
        } catch let error as TrackerDirectDetectorError {
            logger.error("direct detector unavailable: \(String(describing: error), privacy: .public)")
            switch error {
            case .modelNotFound:
                return .failed(.detectorUnavailable(error.localizedDescription))
            default:
                return .failed(.detectorFailed(error.localizedDescription))
            }
        } catch let failure as TrackerScanFailure {
            return .failed(failure)
        } catch {
            logger.error("direct detector failed: \(String(describing: error), privacy: .public)")
            return .failed(.detectorFailed(String(describing: error)))
        }
    }

    /// Photo Library testing shares the same upright, full-image, one-pass path.
    func analyzePhoto(_ data: Data, image: CGImage,
                      orientation: CGImagePropertyOrientation) async
        -> TrackerPresentationOutcome {
        let capture = TrackerStillCapture(
            id: UUID(),
            encodedPhotoData: data,
            encodedFormat: data.starts(with: [0xFF, 0xD8]) ? "JPEG" : "HEIC",
            image: image,
            imageOrientation: orientation,
            previewImage: nil,
            previewPixelSize: .zero,
            photoPixelSize: CGSize(width: image.width, height: image.height),
            cameraLens: .wide,
            captureTimestamp: ProcessInfo.processInfo.systemUptime,
            roi: nil,
            cameraReadinessDuration: 0,
            photoDeliveryDuration: 0
        )
        return await analyze(capture)
    }

    private func makeDiagnostics(
        evidence: TrackerScanEvidence,
        deviceClass: String,
        capture: TrackerStillCapture,
        canonical: CGImage,
        detectorResult: TrackerDirectDetectionResult,
        timings: TrackerStageTimingDiagnostics,
        letterbox: TrackerLetterboxDiagnostics
    ) -> TrackerScanDiagnostics {
        let allInside = evidence.tiles + evidence.discardedTiles.map(\.tile)
        let decisionCounts = Dictionary(grouping: allInside, by: \.decisionReason)
            .map { TrackerDiagnosticCount(name: $0.key.rawValue, count: $0.value.count) }
            .sorted { $0.name < $1.name }
        let bands: [(String, Range<Double>)] = [
            ("<0.10", 0..<0.10),
            ("0.10–0.15", 0.10..<0.15),
            ("0.15–0.50", 0.15..<0.50),
            ("0.50–0.72", 0.50..<TrackerDirectEvidencePolicy.autoConfirmThreshold),
            ("≥0.72", TrackerDirectEvidencePolicy.autoConfirmThreshold..<Double.greatestFiniteMagnitude),
        ]
        return TrackerScanDiagnostics(
            deviceClass: deviceClass,
            cameraProfile: capture.cameraLens.rawValue,
            detector: detectorResult.descriptor,
            previewPixelWidth: Int(capture.previewPixelSize.width),
            previewPixelHeight: Int(capture.previewPixelSize.height),
            canonicalPixelWidth: canonical.width,
            canonicalPixelHeight: canonical.height,
            canonicalFormat: capture.encodedFormat,
            photoQualityPriority: "quality",
            recognitionROI: capture.roi,
            captureTimestamp: capture.captureTimestamp,
            canonicalOrientation: "up (baked from \(capture.imageOrientation))",
            letterbox: letterbox,
            detectorPass: TrackerDirectPassDiagnostics(
                rawTensorRowCount: detectorResult.rawTensorRowCount,
                positiveCandidateCount: detectorResult.positiveCandidateCount,
                validBoxCount: detectorResult.validBoxCount,
                nmsAcceptedCount: detectorResult.detections.count,
                insideGuideCount: allInside.count,
                outsideGuideCount: evidence.outsideGuideDetections.count,
                unmappedLabelCount: detectorResult.unmappedLabelCount
            ),
            timings: timings,
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
            decisionCounts: decisionCounts,
            confidenceBandCounts: bands.map { band in
                TrackerDiagnosticCount(
                    name: band.0,
                    count: allInside.filter {
                        band.1.contains($0.detectionConfidence)
                    }.count
                )
            },
            nmsIoUThreshold: TrackerDirectDetector.nmsIoUThreshold
        )
    }

    private static func containsCenter(_ box: TileBoundingBox,
                                       in guide: TileBoundingBox) -> Bool {
        box.centerX >= guide.x && box.centerX <= guide.x + guide.width
            && box.centerY >= guide.y && box.centerY <= guide.y + guide.height
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let value = components
        return TimeInterval(value.seconds)
            + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}
