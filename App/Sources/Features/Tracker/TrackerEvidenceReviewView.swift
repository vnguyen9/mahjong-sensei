import SwiftUI
import UIKit
import DesignSystem
import MahjongCore
import MahjongData
import Recognition
#if DEBUG
import UniformTypeIdentifiers
#endif

struct TrackerEvidenceReviewView: View {
    @Environment(AppState.self) private var app

    let payload: TrackerReviewPayload
    let tracker: TrackerSession
    let onApplied: (Set<Int>) -> Void
    let onCancel: () -> Void

    @State private var draft: TrackerReviewDraft
    @State private var editTarget: EditTarget?
    @State private var addingTile = false
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var errorMessage: String?
    #if DEBUG
    @State private var showingDiagnostics = false
    @State private var showDiscardedDetections = false
    @State private var discardedTarget: TrackerDiscardedTileEvidence?
    #endif

    init(payload: TrackerReviewPayload, tracker: TrackerSession,
         onApplied: @escaping (Set<Int>) -> Void,
         onCancel: @escaping () -> Void) {
        self.payload = payload
        self.tracker = tracker
        self.onApplied = onApplied
        self.onCancel = onCancel
        _draft = State(initialValue: TrackerReviewDraft(
            evidence: payload.evidence,
            hand: tracker.hand
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                evidenceCanvas
                reviewSummary
            }
            .background(Color(.systemBackground))
            .navigationTitle("Review Tiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    #if DEBUG
                    if app.trackerDeveloperMode {
                        Button {
                            showingDiagnostics = true
                        } label: {
                            Label("Tracker Diagnostics", systemImage: "ladybug")
                        }
                        .accessibilityHint("Shows photo, model, crop, timing, and confidence details for this scan.")
                    }
                    #endif
                    Button {
                        addingTile.toggle()
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Label(addingTile ? "Cancel Add" : "Add Tile",
                              systemImage: addingTile ? "xmark" : "plus")
                    }
                    .accessibilityHint(addingTile
                        ? "Stops placing a missing tile."
                        : "Then tap the photo where a tile is missing.")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .sheet(item: $editTarget) { target in
            TrackerEvidenceEditor(
                crop: crop(for: target),
                current: currentFace(for: target),
                evidenceExplanation: evidenceExplanation(for: target),
                isAdding: target.isAdding,
                isSuggestion: isSuggestion(for: target),
                diagnostics: tileDiagnostics(for: target),
                showsDeveloperDiagnostics: developerModeEnabled,
                onTile: { tile in resolve(target, as: .tile(tile)) },
                onBack: { resolve(target, as: .back) },
                onExclude: target.existingID.map { id in
                    { draft.exclude(id); editTarget = nil }
                }
            )
            .presentationDetents([.large])
            .presentationBackground(.clear)
        }
        #if DEBUG
        .sheet(isPresented: $showingDiagnostics) {
            TrackerScanDiagnosticsView(
                payload: payload,
                showDiscardedDetections: $showDiscardedDetections
            )
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $discardedTarget) { discarded in
            TrackerDiscardedDiagnosticsView(
                discarded: discarded,
                initialCrop: nil,
                finalCrop: crop(image: payload.image,
                                box: discarded.tile.diagnostics.sourceBox)
            )
            .presentationDetents([.medium, .large])
        }
        #endif
        .alert("Counts not applied", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please review the evidence.")
        }
        #if DEBUG
        .onDisappear {
            TrackerDiagnosticExport.cleanup(scanID: payload.evidence.scanID)
        }
        #endif
    }

    private var evidenceCanvas: some View {
        GeometryReader { proxy in
            let imageRect = aspectFitRect(imageSize: payload.image.size, in: proxy.size)
            ZStack {
                Image(uiImage: payload.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityLabel("Frozen table scan with \(draft.tiles.count) marked tiles")

                ForEach(draft.tiles) { tile in
                    marker(tile, imageRect: imageRect)
                }
                #if DEBUG
                if developerModeEnabled && showDiscardedDetections {
                    ForEach(payload.evidence.discardedTiles) { discarded in
                        discardedMarker(discarded, imageRect: imageRect)
                    }
                }
                #endif
            }
            .scaleEffect(zoom)
            .offset(offset)
            .contentShape(Rectangle())
            // Add-mode's spatial tap must coexist with marker buttons and the
            // standard zoom/pan gestures instead of swallowing their taps.
            .simultaneousGesture(addGesture(imageRect: imageRect))
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                zoom = min(5, max(1, settledZoom * value.magnification))
            }.onEnded { _ in
                settledZoom = zoom
                if zoom == 1 { offset = .zero; settledOffset = .zero }
            })
            .simultaneousGesture(DragGesture().onChanged { value in
                guard zoom > 1 else { return }
                offset = CGSize(width: settledOffset.width + value.translation.width,
                                height: settledOffset.height + value.translation.height)
            }.onEnded { _ in settledOffset = offset })
            .clipped()
            .overlay(alignment: .top) {
                if addingTile {
                    Label("Tap the missing tile", systemImage: "hand.tap")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .frame(minHeight: 300)
    }

    #if DEBUG
    private func discardedMarker(_ discarded: TrackerDiscardedTileEvidence,
                                 imageRect: CGRect) -> some View {
        let box = discarded.tile.box
        let rect = CGRect(
            x: imageRect.minX + box.x * imageRect.width,
            y: imageRect.minY + box.y * imageRect.height,
            width: box.width * imageRect.width,
            height: box.height * imageRect.height
        )
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            discardedTarget = discarded
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.purple,
                              style: StrokeStyle(lineWidth: 3, dash: [2, 4]))
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.purple.opacity(0.10))
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 22, height: 22)
                        .background(Color.purple, in: Circle())
                        .offset(x: 9, y: -9)
                }
        }
        .buttonStyle(.plain)
        .frame(width: max(44, rect.width), height: max(44, rect.height))
        .position(x: rect.midX, y: rect.midY)
        .accessibilityLabel("Discarded detection")
        .accessibilityValue("Detection confidence \(decimal(discarded.tile.detectionConfidence))")
        .accessibilityHint("Opens read-only developer diagnostics.")
    }
    #endif

    @ViewBuilder
    private func marker(_ tile: TrackerDraftTile, imageRect: CGRect) -> some View {
        let rect = CGRect(
            x: imageRect.minX + tile.box.x * imageRect.width,
            y: imageRect.minY + tile.box.y * imageRect.height,
            width: tile.box.width * imageRect.width,
            height: tile.box.height * imageRect.height
        )
        Button {
            guard !addingTile else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            editTarget = .existing(tile.id)
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(markerColor(tile),
                              style: StrokeStyle(lineWidth: tile.status == .needsReview ? 3 : 2,
                                                 dash: markerIsDashed(tile) ? [6, 4] : []))
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(markerColor(tile).opacity(tile.isExcluded ? 0.22 : 0.08))
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: markerSymbol(tile.status))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 22, height: 22)
                        .background(markerColor(tile), in: Circle())
                        .offset(x: 9, y: -9)
                }
                .overlay {
                    if tile.isExcluded {
                        Rectangle().fill(Color.red).frame(height: 2).rotationEffect(.degrees(-25))
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: max(44, rect.width), height: max(44, rect.height))
        .position(x: rect.midX, y: rect.midY)
        .accessibilityLabel(accessibilityLabel(tile))
        .accessibilityValue(statusLabel(tile.status))
        .accessibilityHint("Opens face and removal controls for this physical tile.")
    }

    private var reviewSummary: some View {
        let projection = draft.applicationProjection(hand: tracker.hand)
        return VStack(spacing: 12) {
            HStack {
                Label("\(draft.confirmedCount) confirmed", systemImage: "checkmark.circle")
                Spacer()
                Label("\(draft.unresolvedCount) need review", systemImage: "questionmark.circle")
                    .foregroundStyle(draft.unresolvedCount == 0 ? Color.green : Color.orange)
            }
            .font(.subheadline.weight(.semibold))

            if draft.unresolvedCount > 0 {
                reviewCards
            }

            TileCountGrid(
                histogram: projection.histogram,
                handHistogram: tracker.handHistogram,
                tileWidthCap: UIDevice.current.userInterfaceIdiom == .pad ? 36 : 30,
                showHonorCaptions: true,
                onTap: { _ in }
            )
            .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 220 : 180)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Proposed tile count grid")

            if !projection.suggestedEvidenceIDs.isEmpty
                || !projection.skippedEvidenceIDs.isEmpty {
                Text(applicationSummary(projection))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if draft.nonPoolEvidenceCount > 0 {
                Label("\(draft.nonPoolEvidenceCount) bonus or face-down tile\(draft.nonPoolEvidenceCount == 1 ? "" : "s") — not included in the 136-tile pool",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !draft.violatingIDs(hand: tracker.hand).isEmpty {
                Label("Some faces exceed the available copies", systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Apply Counts") {
                do {
                    let changed = try tracker.apply(draft)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onApplied(changed)
                } catch {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    errorMessage = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!projection.canApply)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var reviewCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Needs Review")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(draft.tiles.filter {
                        $0.status == .needsReview && !$0.isExcluded
                    }) { tile in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            editTarget = .existing(tile.id)
                        } label: {
                            TrackerReviewTileCard(
                                crop: crop(image: payload.image, box: tile.box),
                                suggestion: faceName(tile.face)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(faceName(tile.face).map {
                            "Review tile, suggested \($0)"
                        } ?? "Review tile, no suggestion")
                        .accessibilityHint("Opens tile correction controls.")
                    }
                }
            }
        }
    }

    private func faceName(_ face: TileFace?) -> String? {
        switch face {
        case .tile(let tile): return MahjongData.name(for: tile).english
        case .back: return "Face-down tile"
        case nil: return nil
        }
    }

    private func applicationSummary(_ projection: TrackerReviewApplicationProjection) -> String {
        let suggested = projection.suggestedEvidenceIDs.count
        let skipped = projection.skippedEvidenceIDs.count
        if skipped == 0 {
            return "Apply will use \(suggested) system suggestion\(suggested == 1 ? "" : "s")."
        }
        if suggested == 0 {
            return "Apply will skip \(skipped) tile\(skipped == 1 ? "" : "s") without a suggestion."
        }
        return "Apply will use \(suggested) suggestion\(suggested == 1 ? "" : "s") and skip \(skipped) tile\(skipped == 1 ? "" : "s") without a suggestion."
    }

    private func addGesture(imageRect: CGRect) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard addingTile, imageRect.contains(value.location) else { return }
            let point = CGPoint(x: (value.location.x - imageRect.minX) / imageRect.width,
                                y: (value.location.y - imageRect.minY) / imageRect.height)
            editTarget = .add(point)
            addingTile = false
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func resolve(_ target: EditTarget, as face: TileFace) {
        switch target {
        case .existing(let id): draft.resolve(id, as: face)
        case .add(let point): _ = draft.add(face: face, centeredAt: point)
        }
        editTarget = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func currentFace(for target: EditTarget) -> TileFace? {
        guard case let .existing(id) = target else { return nil }
        return draft.tiles.first { $0.id == id }?.face
    }

    private func evidenceExplanation(for target: EditTarget) -> String {
        guard case let .existing(id) = target,
              let evidence = payload.evidence.tiles.first(where: { $0.id == id }) else {
            return "Manually added evidence. Choose the physical tile's face."
        }
        let decision = draft.tiles.first { $0.id == id }?.decisionReason
            ?? evidence.decisionReason
        if let suggestion = evidence.faceSuggestion {
            let name: String
            switch suggestion {
            case .tile(let tile): name = MahjongData.name(for: tile).english
            case .back: name = "Face-down tile"
            }
            switch decision {
            case .conservationViolation:
                return "This suggestion exceeds the available copies. Verify \(name) or choose another face."
            default:
                return "Suggested \(name)."
            }
        }
        switch decision {
        case .unmappedLabel, .invalidOutput, .modelFailure:
            return "No confident face suggestion. Choose the face below."
        default:
            return "No confident face suggestion. Choose the face below."
        }
    }

    private func isSuggestion(for target: EditTarget) -> Bool {
        guard case let .existing(id) = target,
              let evidence = payload.evidence.tiles.first(where: { $0.id == id }) else {
            return false
        }
        return evidence.status == .needsReview && evidence.faceSuggestion != nil
    }

    private func tileDiagnostics(for target: EditTarget) -> TrackerTileDiagnostics? {
        guard case let .existing(id) = target else { return nil }
        guard var diagnostics = payload.evidence.tiles.first(where: { $0.id == id })?
            .diagnostics else { return nil }
        if let decision = draft.tiles.first(where: { $0.id == id })?.decisionReason {
            diagnostics.decisionReason = decision
        }
        return diagnostics
    }

    private var developerModeEnabled: Bool {
        #if DEBUG
        app.trackerDeveloperMode
        #else
        false
        #endif
    }

    private func crop(for target: EditTarget) -> UIImage? {
        guard case let .existing(id) = target,
              let box = draft.tiles.first(where: { $0.id == id })?.box else { return nil }
        return crop(image: payload.image, box: box)
    }

    private func crop(image: UIImage?, box: TileBoundingBox?) -> UIImage? {
        guard let image, let box else { return nil }
        let oriented = image.imageOrientation == .up ? image
            : UIGraphicsImageRenderer(size: image.size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        guard let cgImage = oriented.cgImage else { return nil }
        let expanded = RecognizerFrameCropper.expanded(box, by: 0.12)
        let rect = CGRect(x: expanded.x * Double(cgImage.width),
                          y: expanded.y * Double(cgImage.height),
                          width: expanded.width * Double(cgImage.width),
                          height: expanded.height * Double(cgImage.height)).integral
        guard let crop = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop)
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func markerColor(_ tile: TrackerDraftTile) -> Color {
        switch tile.status {
        case .confirmed: return .green
        case .needsReview: return .orange
        case .userCorrected, .manuallyAdded: return .yellow
        case .excluded: return .red
        }
    }

    private func markerIsDashed(_ tile: TrackerDraftTile) -> Bool {
        guard tile.status == .needsReview else { return false }
        return true
    }

    private func markerSymbol(_ status: TrackerEvidenceStatus) -> String {
        switch status {
        case .confirmed: return "checkmark"
        case .needsReview: return "questionmark"
        case .userCorrected: return "pencil"
        case .manuallyAdded: return "plus"
        case .excluded: return "minus"
        }
    }

    private func statusLabel(_ status: TrackerEvidenceStatus) -> String {
        switch status {
        case .confirmed: return "Confirmed"
        case .needsReview: return "Needs review"
        case .userCorrected: return "User corrected"
        case .manuallyAdded: return "Manually added"
        case .excluded: return "Excluded"
        }
    }

    private func accessibilityLabel(_ tile: TrackerDraftTile) -> String {
        switch tile.face {
        case .tile(let face): return MahjongData.name(for: face).english
        case .back: return "Face-down tile"
        case nil: return "Unknown tile"
        }
    }

    private enum EditTarget: Identifiable {
        case existing(UUID)
        case add(CGPoint)

        var id: String {
            switch self {
            case .existing(let id): return "existing-\(id)"
            case .add(let point): return "add-\(point.x)-\(point.y)"
            }
        }
        var existingID: UUID? { if case .existing(let id) = self { return id }; return nil }
        var isAdding: Bool { if case .add = self { return true }; return false }
    }
}

private struct TrackerReviewTileCard: View {
    let crop: UIImage?
    let suggestion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if let crop {
                    Image(uiImage: crop)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 94, height: 68)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .clipped()

            Text(suggestion.map { "Suggested \($0)" } ?? "No suggestion")
                .font(.caption.weight(.semibold))
                .foregroundStyle(suggestion == nil ? Color.orange : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 118, alignment: .leading)
        }
        .padding(9)
        .frame(minHeight: 118, alignment: .topLeading)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.65), lineWidth: 1)
        }
    }
}

private struct TrackerEvidenceEditor: View {
    let crop: UIImage?
    let current: TileFace?
    let evidenceExplanation: String
    let isAdding: Bool
    let isSuggestion: Bool
    let diagnostics: TrackerTileDiagnostics?
    let showsDeveloperDiagnostics: Bool
    let onTile: (Tile) -> Void
    let onBack: () -> Void
    let onExclude: (() -> Void)?

    @State private var suit: SuitTab
    @State private var selection: Tile

    init(crop: UIImage?, current: TileFace?, evidenceExplanation: String, isAdding: Bool,
         isSuggestion: Bool, diagnostics: TrackerTileDiagnostics?,
         showsDeveloperDiagnostics: Bool,
         onTile: @escaping (Tile) -> Void, onBack: @escaping () -> Void,
         onExclude: (() -> Void)?) {
        self.crop = crop
        self.current = current
        self.evidenceExplanation = evidenceExplanation
        self.isAdding = isAdding
        self.isSuggestion = isSuggestion
        self.diagnostics = diagnostics
        self.showsDeveloperDiagnostics = showsDeveloperDiagnostics
        self.onTile = onTile
        self.onBack = onBack
        self.onExclude = onExclude
        let start: Tile
        if case let .tile(tile)? = current { start = tile } else { start = .m(1) }
        _selection = State(initialValue: start)
        _suit = State(initialValue: SuitTab(for: start))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let crop {
                        Image(uiImage: crop)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Detected tile crop")
                    }
                    Text(evidenceExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TileFaceSelectionGrid(suit: $suit, selection: $selection)

                    if selection.isBonus || current == .back {
                        Label("Physical evidence; not included in the 136-tile pool",
                              systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("\(isSuggestion ? "Accept" : "Use") \(MahjongData.name(for: selection).english)") {
                        onTile(selection)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)

                    Button(action: onBack) {
                        Label("Face-down tile", systemImage: "rectangle.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)

                    #if DEBUG
                    if showsDeveloperDiagnostics, let diagnostics {
                        TrackerTileDiagnosticsSection(diagnostics: diagnostics)
                    }
                    #endif

                    if let onExclude {
                        Button(role: .destructive, action: onExclude) {
                            Label("Not a tile", systemImage: "trash")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemBackground))
            .navigationTitle(isAdding ? "Add Missing Tile" : "Review Tile")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

private func decimal<T: BinaryFloatingPoint>(_ value: T) -> String {
    String(format: "%.3f", Double(value))
}
