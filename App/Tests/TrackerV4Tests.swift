import CoreGraphics
import CoreML
import ImageIO
import UIKit
import XCTest
@testable import Mahjong_Sensei
import MahjongCore
import Recognition

@MainActor
final class TrackerV4Tests: XCTestCase {
    func testLiveTrackerUsesTheWorkingModelLabMediumPolicy() {
        XCTAssertEqual(TrackerLiveDetectorPolicy.resourceName,
                       "MahjongTileDetectorMediumV3")
        XCTAssertEqual(TrackerLiveDetectorPolicy.decodeFloor, 0.05)
        XCTAssertEqual(TrackerLiveDetectorPolicy.reviewFloor, 0.30)
        XCTAssertEqual(TrackerLiveDetectorPolicy.autoConfirmThreshold, 0.72)
        XCTAssertEqual(TrackerLiveDetectorPolicy.nmsIoUThreshold, 0.55)
    }

    func testFrozenLiveSnapshotCarriesTheExactFrameAndMediumDiagnostics() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let snapshot = TrackerLiveSnapshot(
            id: UUID(), image: image,
            detections: [.init(
                label: "1m", confidence: 0.81,
                box: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.3)
            )],
            orientedPixelSize: CGSize(width: 40, height: 60),
            sequenceNumber: 42, timestamp: 12.5, completedAt: 12.6,
            orientation: .up, lens: .wide, inferenceDuration: 0.025,
            intent: .table
        )

        let payload = TrackerLiveEvidenceBuilder.payload(
            from: snapshot,
            guideROI: .init(x: 0, y: 0, width: 1, height: 1),
            tuning: .defaults
        )

        XCTAssertEqual(payload.evidence.canonicalFrameID, FrameID(42))
        XCTAssertEqual(payload.evidence.tiles.count, 1)
        XCTAssertEqual(payload.evidence.tiles[0].status, .confirmed)
        XCTAssertEqual(payload.evidence.diagnostics.detector.resourceName,
                       "MahjongTileDetectorMediumV3")
        XCTAssertEqual(payload.evidence.diagnostics.detector.embeddedName,
                       "mjss-m-v3")
        XCTAssertEqual(payload.evidence.diagnostics.photoQualityPriority,
                       "live video frame")
    }

    func testFrozenLiveSnapshotExcludesDetectionsOutsideTheGuide() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let snapshot = TrackerLiveSnapshot(
            id: UUID(), image: image,
            detections: [
                .init(label: "1m", confidence: 0.9,
                      box: .init(x: 0.25, y: 0.25, width: 0.1, height: 0.1)),
                .init(label: "2m", confidence: 0.9,
                      box: .init(x: 0.8, y: 0.8, width: 0.1, height: 0.1)),
            ],
            orientedPixelSize: CGSize(width: 100, height: 100),
            sequenceNumber: 7, timestamp: 1, completedAt: 1,
            orientation: .up, lens: .wide, inferenceDuration: 0.01,
            intent: .table
        )

        let payload = TrackerLiveEvidenceBuilder.payload(
            from: snapshot,
            guideROI: .init(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            tuning: .defaults
        )

        XCTAssertEqual(payload.evidence.tiles.map(\.diagnostics.detectorLabel), ["1m"])
        XCTAssertEqual(payload.evidence.outsideGuideDetections.map(\.label), ["2m"])
        XCTAssertEqual(payload.evidence.diagnostics.detectorPass.insideGuideCount, 1)
        XCTAssertEqual(payload.evidence.diagnostics.detectorPass.outsideGuideCount, 1)
    }

    func testHandScanAndManualEditsCommitThroughOneAtomicApply() throws {
        let session = TrackerSession(store: TrackerStore())
        session.seenHistogram[Tile.east.classIndex] = 3
        try session.applyHand([.m(1), .m(2)])

        XCTAssertThrowsError(try session.applyHand([.east, .east]))
        XCTAssertEqual(session.hand, [.m(1), .m(2)])

        try session.applyHand([.m(1), .m(3), .m(3)])
        XCTAssertEqual(session.hand, [.m(1), .m(3), .m(3)])
    }

    func testReferenceFixtureIsUprightAndMetadataFree() throws {
        let url = try fixtureURL(named: "tracker-pro-full-table-37", extension: "jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 3_024)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 4_032)
        XCTAssertNil(properties[kCGImagePropertyOrientation])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
    }

    func testLetterboxMatchesOpenCVReferenceWithinBilinearTolerance() throws {
        let canonical = try fixtureImage(named: "tracker-pro-full-table-37",
                                         extension: "jpeg")
        let reference = try fixtureImage(named: "tracker-pro-full-table-37-letterbox",
                                         extension: "png")
        let rendered = try UltralyticsLetterboxRenderer.render(canonical)
        let actualAttachment = XCTAttachment(
            image: UIImage(cgImage: rendered.image), quality: .original
        )
        actualAttachment.name = "Core Graphics letterbox"
        actualAttachment.lifetime = .deleteOnSuccess
        add(actualAttachment)
        let referenceAttachment = XCTAttachment(
            image: UIImage(cgImage: reference), quality: .original
        )
        referenceAttachment.name = "OpenCV letterbox"
        referenceAttachment.lifetime = .deleteOnSuccess
        add(referenceAttachment)

        XCTAssertEqual(rendered.geometry.resizedWidth, 480)
        XCTAssertEqual(rendered.geometry.resizedHeight, 640)
        XCTAssertEqual(rendered.geometry.leftPadding, 80)
        XCTAssertEqual(rendered.geometry.rightPadding, 80)
        let actualPixels = try rgbaPixels(rendered.image)
        let expectedPixels = try rgbaPixels(reference)
        XCTAssertEqual(actualPixels.count, expectedPixels.count)

        var totalDifference = 0
        var comparedComponents = 0
        for index in stride(from: 0, to: actualPixels.count, by: 4) {
            for component in 0..<3 {
                totalDifference += abs(Int(actualPixels[index + component])
                                       - Int(expectedPixels[index + component]))
                comparedComponents += 1
            }
        }
        let meanDifference = Double(totalDifference) / Double(comparedComponents)
        // ImageIO and OpenCV use different JPEG decoders/color conversion.
        // Five 8-bit levels keeps that decode variance while still catching
        // wrong padding, orientation, resize dimensions, or resampler choice.
        XCTAssertLessThanOrEqual(meanDifference, 5.0)

        // The detector input's side bars must be Ultralytics gray, not black.
        let leftCenter = (320 * 640 + 40) * 4
        XCTAssertEqual(Array(actualPixels[leftCenter..<(leftCenter + 3)]),
                       [114, 114, 114])
    }

    func testProModelMatchesThe37TileReferenceHistogram() async throws {
        let image = try fixtureImage(named: "tracker-pro-full-table-37",
                                     extension: "jpeg")
        let expectedURL = try fixtureURL(
            named: "tracker-pro-full-table-37.expected", extension: "json"
        )
        let expected = try JSONDecoder().decode(
            ReferenceExpectation.self, from: Data(contentsOf: expectedURL)
        )
        let result = try await TrackerDirectDetector().detect(image)
        let visible = result.detections.filter {
            $0.confidence >= TrackerDirectEvidencePolicy.displayFloor
        }
        let histogram = Dictionary(grouping: visible, by: \.label)
            .mapValues(\.count)

        XCTAssertEqual(visible.count, expected.detectionCount)
        XCTAssertEqual(histogram, expected.histogram)
        XCTAssertGreaterThanOrEqual(visible.filter {
            $0.confidence >= TrackerDirectEvidencePolicy.autoConfirmThreshold
        }.count, expected.autoConfirmCount)
        XCTAssertEqual(result.descriptor.resourceName, "MahjongTileDetectorProV3")
        XCTAssertEqual(result.descriptor.embeddedName, "mjss-l-v3")
        XCTAssertEqual(result.descriptor.embeddedVersion, expected.modelVersion)
    }

    func testTrackerAlwaysNamesTheProResource() {
        XCTAssertEqual(TrackerDirectDetector.resourceName,
                       "MahjongTileDetectorProV3")
    }

    func testUnreviewedSuggestionsApplyAtomically() throws {
        let session = TrackerSession(store: TrackerStore())
        session.seenHistogram[Tile.m(9).classIndex] = 2
        let draft = TrackerReviewDraft(evidence: evidence([
            tile(.m(1), status: .needsReview),
            tile(.p(2), status: .confirmed),
        ]))

        let changed = try session.apply(draft)

        XCTAssertEqual(session.tableSeen(.m(9)), 0)
        XCTAssertEqual(session.tableSeen(.m(1)), 1)
        XCTAssertEqual(session.tableSeen(.p(2)), 1)
        XCTAssertTrue(changed.contains(Tile.m(9).classIndex))
    }

    func testUnreviewedTileWithoutSuggestionIsSkipped() throws {
        let session = TrackerSession(store: TrackerStore())
        let draft = TrackerReviewDraft(evidence: evidence([
            tile(.m(1), status: .confirmed),
            tile(.p(2), status: .needsReview),
        ]))
        draft.tiles[1].face = nil

        let projection = draft.applicationProjection(hand: [])
        XCTAssertEqual(projection.suggestedEvidenceIDs.count, 0)
        XCTAssertEqual(projection.skippedEvidenceIDs, Set([draft.tiles[1].id]))

        _ = try session.apply(draft)
        XCTAssertEqual(session.tableSeen(.m(1)), 1)
        XCTAssertEqual(session.tableSeen(.p(2)), 0)
    }

    func testAutoConfirmBoundaryIsExactlyPointSevenTwo() {
        let evidence = TrackerDirectEvidenceFusion.makeEvidence(
            canonicalFrameID: FrameID(1),
            detections: [
                .init(label: "1m", confidence: 0.719_999,
                      box: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.2)),
                .init(label: "2m", confidence: 0.720_000,
                      box: .init(x: 0.3, y: 0.1, width: 0.1, height: 0.2)),
            ]
        )

        XCTAssertEqual(evidence.tiles.map(\.status), [.needsReview, .confirmed])
    }

    func testDiscardedDetectionsNeverEnterDraft() {
        let included = tile(.p(7), status: .needsReview)
        let discardedTile = tile(.m(2), status: .needsReview,
                                 confidence: 0.0999)
        var scan = evidence([included])
        scan.discardedTiles = [.init(
            tile: discardedTile,
            reason: .detectionConfidenceBelowDisplayFloor,
            threshold: 0.10
        )]

        let draft = TrackerReviewDraft(evidence: scan)

        XCTAssertEqual(draft.tiles.map(\.id), [included.id])
        XCTAssertEqual(draft.includedCount, 1)
    }

    func testDiagnosticsExportIsDirectAndScalarOnly() {
        var scan = evidence([tile(.p(7), status: .needsReview)])
        scan.diagnostics = TrackerScanDiagnostics(
            deviceClass: "iPad",
            cameraProfile: "1×",
            detector: .init(resourceName: "MahjongTileDetectorProV3",
                            embeddedName: "mjss-l-v3",
                            embeddedVersion: "8.4.98",
                            inputName: "image", outputName: "var_1149"),
            previewPixelWidth: 1920,
            previewPixelHeight: 1080,
            canonicalPixelWidth: 3024,
            canonicalPixelHeight: 4032,
            canonicalFormat: "JPEG",
            letterbox: .init(sourcePixelWidth: 3024, sourcePixelHeight: 4032,
                             resizedPixelWidth: 480, resizedPixelHeight: 640,
                             scale: 640.0 / 4032.0,
                             leftPadding: 80, topPadding: 0,
                             rightPadding: 80, bottomPadding: 0),
            detectorPass: .init(rawTensorRowCount: 300,
                                positiveCandidateCount: 37,
                                validBoxCount: 37, nmsAcceptedCount: 37,
                                insideGuideCount: 37),
            reviewTileCount: 1,
            suggestionTileCount: 1
        )

        let json = TrackerDiagnosticsExporter.jsonString(for: scan)

        XCTAssertTrue(json.contains("MahjongTileDetectorProV3"))
        XCTAssertTrue(json.contains("mjss-l-v3"))
        XCTAssertTrue(json.contains("detectionConfidence"))
        XCTAssertTrue(json.contains("letterbox"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("imageData"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("filePath"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("locatorModel"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("faceConfidence"))
    }

    func testDirectTensorDecodeAndClassAgnosticNMS() throws {
        let tensor = try MLMultiArray(shape: [1, 300, 6], dataType: .float32)
        for index in 0..<tensor.count { tensor[index] = 0 }
        setRow(tensor, row: 0, values: [64, 96, 192, 288, 0.91, 0])
        setRow(tensor, row: 1, values: [66, 98, 194, 290, 0.70, 1])
        let decoded = try TrackerDirectDetector.decode(
            tensor,
            geometry: .init(sourceSize: CGSize(width: 640, height: 640))
        )
        let kept = TrackerDirectDetector.suppressingOverlaps(decoded.detections)

        XCTAssertEqual(decoded.rawRowCount, 300)
        XCTAssertEqual(decoded.positiveCandidateCount, 2)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].label, "1m")
        XCTAssertEqual(kept[0].box.x, 0.10, accuracy: 0.001)
    }

    func testInvalidTensorRowsNeverBecomeEvidence() throws {
        let tensor = try MLMultiArray(shape: [1, 300, 6], dataType: .float32)
        for index in 0..<tensor.count { tensor[index] = 0 }
        setRow(tensor, row: 0, values: [10, 10, 30, 40, 0.8, 0])
        setRow(tensor, row: 1, values: [.nan, 10, 30, 40, 0.8, 0])
        setRow(tensor, row: 2, values: [10, 10, 30, 40, -0.2, 0])
        setRow(tensor, row: 3, values: [10, 10, 30, 40, 0.8, 99])
        let decoded = try TrackerDirectDetector.decode(
            tensor,
            geometry: .init(sourceSize: CGSize(width: 640, height: 640))
        )

        XCTAssertEqual(decoded.positiveCandidateCount, 3)
        XCTAssertEqual(decoded.unmappedLabelCount, 1)
        XCTAssertEqual(decoded.detections.count, 1)
    }

    func testPipelineInvokesOneDirectDetectionPass() async throws {
        let image = try makeImage(width: 640, height: 640)
        let fake = DirectDetectorProbe(image: image)
        let pipeline = TrackerScanPipeline(detector: fake)
        let capture = TrackerStillCapture(
            id: UUID(), encodedPhotoData: Data(), encodedFormat: "JPEG",
            image: image, imageOrientation: .up, previewImage: nil,
            previewPixelSize: .zero,
            photoPixelSize: CGSize(width: 640, height: 640),
            cameraLens: .wide, captureTimestamp: 1,
            roi: nil, cameraReadinessDuration: 0, photoDeliveryDuration: 0
        )

        let outcome = await pipeline.analyze(capture)
        let calls = await fake.values

        XCTAssertEqual(calls.prepare, 1)
        XCTAssertEqual(calls.detect, 1)
        guard case .review(let payload) = outcome else {
            return XCTFail("Expected review evidence")
        }
        XCTAssertEqual(payload.evidence.tiles.count, 1)
        XCTAssertEqual(payload.evidence.tiles[0].status, .confirmed)
    }

    func testGuideUsesDetectionCenterAfterTheSinglePass() async throws {
        let image = try makeImage(width: 640, height: 640)
        let fake = DirectDetectorProbe(image: image, detections: [
            .init(label: "1m", confidence: 0.9,
                  box: .init(x: 0.25, y: 0.25, width: 0.1, height: 0.1)),
            .init(label: "2m", confidence: 0.9,
                  box: .init(x: 0.75, y: 0.75, width: 0.1, height: 0.1)),
        ])
        let pipeline = TrackerScanPipeline(detector: fake)
        let capture = TrackerStillCapture(
            id: UUID(), encodedPhotoData: Data(), encodedFormat: "JPEG",
            image: image, imageOrientation: .up, previewImage: nil,
            previewPixelSize: .zero, photoPixelSize: .init(width: 640, height: 640),
            cameraLens: .wide, captureTimestamp: 1,
            roi: .init(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            cameraReadinessDuration: 0, photoDeliveryDuration: 0
        )

        let outcome = await pipeline.analyze(capture)

        guard case .review(let payload) = outcome else {
            return XCTFail("Expected guide-filtered review")
        }
        XCTAssertEqual(payload.evidence.tiles.map(\.diagnostics.detectorLabel), ["1m"])
        XCTAssertEqual(payload.evidence.outsideGuideDetections.map(\.label), ["2m"])
        let calls = await fake.values
        XCTAssertEqual(calls.detect, 1)
    }

    func testConservationBlocksApplyAgainstPreservedHand() {
        let session = TrackerSession(store: TrackerStore())
        session.hand = [.east]
        let draft = TrackerReviewDraft(
            evidence: evidence((0..<4).map { _ in
                tile(.east, status: .confirmed)
            }),
            hand: session.hand
        )

        XCTAssertEqual(draft.unresolvedCount, 1)
        XCTAssertThrowsError(try session.apply(draft))
        XCTAssertEqual(session.tableSeen(.east), 0)
    }

    func testTypedFailuresCannotBecomeEmptySuccesses() {
        let failures: [TrackerScanFailure] = [
            .holdSteadier, .moreLightNeeded, .qualityRejected,
            .noTilesFound, .noDetectionsInsideGuide, .imageCreationFailed,
            .detectorUnavailable("missing"), .detectorFailed("failed"),
        ]
        for failure in failures {
            guard case .failed(let value) = TrackerScanOutcome.failed(failure) else {
                return XCTFail("Expected typed failure")
            }
            XCTAssertEqual(value, failure)
        }
    }

    func testPresentationStartsCameraFirstAndApplyStartsSmall() {
        let state = TrackerPresentationState()
        XCTAssertFalse(state.isDrawerVisible)
        XCTAssertEqual(state.phase, .cameraFirst)

        state.beginCapture()
        XCTAssertEqual(state.phase, .capturing)
        state.showFrozenAnalysis()
        XCTAssertEqual(state.phase, .frozenAnalyzing)
        state.showReview()
        XCTAssertEqual(state.phase, .review)
        state.cancelReviewOrCapture()
        XCTAssertEqual(state.phase, .cameraFirst)

        state.showAfterApply()

        XCTAssertTrue(state.isDrawerVisible)
        XCTAssertEqual(state.drawerDetent, .small)
        XCTAssertEqual(state.phase, .dashboard)
        state.beginCapture()
        state.showReview()
        state.cancelReviewOrCapture()
        XCTAssertEqual(state.phase, .dashboard)
        XCTAssertTrue(state.isDrawerVisible)
        state.collapseDrawer()
        XCTAssertEqual(state.phase, .cameraFirst)
        XCTAssertEqual(state.drawerDetent, .small)
        XCTAssertFalse(state.isDrawerVisible)
        state.showExistingCounts()
        XCTAssertTrue(state.isDrawerVisible)
        state.rescan()
        XCTAssertEqual(state.phase, .cameraFirst)
        XCTAssertFalse(state.isDrawerVisible)
        state.reset()
        XCTAssertFalse(state.isDrawerVisible)
    }

    func testDiagnosticShareDeclaresFiveDirectPipelineFiles() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let payload = TrackerReviewPayload(
            evidence: evidence([tile(.m(1), status: .confirmed)]),
            previewImage: image,
            image: image,
            detectorInputImage: image,
            canonicalData: nil,
            canonicalFormat: "JPEG",
            recognitionROI: nil
        )

        let names = Set(TrackerDiagnosticExport.shareItems(for: payload).map(\.fileName))

        XCTAssertEqual(names, ["diagnostics.json", "preview.jpg", "canonical.jpg",
                               "detector-input.jpg", "detections.jpg"])
    }

    func testDiagnosticSharePreservesAnOriginalHEIC() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let original = Data([0, 1, 2, 3])
        let payload = TrackerReviewPayload(
            evidence: evidence([tile(.m(1), status: .confirmed)]),
            previewImage: image, image: image, detectorInputImage: image,
            canonicalData: original, canonicalFormat: "HEIC", recognitionROI: nil
        )

        let canonical = try XCTUnwrap(
            TrackerDiagnosticExport.shareItems(for: payload)
                .first { $0.fileName.hasPrefix("canonical.") }
        )

        XCTAssertEqual(canonical.fileName, "canonical.heic")
        XCTAssertEqual(canonical.data, original)
    }

    private func evidence(_ tiles: [TrackerTileEvidence]) -> TrackerScanEvidence {
        TrackerScanEvidence(canonicalFrameID: FrameID(1), tiles: tiles)
    }

    private func tile(_ face: Tile, status: TrackerEvidenceStatus,
                      confidence: Double = 0.9) -> TrackerTileEvidence {
        let reason: TrackerFusionDecisionReason = status == .confirmed
            ? .autoConfirmed : .belowAutoConfirmThreshold
        return TrackerTileEvidence(
            box: TileBoundingBox(x: 0.1, y: 0.2, width: 0.08, height: 0.14),
            faceSuggestion: .tile(face),
            detectionConfidence: confidence,
            status: status,
            decisionReason: reason
        )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func fixtureURL(named name: String, extension fileExtension: String) throws
        -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: fileExtension,
            subdirectory: "Fixtures"
        ) ?? Bundle(for: Self.self).url(forResource: name,
                                       withExtension: fileExtension))
    }

    private func fixtureImage(named name: String, extension fileExtension: String) throws
        -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            try fixtureURL(named: name, extension: fileExtension) as CFURL, nil
        ))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                      width: image.width, height: image.height))
        return pixels
    }

    private func setRow(_ tensor: MLMultiArray, row: Int, values: [Float]) {
        for (column, value) in values.enumerated() {
            tensor[row * 6 + column] = NSNumber(value: value)
        }
    }
}

private struct ReferenceExpectation: Decodable {
    var detectionCount: Int
    var autoConfirmCount: Int
    var modelVersion: String
    var histogram: [String: Int]
}

private actor DirectDetectorProbe: TrackerDirectDetecting {
    private var prepareCalls = 0
    private var detectCalls = 0
    let image: CGImage
    let detections: [TrackerDirectDetection]

    init(image: CGImage,
         detections: [TrackerDirectDetection] = [.init(
            label: "1m", confidence: 0.9,
            box: TileBoundingBox(x: 0.1, y: 0.1, width: 0.1, height: 0.2)
         )]) {
        self.image = image
        self.detections = detections
    }

    var values: (prepare: Int, detect: Int) { (prepareCalls, detectCalls) }

    func prepare() async throws { prepareCalls += 1 }

    func detect(_ image: CGImage) async throws -> TrackerDirectDetectionResult {
        detectCalls += 1
        return TrackerDirectDetectionResult(
            detections: detections,
            descriptor: .init(inputName: "image", outputName: "output"),
            letterbox: .init(sourceSize: CGSize(width: image.width,
                                                height: image.height)),
            detectorInputImage: self.image,
            rawTensorRowCount: 300,
            positiveCandidateCount: detections.count,
            validBoxCount: detections.count,
            unmappedLabelCount: 0,
            timings: .init(letterboxRendering: 0, inference: 0,
                           tensorDecode: 0, nms: 0)
        )
    }
}
