#if DEBUG
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import DesignSystem
import MahjongData
import Recognition

struct TrackerScanDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: TrackerReviewPayload
    @Binding var showDiscardedDetections: Bool

    @State private var showOutsideGuide = false
    @State private var copied = false
    @State private var shareItems: [TrackerDiagnosticShareItem] = []

    private var evidence: TrackerScanEvidence { payload.evidence }
    private var diagnostics: TrackerScanDiagnostics { evidence.diagnostics }
    private var isLiveMedium: Bool {
        diagnostics.detector.resourceName == TrackerLiveDetectorPolicy.resourceName
    }

    var body: some View {
        NavigationStack {
            List {
                imageSection
                modelSection
                if !isLiveMedium { letterboxSection }
                timingSection
                detectorSection
                resultSection
                thresholdSection
                reviewSection
                shareSection
            }
            .navigationTitle("Tracker Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: copyJSON) {
                        Label(copied ? "Copied" : "Copy JSON",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityHint("Copies scalar diagnostics without images or file paths.")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { shareItems = TrackerDiagnosticExport.shareItems(for: payload) }
    }

    private var imageSection: some View {
        Section("Images") {
            if let preview = payload.previewImage {
                diagnosticImage(title: "Latest preview · diagnostics only",
                                image: preview, overlays: [], roi: nil)
            }
            diagnosticImage(
                title: "Canonical still · \(diagnostics.cameraProfile)",
                image: payload.image,
                overlays: canonicalOverlays,
                roi: diagnostics.recognitionROI
            )
            if let detectorInput = payload.detectorInputImage {
                diagnosticImage(title: "Prepared detector input · 640 × 640",
                                image: detectorInput, overlays: [], roi: nil)
            }
            if !evidence.discardedTiles.isEmpty {
                Toggle("Show \(evidence.discardedTiles.count) below \(decimal(diagnostics.displayFloor))",
                       isOn: $showDiscardedDetections)
                    .accessibilityHint("Shows purple inspect-only detector boxes.")
            }
            if !evidence.outsideGuideDetections.isEmpty {
                Toggle("Show \(evidence.outsideGuideDetections.count) outside guide",
                       isOn: $showOutsideGuide)
                    .accessibilityHint("Shows gray boxes excluded by the framing guide.")
            }
        }
    }

    private var modelSection: some View {
        Section("Model and Capture") {
            row("Device", diagnostics.deviceClass)
            row("Actual camera", diagnostics.cameraProfile)
            row("Frozen frame", "\(evidence.canonicalFrameID.value)")
            row("App model", diagnostics.detector.resourceName)
            row("Embedded model", diagnostics.detector.embeddedName)
            row("Model version", diagnostics.detector.embeddedVersion)
            row("Recognition mode", isLiveMedium
                ? "Live 43-class Medium detector"
                : "One-pass 43-class detector")
            row("Core ML input", diagnostics.detector.inputName)
            row("Core ML output", diagnostics.detector.outputName)
            row("Preview", "\(diagnostics.previewPixelWidth) × \(diagnostics.previewPixelHeight) px")
            row("Canonical", "\(diagnostics.canonicalPixelWidth) × \(diagnostics.canonicalPixelHeight) px")
            row("Format", diagnostics.canonicalFormat)
            row(isLiveMedium ? "Frame source" : "Photo priority",
                diagnostics.photoQualityPriority)
            row("Guide", diagnostics.recognitionROI.map(boxString) ?? "Full photo")
            row("Photo requests", isLiveMedium ? "0" : "1")
            row("Orientation", diagnostics.canonicalOrientation)
        }
    }

    private var letterboxSection: some View {
        let value = diagnostics.letterbox
        return Section("Ultralytics Letterbox") {
            row("Source", "\(value.sourcePixelWidth) × \(value.sourcePixelHeight)")
            row("Resized", "\(value.resizedPixelWidth) × \(value.resizedPixelHeight)")
            row("Model input", "\(value.inputPixelSize) × \(value.inputPixelSize)")
            row("Scale", decimal(value.scale))
            row("Padding L · T · R · B",
                "\(value.leftPadding) · \(value.topPadding) · \(value.rightPadding) · \(value.bottomPadding)")
            row("Padding RGB", "\(value.paddingValue), \(value.paddingValue), \(value.paddingValue)")
            row("Interpolation", value.interpolation)
            Text("The upright full photo is resized once and centered on the gray canvas. Vision scaling is not used.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var timingSection: some View {
        let value = diagnostics.timings
        return Section("Stage Timings") {
            row("Camera readiness", seconds(value.cameraReadiness))
            row("Photo delivery", seconds(value.photoDelivery))
            row("Model preparation", "\(seconds(value.modelPreparation)) · \(value.modelWasCold ? "cold" : "warm")")
            row("Orientation", seconds(value.orientationRendering))
            row("Letterbox rendering", seconds(value.letterboxRendering))
            row(isLiveMedium ? "Medium inference" : "Detector inference",
                seconds(value.detectorInference))
            row("Tensor decode", seconds(value.tensorDecode))
            row("Class-agnostic NMS", seconds(value.nms))
            row("Guide filtering", seconds(value.guideFiltering))
            row("Review preparation", seconds(value.reviewPreparation))
            row("Tap to review", seconds(value.total))
        }
    }

    private var detectorSection: some View {
        let value = diagnostics.detectorPass
        return Section(isLiveMedium ? "Live Medium Detector" : "Direct Detector") {
            row("Tensor rows", "\(value.rawTensorRowCount)")
            if isLiveMedium {
                row("Retained at decode floor", "\(value.nmsAcceptedCount)")
                row("Shown in review", "\(value.insideGuideCount)")
            } else {
                row("Positive candidates", "\(value.positiveCandidateCount)")
                row("Valid boxes", "\(value.validBoxCount)")
                row("After NMS", "\(value.nmsAcceptedCount)")
                row("Inside guide", "\(value.insideGuideCount)")
                row("Outside guide", "\(value.outsideGuideCount)")
            }
            row("Unmapped labels", "\(value.unmappedLabelCount)")
        }
    }

    private var resultSection: some View {
        Section("Recognition Results") {
            row("Auto-confirmed", "\(diagnostics.confirmedTileCount)")
            row("Review with suggestion", "\(diagnostics.suggestionTileCount)")
            row("Review without suggestion", "\(diagnostics.reviewWithoutSuggestionTileCount)")
            row("Discarded below \(decimal(diagnostics.displayFloor))",
                "\(diagnostics.discardedBelowDisplayFloorCount)")
            row("Conservation violations", "\(diagnostics.conservationViolationCount)")
            ForEach(diagnostics.decisionCounts, id: \.name) {
                row(readable($0.name), "\($0.count)")
            }
            ForEach(diagnostics.confidenceBandCounts, id: \.name) {
                row($0.name, "\($0.count)")
            }
        }
    }

    private var thresholdSection: some View {
        Section("Thresholds") {
            row("Display floor", decimal(diagnostics.displayFloor))
            row("Suggestion", decimal(diagnostics.suggestionThreshold))
            row("Auto-confirm", decimal(diagnostics.autoConfirmThreshold))
            row("NMS IoU", decimal(diagnostics.nmsIoUThreshold))
            Text("Threshold comparisons use the unrounded detector value.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        let needsReview = evidence.tiles.filter { $0.status == .needsReview }
        if !needsReview.isEmpty {
            Section("Needs Review Analysis") {
                ForEach(needsReview) { tile in
                    TrackerNeedsReviewDiagnosticRow(tile: tile,
                                                    canonicalImage: payload.image)
                }
            }
        }
    }

    private var shareSection: some View {
        Section("Share Diagnostics") {
            Text("Includes captured table photos. Nothing is uploaded automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ShareLink(items: shareItems, preview: { SharePreview($0.fileName) }) {
                Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(shareItems.count != 5)
            .accessibilityHint("Shares JSON, preview, frozen detector frame, detector source, and annotated detections.")
        }
    }

    private var canonicalOverlays: [TrackerDiagnosticOverlay] {
        var values = evidence.tiles.map { tile in
            TrackerDiagnosticOverlay(
                box: tile.box,
                color: tile.status == .confirmed ? .green : .orange,
                dashed: tile.status != .confirmed
            )
        }
        if showDiscardedDetections {
            values += evidence.discardedTiles.map {
                TrackerDiagnosticOverlay(box: $0.tile.box, color: .purple, dashed: true)
            }
        }
        if showOutsideGuide {
            values += evidence.outsideGuideDetections.map {
                TrackerDiagnosticOverlay(box: $0.box, color: .gray, dashed: true)
            }
        }
        return values
    }

    private func diagnosticImage(title: String, image: UIImage,
                                 overlays: [TrackerDiagnosticOverlay],
                                 roi: TileBoundingBox?) -> some View {
        TrackerDiagnosticImage(title: title, image: image,
                               overlays: overlays, roi: roi)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).font(.body.monospacedDigit()) }
    }

    private func copyJSON() {
        UIPasteboard.general.string = TrackerDiagnosticsExporter.jsonString(for: evidence)
        copied = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

private struct TrackerDiagnosticOverlay: Identifiable {
    let id = UUID()
    var box: TileBoundingBox
    var color: Color
    var dashed: Bool
}

private struct TrackerDiagnosticImage: View {
    let title: String
    let image: UIImage
    let overlays: [TrackerDiagnosticOverlay]
    let roi: TileBoundingBox?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            GeometryReader { proxy in
                let imageRect = aspectFitRect(image.size, in: proxy.size)
                ZStack {
                    Image(uiImage: image)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    ForEach(overlays) { overlay in
                        outline(overlay.box, in: imageRect, color: overlay.color,
                                dashed: overlay.dashed)
                    }
                    if let roi {
                        outline(roi, in: imageRect, color: .yellow, dashed: true)
                    }
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(title)
        }
    }

    private func outline(_ box: TileBoundingBox, in imageRect: CGRect,
                         color: Color, dashed: Bool) -> some View {
        let rect = normalizedRect(box, in: imageRect)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(color, style: StrokeStyle(lineWidth: 2,
                                              dash: dashed ? [5, 3] : []))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct TrackerNeedsReviewDiagnosticRow: View {
    let tile: TrackerTileEvidence
    let canonicalImage: UIImage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(readable(tile.decisionReason.rawValue))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(decimal(tile.detectionConfidence))
                    .font(.subheadline.monospacedDigit())
            }
            if let crop = cropImage(canonicalImage, box: tile.box) {
                Image(uiImage: crop)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity).frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            LabeledContent("Raw label", value: tile.diagnostics.detectorLabel)
            LabeledContent("Source box", value: boxString(tile.box))
        }
        .font(.caption)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct TrackerDiscardedDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    let discarded: TrackerDiscardedTileEvidence
    let initialCrop: UIImage?
    let finalCrop: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let finalCrop {
                        Image(uiImage: finalCrop)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity).frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Label("Inspect only — excluded from counts and Apply",
                          systemImage: "xmark.circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.purple)
                    Text("Detection confidence \(decimal(discarded.tile.detectionConfidence)) is below the \(decimal(discarded.threshold)) display floor.")
                    TrackerTileDiagnosticsSection(diagnostics: discarded.tile.diagnostics)
                }
                .padding(20)
            }
            .navigationTitle("Discarded Detection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct TrackerTileDiagnosticsSection: View {
    let diagnostics: TrackerTileDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Developer Diagnostics", systemImage: "ladybug")
                .font(.headline)
            line("Raw detector label", diagnostics.detectorLabel)
            line("Detection confidence", decimal(diagnostics.detectionConfidence))
            line("Inside guide", diagnostics.insideGuide ? "Yes" : "No")
            line("Source box", boxString(diagnostics.sourceBox))
            line("Decision", readable(diagnostics.decisionReason.rawValue))
        }
        .font(.footnote)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.footnote.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}

struct TrackerDiagnosticShareItem: Identifiable, Transferable {
    var id: String { fileName }
    var scanID: UUID
    var fileName: String
    var data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try TrackerDiagnosticExport.write(item))
        }
    }
}

enum TrackerDiagnosticExport {
    private static let folderName = "MahjongSensei-TrackerDiagnostics"

    @MainActor
    static func shareItems(for payload: TrackerReviewPayload)
        -> [TrackerDiagnosticShareItem] {
        let id = payload.evidence.scanID
        let preview = payload.previewImage ?? payload.image
        let detectorInput = payload.detectorInputImage ?? payload.image
        let detections = annotatedDetections(payload)
        let sharesOriginalHEIC = payload.canonicalFormat.uppercased() == "HEIC"
            && payload.canonicalData?.isEmpty == false
        let canonicalFileName = sharesOriginalHEIC ? "canonical.heic" : "canonical.jpg"
        let canonicalData = sharesOriginalHEIC
            ? payload.canonicalData ?? Data()
            : normalized(payload.image).jpegData(compressionQuality: 0.94) ?? Data()
        return [
            .init(scanID: id, fileName: "diagnostics.json",
                  data: Data(TrackerDiagnosticsExporter.jsonString(
                    for: payload.evidence
                  ).utf8)),
            .init(scanID: id, fileName: "preview.jpg",
                  data: normalized(preview).jpegData(compressionQuality: 0.88) ?? Data()),
            .init(scanID: id, fileName: canonicalFileName, data: canonicalData),
            .init(scanID: id, fileName: payload.detectorInputImage == nil
                  ? "detector-frame.jpg" : "detector-input.jpg",
                  data: normalized(detectorInput).jpegData(compressionQuality: 0.94) ?? Data()),
            .init(scanID: id, fileName: "detections.jpg",
                  data: detections.jpegData(compressionQuality: 0.92) ?? Data()),
        ]
    }

    static func write(_ item: TrackerDiagnosticShareItem) throws -> URL {
        let directory = root.appendingPathComponent(item.scanID.uuidString,
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        let url = directory.appendingPathComponent(item.fileName)
        try item.data.write(to: url, options: .atomic)
        return url
    }

    static func cleanup(scanID: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(
            scanID.uuidString, isDirectory: true
        ))
    }

    static func purgeAbandonedExports(now: Date = Date()) {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories {
            let modified = (try? directory.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > 3_600 {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(folderName, isDirectory: true)
    }

    @MainActor
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        return UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    @MainActor
    private static func annotatedDetections(_ payload: TrackerReviewPayload) -> UIImage {
        let source = normalized(payload.image)
        let targetWidth: CGFloat = 1_200
        let targetSize = CGSize(width: targetWidth,
                                height: targetWidth * source.size.height / source.size.width)
        return UIGraphicsImageRenderer(size: targetSize).image { context in
            source.draw(in: CGRect(origin: .zero, size: targetSize))
            let cg = context.cgContext
            cg.setLineWidth(4)
            for tile in payload.evidence.tiles {
                cg.setStrokeColor((tile.status == .confirmed
                                   ? UIColor.systemGreen : UIColor.systemOrange).cgColor)
                cg.stroke(rect(tile.box, size: targetSize))
            }
            cg.setStrokeColor(UIColor.systemPurple.cgColor)
            for discarded in payload.evidence.discardedTiles {
                cg.stroke(rect(discarded.tile.box, size: targetSize))
            }
            if let roi = payload.recognitionROI {
                cg.setStrokeColor(UIColor.systemYellow.cgColor)
                cg.setLineDash(phase: 0, lengths: [12, 8])
                cg.stroke(rect(roi, size: targetSize))
            }
        }
    }

    private static func rect(_ box: TileBoundingBox, size: CGSize) -> CGRect {
        CGRect(x: box.x * size.width, y: box.y * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }
}

enum TrackerDiagnosticsExporter {
    static func jsonString(for evidence: TrackerScanEvidence) -> String {
        let scan = evidence.diagnostics
        let root: [String: Any] = [
            "scanID": evidence.scanID.uuidString,
            "canonicalFrameID": String(describing: evidence.canonicalFrameID),
            "scan": [
                "deviceClass": scan.deviceClass,
                "cameraProfile": scan.cameraProfile,
                "detector": [
                    "resourceName": scan.detector.resourceName,
                    "embeddedName": scan.detector.embeddedName,
                    "embeddedVersion": scan.detector.embeddedVersion,
                    "inputName": scan.detector.inputName,
                    "outputName": scan.detector.outputName,
                ],
                "previewPixels": ["width": scan.previewPixelWidth,
                                  "height": scan.previewPixelHeight],
                "canonicalPixels": ["width": scan.canonicalPixelWidth,
                                    "height": scan.canonicalPixelHeight],
                "canonicalFormat": scan.canonicalFormat,
                "photoQualityPriority": scan.photoQualityPriority,
                "recognitionROI": scan.recognitionROI.map(boxDictionary) ?? NSNull(),
                "photoRequestCount": scan.photoQualityPriority == "live video frame" ? 0 : 1,
                "captureTimestamp": scan.captureTimestamp,
                "canonicalOrientation": scan.canonicalOrientation,
                "letterbox": [
                    "sourceWidth": scan.letterbox.sourcePixelWidth,
                    "sourceHeight": scan.letterbox.sourcePixelHeight,
                    "resizedWidth": scan.letterbox.resizedPixelWidth,
                    "resizedHeight": scan.letterbox.resizedPixelHeight,
                    "inputSize": scan.letterbox.inputPixelSize,
                    "scale": scan.letterbox.scale,
                    "leftPadding": scan.letterbox.leftPadding,
                    "topPadding": scan.letterbox.topPadding,
                    "rightPadding": scan.letterbox.rightPadding,
                    "bottomPadding": scan.letterbox.bottomPadding,
                    "paddingValue": scan.letterbox.paddingValue,
                    "interpolation": scan.letterbox.interpolation,
                ],
                "detectorPass": [
                    "rawTensorRows": scan.detectorPass.rawTensorRowCount,
                    "positiveCandidates": scan.detectorPass.positiveCandidateCount,
                    "validBoxes": scan.detectorPass.validBoxCount,
                    "nmsAccepted": scan.detectorPass.nmsAcceptedCount,
                    "insideGuide": scan.detectorPass.insideGuideCount,
                    "outsideGuide": scan.detectorPass.outsideGuideCount,
                    "unmappedLabels": scan.detectorPass.unmappedLabelCount,
                ],
                "timings": timingDictionary(scan.timings),
                "confirmedTileCount": scan.confirmedTileCount,
                "reviewTileCount": scan.reviewTileCount,
                "suggestionTileCount": scan.suggestionTileCount,
                "reviewWithoutSuggestionTileCount": scan.reviewWithoutSuggestionTileCount,
                "discardedBelowDisplayFloorCount": scan.discardedBelowDisplayFloorCount,
                "conservationViolationCount": scan.conservationViolationCount,
                "decisionCounts": scan.decisionCounts.map {
                    ["name": $0.name, "count": $0.count]
                },
                "confidenceBands": scan.confidenceBandCounts.map {
                    ["name": $0.name, "count": $0.count]
                },
                "thresholds": [
                    "displayFloor": scan.displayFloor,
                    "suggestion": scan.suggestionThreshold,
                    "autoConfirm": scan.autoConfirmThreshold,
                    "nmsIoU": scan.nmsIoUThreshold,
                ],
            ],
            "tiles": evidence.tiles.enumerated().map {
                tileDictionary(index: $0.offset, tile: $0.element)
            },
            "discardedTiles": evidence.discardedTiles.enumerated().map {
                var value = tileDictionary(index: $0.offset, tile: $0.element.tile)
                value["discardReason"] = $0.element.reason.rawValue
                value["displayFloor"] = $0.element.threshold
                return value
            },
            "outsideGuideDetections": evidence.outsideGuideDetections.enumerated().map {
                detectionDictionary(index: $0.offset, detection: $0.element)
            },
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    private static func tileDictionary(index: Int,
                                       tile: TrackerTileEvidence) -> [String: Any] {
        [
            "index": index,
            "id": tile.id.uuidString,
            "status": tile.status.rawValue,
            "decision": tile.decisionReason.rawValue,
            "detectionConfidence": tile.detectionConfidence,
            "detectorLabel": tile.diagnostics.detectorLabel,
            "suggestion": tile.faceSuggestion.map(faceName) ?? NSNull(),
            "box": boxDictionary(tile.box),
        ]
    }

    private static func detectionDictionary(index: Int,
                                            detection: TrackerDirectDetection)
        -> [String: Any] {
        ["index": index, "label": detection.label,
         "confidence": detection.confidence,
         "box": boxDictionary(detection.box)]
    }

    private static func timingDictionary(_ value: TrackerStageTimingDiagnostics)
        -> [String: Any] {
        ["cameraReadiness": value.cameraReadiness,
         "photoDelivery": value.photoDelivery,
         "modelPreparation": value.modelPreparation,
         "modelWasCold": value.modelWasCold,
         "orientationRendering": value.orientationRendering,
         "letterboxRendering": value.letterboxRendering,
         "detectorInference": value.detectorInference,
         "tensorDecode": value.tensorDecode,
         "nms": value.nms,
         "guideFiltering": value.guideFiltering,
         "reviewPreparation": value.reviewPreparation,
         "total": value.total]
    }

    private static func boxDictionary(_ box: TileBoundingBox) -> [String: Double] {
        ["x": box.x, "y": box.y, "width": box.width, "height": box.height]
    }
}

private func aspectFitRect(_ imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(x: (container.width - size.width) / 2,
                  y: (container.height - size.height) / 2,
                  width: size.width, height: size.height)
}

private func normalizedRect(_ box: TileBoundingBox, in rect: CGRect) -> CGRect {
    CGRect(x: rect.minX + box.x * rect.width,
           y: rect.minY + box.y * rect.height,
           width: box.width * rect.width,
           height: box.height * rect.height)
}

private func cropImage(_ image: UIImage, box: TileBoundingBox) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }
    let padding = 0.12
    let expanded = TileBoundingBox(
        x: max(0, box.x - box.width * padding),
        y: max(0, box.y - box.height * padding),
        width: min(1, box.x + box.width * (1 + padding))
            - max(0, box.x - box.width * padding),
        height: min(1, box.y + box.height * (1 + padding))
            - max(0, box.y - box.height * padding)
    )
    let rect = CGRect(x: expanded.x * Double(cgImage.width),
                      y: expanded.y * Double(cgImage.height),
                      width: expanded.width * Double(cgImage.width),
                      height: expanded.height * Double(cgImage.height)).integral
    guard let crop = cgImage.cropping(to: rect) else { return nil }
    return UIImage(cgImage: crop)
}

private func seconds(_ value: TimeInterval) -> String {
    String(format: "%.3f s", value)
}

private func decimal<T: BinaryFloatingPoint>(_ value: T) -> String {
    String(format: "%.6f", Double(value))
}

private func readable(_ raw: String) -> String {
    raw.reduce(into: "") { result, character in
        if character.isUppercase && !result.isEmpty { result.append(" ") }
        result.append(character)
    }.capitalized
}

private func faceName(_ face: TileFace) -> String {
    switch face {
    case .tile(let tile): return MahjongData.name(for: tile).english
    case .back: return "Face-down tile"
    }
}

private func boxString(_ box: TileBoundingBox) -> String {
    "x \(decimal(box.x)), y \(decimal(box.y)), w \(decimal(box.width)), h \(decimal(box.height))"
}
#endif
