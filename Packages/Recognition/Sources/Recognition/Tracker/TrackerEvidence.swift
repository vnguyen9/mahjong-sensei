import Foundation
import MahjongCore

public enum TrackerEvidenceStatus: String, Sendable, Hashable, Codable {
    case confirmed
    case needsReview
    case userCorrected
    case manuallyAdded
    case excluded
}

/// The deterministic reason a one-pass detector result has its current state.
public enum TrackerFusionDecisionReason: String, Sendable, Hashable, Codable {
    case autoConfirmed
    case belowAutoConfirmThreshold
    case belowSuggestionThreshold
    case conservationViolation
    case unmappedLabel
    case invalidOutput
    case modelFailure
    case userSelected
    case manuallyAdded
}

/// One row from the Pro detector after model-space coordinates have been
/// mapped back into the upright canonical still.
public struct TrackerDirectDetection: Sendable, Hashable {
    public var label: String
    public var face: TileFace?
    public var confidence: Double
    public var box: TileBoundingBox

    public init(label: String, face: TileFace? = nil, confidence: Double,
                box: TileBoundingBox) {
        self.label = label
        self.face = face ?? TileFace(detectorLabel: label)
        self.confidence = confidence
        self.box = box
    }
}

public struct TrackerDetectorDescriptor: Sendable, Hashable {
    public var resourceName: String
    public var embeddedName: String
    public var embeddedVersion: String
    public var inputName: String
    public var outputName: String

    public init(resourceName: String = "MahjongTileDetectorProV3",
                embeddedName: String = "mjss-l-v3",
                embeddedVersion: String = "Unknown",
                inputName: String = "Unknown",
                outputName: String = "Unknown") {
        self.resourceName = resourceName
        self.embeddedName = embeddedName
        self.embeddedVersion = embeddedVersion
        self.inputName = inputName
        self.outputName = outputName
    }
}

public struct TrackerTileDiagnostics: Sendable, Hashable {
    public var detectorLabel: String
    public var detectionConfidence: Double
    public var sourceBox: TileBoundingBox
    public var insideGuide: Bool
    public var decisionReason: TrackerFusionDecisionReason

    public init(detectorLabel: String, detectionConfidence: Double,
                sourceBox: TileBoundingBox, insideGuide: Bool = true,
                decisionReason: TrackerFusionDecisionReason) {
        self.detectorLabel = detectorLabel
        self.detectionConfidence = detectionConfidence
        self.sourceBox = sourceBox
        self.insideGuide = insideGuide
        self.decisionReason = decisionReason
    }
}

public struct TrackerLetterboxDiagnostics: Sendable, Hashable {
    public var sourcePixelWidth: Int
    public var sourcePixelHeight: Int
    public var resizedPixelWidth: Int
    public var resizedPixelHeight: Int
    public var inputPixelSize: Int
    public var scale: Double
    public var leftPadding: Int
    public var topPadding: Int
    public var rightPadding: Int
    public var bottomPadding: Int
    public var paddingValue: Int
    public var interpolation: String

    public init(sourcePixelWidth: Int = 0, sourcePixelHeight: Int = 0,
                resizedPixelWidth: Int = 0, resizedPixelHeight: Int = 0,
                inputPixelSize: Int = 640, scale: Double = 0,
                leftPadding: Int = 0, topPadding: Int = 0,
                rightPadding: Int = 0, bottomPadding: Int = 0,
                paddingValue: Int = 114, interpolation: String = "bilinear") {
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.resizedPixelWidth = resizedPixelWidth
        self.resizedPixelHeight = resizedPixelHeight
        self.inputPixelSize = inputPixelSize
        self.scale = scale
        self.leftPadding = leftPadding
        self.topPadding = topPadding
        self.rightPadding = rightPadding
        self.bottomPadding = bottomPadding
        self.paddingValue = paddingValue
        self.interpolation = interpolation
    }
}

public struct TrackerDirectPassDiagnostics: Sendable, Hashable {
    public var rawTensorRowCount: Int
    public var positiveCandidateCount: Int
    public var validBoxCount: Int
    public var nmsAcceptedCount: Int
    public var insideGuideCount: Int
    public var outsideGuideCount: Int
    public var unmappedLabelCount: Int

    public init(rawTensorRowCount: Int = 0, positiveCandidateCount: Int = 0,
                validBoxCount: Int = 0, nmsAcceptedCount: Int = 0,
                insideGuideCount: Int = 0, outsideGuideCount: Int = 0,
                unmappedLabelCount: Int = 0) {
        self.rawTensorRowCount = rawTensorRowCount
        self.positiveCandidateCount = positiveCandidateCount
        self.validBoxCount = validBoxCount
        self.nmsAcceptedCount = nmsAcceptedCount
        self.insideGuideCount = insideGuideCount
        self.outsideGuideCount = outsideGuideCount
        self.unmappedLabelCount = unmappedLabelCount
    }
}

public struct TrackerStageTimingDiagnostics: Sendable, Hashable {
    public var cameraReadiness: TimeInterval
    public var photoDelivery: TimeInterval
    public var modelPreparation: TimeInterval
    public var modelWasCold: Bool
    public var orientationRendering: TimeInterval
    public var letterboxRendering: TimeInterval
    public var detectorInference: TimeInterval
    public var tensorDecode: TimeInterval
    public var nms: TimeInterval
    public var guideFiltering: TimeInterval
    public var reviewPreparation: TimeInterval
    public var total: TimeInterval

    public init(cameraReadiness: TimeInterval = 0,
                photoDelivery: TimeInterval = 0,
                modelPreparation: TimeInterval = 0,
                modelWasCold: Bool = false,
                orientationRendering: TimeInterval = 0,
                letterboxRendering: TimeInterval = 0,
                detectorInference: TimeInterval = 0,
                tensorDecode: TimeInterval = 0,
                nms: TimeInterval = 0,
                guideFiltering: TimeInterval = 0,
                reviewPreparation: TimeInterval = 0,
                total: TimeInterval = 0) {
        self.cameraReadiness = cameraReadiness
        self.photoDelivery = photoDelivery
        self.modelPreparation = modelPreparation
        self.modelWasCold = modelWasCold
        self.orientationRendering = orientationRendering
        self.letterboxRendering = letterboxRendering
        self.detectorInference = detectorInference
        self.tensorDecode = tensorDecode
        self.nms = nms
        self.guideFiltering = guideFiltering
        self.reviewPreparation = reviewPreparation
        self.total = total
    }
}

public struct TrackerDiagnosticCount: Sendable, Hashable {
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// Scan-wide scalar metadata attached only to the in-memory review transaction.
public struct TrackerScanDiagnostics: Sendable, Hashable {
    public var deviceClass: String
    public var cameraProfile: String
    public var detector: TrackerDetectorDescriptor
    public var previewPixelWidth: Int
    public var previewPixelHeight: Int
    public var canonicalPixelWidth: Int
    public var canonicalPixelHeight: Int
    public var canonicalFormat: String
    public var photoQualityPriority: String
    public var recognitionROI: TileBoundingBox?
    public var captureTimestamp: TimeInterval
    public var canonicalOrientation: String
    public var letterbox: TrackerLetterboxDiagnostics
    public var detectorPass: TrackerDirectPassDiagnostics
    public var timings: TrackerStageTimingDiagnostics
    public var confirmedTileCount: Int
    public var reviewTileCount: Int
    public var suggestionTileCount: Int
    public var reviewWithoutSuggestionTileCount: Int
    public var discardedBelowDisplayFloorCount: Int
    public var conservationViolationCount: Int
    public var decisionCounts: [TrackerDiagnosticCount]
    public var confidenceBandCounts: [TrackerDiagnosticCount]
    public var displayFloor: Double
    public var suggestionThreshold: Double
    public var autoConfirmThreshold: Double
    public var nmsIoUThreshold: Double

    public init(deviceClass: String = "Unknown",
                cameraProfile: String = "Unknown",
                detector: TrackerDetectorDescriptor = .init(),
                previewPixelWidth: Int = 0, previewPixelHeight: Int = 0,
                canonicalPixelWidth: Int = 0, canonicalPixelHeight: Int = 0,
                canonicalFormat: String = "Unknown",
                photoQualityPriority: String = "quality",
                recognitionROI: TileBoundingBox? = nil,
                captureTimestamp: TimeInterval = 0,
                canonicalOrientation: String = "up",
                letterbox: TrackerLetterboxDiagnostics = .init(),
                detectorPass: TrackerDirectPassDiagnostics = .init(),
                timings: TrackerStageTimingDiagnostics = .init(),
                confirmedTileCount: Int = 0, reviewTileCount: Int = 0,
                suggestionTileCount: Int = 0,
                reviewWithoutSuggestionTileCount: Int = 0,
                discardedBelowDisplayFloorCount: Int = 0,
                conservationViolationCount: Int = 0,
                decisionCounts: [TrackerDiagnosticCount] = [],
                confidenceBandCounts: [TrackerDiagnosticCount] = [],
                displayFloor: Double = TrackerDirectEvidencePolicy.displayFloor,
                suggestionThreshold: Double = TrackerDirectEvidencePolicy.suggestionThreshold,
                autoConfirmThreshold: Double = TrackerDirectEvidencePolicy.autoConfirmThreshold,
                nmsIoUThreshold: Double = 0.55) {
        self.deviceClass = deviceClass
        self.cameraProfile = cameraProfile
        self.detector = detector
        self.previewPixelWidth = previewPixelWidth
        self.previewPixelHeight = previewPixelHeight
        self.canonicalPixelWidth = canonicalPixelWidth
        self.canonicalPixelHeight = canonicalPixelHeight
        self.canonicalFormat = canonicalFormat
        self.photoQualityPriority = photoQualityPriority
        self.recognitionROI = recognitionROI
        self.captureTimestamp = captureTimestamp
        self.canonicalOrientation = canonicalOrientation
        self.letterbox = letterbox
        self.detectorPass = detectorPass
        self.timings = timings
        self.confirmedTileCount = confirmedTileCount
        self.reviewTileCount = reviewTileCount
        self.suggestionTileCount = suggestionTileCount
        self.reviewWithoutSuggestionTileCount = reviewWithoutSuggestionTileCount
        self.discardedBelowDisplayFloorCount = discardedBelowDisplayFloorCount
        self.conservationViolationCount = conservationViolationCount
        self.decisionCounts = decisionCounts
        self.confidenceBandCounts = confidenceBandCounts
        self.displayFloor = displayFloor
        self.suggestionThreshold = suggestionThreshold
        self.autoConfirmThreshold = autoConfirmThreshold
        self.nmsIoUThreshold = nmsIoUThreshold
    }
}

public struct TrackerTileEvidence: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var box: TileBoundingBox
    public var faceSuggestion: TileFace?
    public var detectionConfidence: Double
    public var status: TrackerEvidenceStatus
    public var decisionReason: TrackerFusionDecisionReason
    public var diagnostics: TrackerTileDiagnostics

    public init(id: UUID = UUID(), box: TileBoundingBox,
                faceSuggestion: TileFace?, detectionConfidence: Double,
                status: TrackerEvidenceStatus,
                decisionReason: TrackerFusionDecisionReason,
                diagnostics: TrackerTileDiagnostics? = nil) {
        self.id = id
        self.box = box
        self.faceSuggestion = faceSuggestion
        self.detectionConfidence = detectionConfidence
        self.status = status
        self.decisionReason = decisionReason
        self.diagnostics = diagnostics ?? TrackerTileDiagnostics(
            detectorLabel: faceSuggestion.map(Self.detectorLabel) ?? "unknown",
            detectionConfidence: detectionConfidence,
            sourceBox: box,
            decisionReason: decisionReason
        )
    }

    private static func detectorLabel(_ face: TileFace) -> String {
        switch face {
        case .back: return "back"
        case .tile(let tile): return tile.code
        }
    }
}

public enum TrackerDiscardReason: String, Sendable, Hashable, Codable {
    case detectionConfidenceBelowDisplayFloor
}

/// A detection kept outside the review transaction. Developer Mode may inspect
/// it, but it can never affect conservation, histogram deltas, or Apply.
public struct TrackerDiscardedTileEvidence: Identifiable, Sendable, Hashable {
    public var tile: TrackerTileEvidence
    public var reason: TrackerDiscardReason
    public var threshold: Double

    public var id: UUID { tile.id }

    public init(tile: TrackerTileEvidence, reason: TrackerDiscardReason,
                threshold: Double) {
        self.tile = tile
        self.reason = reason
        self.threshold = threshold
    }
}

public struct TrackerScanEvidence: Sendable, Hashable {
    public var scanID: UUID
    public var canonicalFrameID: FrameID
    public var tiles: [TrackerTileEvidence]
    public var discardedTiles: [TrackerDiscardedTileEvidence]
    public var outsideGuideDetections: [TrackerDirectDetection]
    public var diagnostics: TrackerScanDiagnostics

    public init(scanID: UUID = UUID(), canonicalFrameID: FrameID,
                tiles: [TrackerTileEvidence],
                discardedTiles: [TrackerDiscardedTileEvidence] = [],
                outsideGuideDetections: [TrackerDirectDetection] = [],
                diagnostics: TrackerScanDiagnostics = .init()) {
        self.scanID = scanID
        self.canonicalFrameID = canonicalFrameID
        self.tiles = tiles
        self.discardedTiles = discardedTiles
        self.outsideGuideDetections = outsideGuideDetections
        self.diagnostics = diagnostics
    }
}

public enum TrackerScanFailure: Error, Sendable, Hashable {
    case holdSteadier
    case moreLightNeeded
    case qualityRejected
    case detectorUnavailable(String)
    case detectorFailed(String)
    case noTilesFound
    case noDetectionsInsideGuide
    case imageCreationFailed
}

public enum TrackerScanOutcome: Sendable {
    case review(TrackerScanEvidence)
    case failed(TrackerScanFailure)
}

public enum TrackerDirectEvidencePolicy {
    /// Tracker's production live Medium detector uses the same visible floor
    /// that proved complete in Model Lab. Lower decoded rows remain available
    /// only to developer diagnostics.
    public static let displayFloor = 0.3000
    public static let suggestionThreshold = 0.3000
    public static let autoConfirmThreshold = 0.7200
}

public enum TrackerDirectEvidenceFusion {
    public static func makeEvidence(canonicalFrameID: FrameID,
                                    detections: [TrackerDirectDetection],
                                    displayFloor: Double = TrackerDirectEvidencePolicy.displayFloor,
                                    suggestionThreshold: Double = TrackerDirectEvidencePolicy.suggestionThreshold,
                                    autoConfirmThreshold: Double = TrackerDirectEvidencePolicy.autoConfirmThreshold)
        -> TrackerScanEvidence {
        var tiles: [TrackerTileEvidence] = []
        var discarded: [TrackerDiscardedTileEvidence] = []

        for detection in detections {
            let mappedFace = detection.face
            let status: TrackerEvidenceStatus
            let reason: TrackerFusionDecisionReason
            let suggestion: TileFace?

            if detection.confidence < displayFloor {
                status = .needsReview
                reason = .belowSuggestionThreshold
                suggestion = nil
            } else if mappedFace == nil {
                status = .needsReview
                reason = .unmappedLabel
                suggestion = nil
            } else if detection.confidence >= autoConfirmThreshold {
                status = .confirmed
                reason = .autoConfirmed
                suggestion = mappedFace
            } else if detection.confidence >= suggestionThreshold {
                status = .needsReview
                reason = .belowAutoConfirmThreshold
                suggestion = mappedFace
            } else {
                status = .needsReview
                reason = .belowSuggestionThreshold
                suggestion = nil
            }

            let tile = TrackerTileEvidence(
                box: detection.box,
                faceSuggestion: suggestion,
                detectionConfidence: detection.confidence,
                status: status,
                decisionReason: reason,
                diagnostics: TrackerTileDiagnostics(
                    detectorLabel: detection.label,
                    detectionConfidence: detection.confidence,
                    sourceBox: detection.box,
                    decisionReason: reason
                )
            )
            if detection.confidence < displayFloor {
                discarded.append(TrackerDiscardedTileEvidence(
                    tile: tile,
                    reason: .detectionConfidenceBelowDisplayFloor,
                    threshold: displayFloor
                ))
            } else {
                tiles.append(tile)
            }
        }

        downgradeConservationViolations(&tiles)
        return TrackerScanEvidence(canonicalFrameID: canonicalFrameID,
                                   tiles: tiles, discardedTiles: discarded)
    }

    private static func downgradeConservationViolations(
        _ tiles: inout [TrackerTileEvidence]
    ) {
        let confirmed = tiles.indices.filter { tiles[$0].status == .confirmed }
        let groups = Dictionary(grouping: confirmed) { index -> Tile? in
            guard case let .tile(tile)? = tiles[index].faceSuggestion else { return nil }
            return tile
        }
        for (tile, indices) in groups {
            guard let tile else { continue }
            let cap = tile.isBonus ? 1 : 4
            guard indices.count > cap else { continue }
            let excess = indices.sorted {
                if tiles[$0].detectionConfidence != tiles[$1].detectionConfidence {
                    return tiles[$0].detectionConfidence < tiles[$1].detectionConfidence
                }
                return tiles[$0].id.uuidString < tiles[$1].id.uuidString
            }.prefix(indices.count - cap)
            for index in excess {
                tiles[index].status = .needsReview
                tiles[index].decisionReason = .conservationViolation
                tiles[index].diagnostics.decisionReason = .conservationViolation
            }
        }
    }
}
