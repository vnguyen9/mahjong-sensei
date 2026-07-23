import SwiftUI
import UIKit
import ImageIO
import DesignSystem
import MahjongCore
import Recognition
import EfficiencyEngine
import CoachEngine

/// Full-camera Tracker chrome. Counts stay hidden until the user reveals an
/// existing game or applies a reviewed scan.
struct TrackerCard: View {
    @Environment(ScanCoordinator.self) private var coordinator
    @Environment(AppState.self) private var app
    @Environment(\.floatingDockClearance) private var floatingDockClearance
    let previewFrame: CGRect
    let reticleFrame: CGRect

    @State private var isBusy = false
    @State private var statsTile: TileSelection?
    @State private var editingHand = false
    @State private var handReview: TrackerHandReviewPayload?
    @State private var confirmingReset = false
    @State private var reviewPayload: TrackerReviewPayload?
    @State private var scanError: String?
    @State private var selectedLens: CameraLens = .wide
    @State private var liveDetector: TrackerLiveDetectorController?
    @State private var justChanged: Set<Tile> = []
    @State private var shotReadout: String?
    @State private var liveTuning = TrackerLiveTuning.defaults
    #if DEBUG
    @State private var showingLiveTuning = false
    #endif

    private var tracker: TrackerSession { coordinator.tracker }
    private var presentation: TrackerPresentationState {
        coordinator.trackerPresentation
    }

    private var liveVisibleDetections: [RawTileDetection] {
        guard let liveDetector else { return [] }
        let visible = liveDetector.detections.filter {
            $0.confidence >= TrackerLiveDetectorPolicy.reviewFloor
                && TileFace(detectorLabel: $0.label) != nil
        }
        guard let roi = guideROI(orientedImageSize: liveDetector.orientedImageSize) else {
            return []
        }
        return visible.filter { roi.containsCenter(of: $0.box) }
    }

    var body: some View {
        GeometryReader { proxy in
            let drawerHeight = presentation.isDrawerVisible
                ? CameraDrawerHeights.height(
                    for: presentation.drawerDetent,
                    availableHeight: max(320, proxy.size.height - floatingDockClearance),
                    isPad: UIDevice.current.userInterfaceIdiom == .pad
                )
                : 0
            ZStack(alignment: .bottom) {
                liveDetectionOverlay(canvasOrigin: proxy.frame(in: .global).origin)

                if presentation.isDrawerVisible && !isBusy {
                    trackerDrawer(height: drawerHeight)
                        .padding(.bottom, floatingDockClearance)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                captureControls
                    .padding(.bottom, presentation.isDrawerVisible && !isBusy
                             ? drawerHeight + floatingDockClearance + 12
                             : max(96, floatingDockClearance + 12))
                    .padding(.horizontal, 20)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .sheet(item: $statsTile) { selection in
            TrackerTileSheet(tile: selection.tile, tracker: tracker)
        }
        .sheet(isPresented: $editingHand) {
            TrackerHandSheet(
                tracker: tracker,
                onScanHand: { beginHandScan() }
            )
        }
        .sheet(item: $handReview) { payload in
            TrackerHandSheet(
                tracker: tracker,
                initialTiles: payload.tiles,
                sourceImage: payload.image,
                onScanHand: { beginHandScan() },
                onApplied: {
                    coordinator.trackerCaptureIntent = .table
                    presentation.showAfterApply()
                }
            )
        }
        #if DEBUG
        .sheet(isPresented: $showingLiveTuning) {
            TrackerLiveTuningView(
                tuning: $liveTuning,
                onNMSChanged: { liveDetector?.nmsIoUThreshold = $0 }
            )
            .presentationDetents([.medium])
        }
        #endif
        .confirmationDialog("Start a new game? This clears all counts.",
                             isPresented: $confirmingReset,
                             titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                tracker.reset()
                presentation.reset()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: selectedLens) { _, lens in coordinator.camera.setLens(lens) }
        .onAppear {
            configureLens()
            coordinator.trackerCaptureIntent = .table
            if liveDetector == nil {
                liveDetector = TrackerLiveDetectorController(camera: coordinator.camera)
            }
            liveDetector?.nmsIoUThreshold = liveTuning.nmsIoUThreshold
            liveDetector?.start()
        }
        .onDisappear {
            liveDetector?.stop()
            coordinator.trackerCaptureIntent = .table
        }
        .fullScreenCover(item: $reviewPayload) { payload in
            TrackerEvidenceReviewView(
                payload: payload,
                tracker: tracker,
                onApplied: { changed in
                    reviewPayload = nil
                    liveDetector?.resume()
                    presentation.showAfterApply()
                    showShotReadout(count: tracker.seenHistogram.reduce(0, +))
                    flash(changed)
                },
                onCancel: {
                    reviewPayload = nil
                    liveDetector?.resume()
                    presentation.cancelReviewOrCapture()
                }
            )
        }
        .alert("Scan not applied", isPresented: Binding(
            get: { scanError != nil },
            set: { if !$0 { scanError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanError ?? "Try scanning again.")
        }
    }

    /// Draws in this Canvas's own local space, but `previewFrame`/`reticleFrame`
    /// (from `ScanView`) are captured in `.global` — the Canvas here lives
    /// inside a `GeometryReader` that is NOT `.ignoresSafeArea()`d, so its local
    /// bounds are the safe-area rect, not the full-screen preview rect. Mapping
    /// against `previewFrame` first (correct scale + alignment) and then
    /// translating by this Canvas's own global origin (`canvasOrigin`, from
    /// `proxy.frame(in: .global)`) keeps boxes pinned to the real detections
    /// instead of drifting by the safe-area inset.
    private func liveDetectionOverlay(canvasOrigin: CGPoint) -> some View {
        Canvas { context, _ in
            guard let liveDetector,
                  liveDetector.orientedImageSize.width > 0,
                  previewFrame.width > 0 else { return }
            for detection in liveVisibleDetections {
                // Prefer the preview layer's own authoritative conversion
                // (correct under aspect-fill + rotation); fall back to the
                // reconstructed aspect-fill math only while the preview
                // hasn't registered yet.
                let metadataBox = NormalizedRectOrientation.metadataRect(
                    fromOriented: detection.box,
                    orientation: liveDetector.frameOrientation
                )
                let globalRect = coordinator.camera.globalRect(fromMetadata: metadataBox.cgRect)
                    ?? AspectFillMapping.previewRect(
                        ofNormalized: detection.box,
                        previewBounds: previewFrame,
                        orientedImageSize: liveDetector.orientedImageSize
                    )
                let rect = globalRect.offsetBy(dx: -canvasOrigin.x, dy: -canvasOrigin.y)
                guard rect.width > 1, rect.height > 1 else { continue }
                let color = markerColor(label: detection.label)
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 5),
                    with: .color(color),
                    lineWidth: 2
                )
                let label = context.resolve(
                    Text(shortLabel(detection.label))
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(Color.black)
                )
                let measured = label.measure(in: CGSize(width: 120, height: 36))
                let chip = CGRect(
                    x: rect.minX,
                    y: max(0, rect.minY - measured.height - 5),
                    width: measured.width + 8,
                    height: measured.height + 4
                )
                context.fill(Path(roundedRect: chip, cornerRadius: 3), with: .color(color))
                context.draw(
                    label,
                    at: CGPoint(x: chip.minX + 4 + measured.width / 2, y: chip.midY)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func shortLabel(_ raw: String) -> String {
        guard let face = TileFace(detectorLabel: raw) else { return raw }
        switch face {
        case .tile(.suited(.characters, let rank)): return "\(rank) Char"
        case .tile(.suited(.dots, let rank)): return "\(rank) Dot"
        case .tile(.suited(.bamboo, let rank)): return "\(rank) Bam"
        case .tile(.wind(let wind)):
            switch wind {
            case .east: return "East"
            case .south: return "South"
            case .west: return "West"
            case .north: return "North"
            }
        case .tile(.dragon(let dragon)):
            switch dragon {
            case .red: return "Red"
            case .green: return "Green"
            case .white: return "White"
            }
        case .tile(.flower(let flower)): return "Flower \(flower.rawValue)"
        case .tile(.season(let season)): return "Season \(season.rawValue)"
        case .back: return "Back"
        }
    }

    private func markerColor(label: String) -> Color {
        guard case let .tile(tile)? = TileFace(detectorLabel: label) else {
            return Color.gray
        }
        switch tile {
        case .suited(.characters, _): return Color(red: 0.96, green: 0.45, blue: 0.40)
        case .suited(.dots, _): return Color(red: 0.40, green: 0.78, blue: 0.94)
        case .suited(.bamboo, _): return Color(red: 0.45, green: 0.86, blue: 0.50)
        case .wind, .dragon: return MJColor.gold
        case .flower, .season: return Color(red: 0.85, green: 0.55, blue: 0.95)
        }
    }

    private var captureControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(statusText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MJColor.creamHeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())

                #if DEBUG
                if app.trackerDeveloperMode {
                    Button {
                        showingLiveTuning = true
                    } label: {
                        Image(systemName: "ladybug")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Live detector settings")
                    .accessibilityValue(
                        "Auto-confirm \(Int(liveTuning.autoConfirmThreshold * 100)) percent, NMS \(String(format: "%.2f", liveTuning.nmsIoUThreshold))"
                    )
                    .accessibilityHint("Adjusts confidence and overlap filtering for this Tracker session.")
                }
                #endif
            }

            HStack(alignment: .center, spacing: 18) {
                if !presentation.isDrawerVisible, tracker.totalCounted > 0, !isBusy {
                    Button {
                        presentation.showExistingCounts()
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Label("Counts", systemImage: "square.grid.3x3")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Show Tracker counts")
                    .accessibilityValue("\(tracker.totalCounted) counted")
                }

                Button(action: scanTapped) {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 64, height: 64)
                                .overlay {
                                    Circle().strokeBorder(Color.white.opacity(0.92), lineWidth: 4)
                                        .padding(-4)
                                    Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 1)
                                        .padding(5)
                                }
                                .shadow(color: .black.opacity(0.34), radius: 7, y: 3)
                            if isBusy {
                                ProgressView().tint(Color.black)
                            }
                        }
                        Text(coordinator.trackerCaptureIntent == .hand
                             ? "Scan Hand" : "Scan Table")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MJColor.creamHeading)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isBusy || liveDetector?.isReady != true)
                .accessibilityLabel(coordinator.trackerCaptureIntent == .hand
                                    ? "Scan Hand" : "Scan Table")
                .accessibilityHint("Freezes the current Medium detector reading for review.")

                if coordinator.camera.availableBackLenses.count > 1 {
                    Picker("Camera lens", selection: $selectedLens) {
                        ForEach(coordinator.camera.availableBackLenses, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                    .frame(minHeight: 44)
                    .disabled(isBusy)
                    .accessibilityHint("Use 1× for detail or 0.5× when the table does not fit.")
                }

            }
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity)
    }

    private func trackerDrawer(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            CameraDrawerHandle(detent: Binding(
                get: { presentation.drawerDetent },
                set: { presentation.drawerDetent = $0 }
            ),
                               noun: "Tracker drawer",
                               onCollapse: { presentation.collapseDrawer() })
            switch presentation.drawerDetent {
            case .small:
                drawerDetails(compact: true, showOdds: false,
                              availableHeight: max(0, height - 44))
            case .medium:
                drawerDetails(compact: false, showOdds: false,
                              availableHeight: max(0, height - 44))
            case .big:
                drawerDetails(compact: false, showOdds: true,
                              availableHeight: max(0, height - 44))
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height,
               alignment: .top)
        .background(MJColor.deepJade.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(MJColor.gold(0.18)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tracker counts")
    }

    private func drawerDetails(compact: Bool, showOdds: Bool,
                               availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack {
                Text("\(tracker.totalCounted) counted · \(tracker.unseenCount) unseen")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") { confirmingReset = true }
                    .foregroundStyle(MJColor.gold)
                    .frame(minHeight: 44)
            }
            TileCountGrid(histogram: tracker.seenHistogram,
                          handHistogram: tracker.handHistogram,
                          highlight: justChanged,
                          tileWidthCap: compact ? 28 : (showOdds ? 54 : 46),
                          showHonorCaptions: !compact,
                          onTap: { statsTile = TileSelection($0) })
                .frame(maxHeight: .infinity)

            handSummary(compact: compact, showOdds: showOdds)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, compact ? 12 : 16)
        .frame(maxWidth: 760, minHeight: availableHeight, maxHeight: availableHeight,
               alignment: .top)
        .frame(maxWidth: .infinity)
    }

    private func handSummary(compact: Bool, showOdds: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 8) {
                Text("Player Hand")
                    .font(.headline)
                    .foregroundStyle(MJColor.creamHeading)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                Button { beginHandScan() } label: {
                    Label(tracker.hand.isEmpty ? "Scan Hand" : "Scan Again",
                          systemImage: "camera.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button { editingHand = true } label: {
                    Label("Edit Hand Tiles", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if tracker.hand.isEmpty {
                Text("No hand tiles yet")
                    .font(.footnote)
                    .foregroundStyle(MJColor.cream(0.62))
            } else {
                TrackerHandTilesView(
                    tiles: tracker.hand,
                    tileWidth: compact ? 23 : (showOdds ? 36 : 30)
                ) {
                    statsTile = TileSelection($0)
                }
            }

            if showOdds {
                handOddsReadout
            }
        }
    }

    @ViewBuilder
    private var handOddsReadout: some View {
        if let advice = handAdvice {
            if let best = advice.best {
                HStack(spacing: 6) {
                    Text("Discard").foregroundStyle(MJColor.cream(0.6))
                    MahjongTileView(best.tile, width: 22)
                    Text("→ \(shantenLabel(best.shantenAfter)) · \(best.ukeireTotal) live · \(pct(best.nextDrawOdds))")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(MJColor.creamHeading)
            } else if let waitSet = advice.waitSet {
                Text("\(shantenLabel(waitSet.shanten)) · \(waitSet.totalLive) live · \(pct(waitSet.nextDrawOdds))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MJColor.creamHeading)
            }
        } else {
            Text(tracker.hand.count > 14
                 ? "Odds need a 13–14 tile shape"
                 : "Add \(max(0, 13 - tracker.hand.count)) more tiles for hand odds")
                .font(.caption)
                .foregroundStyle(MJColor.cream(0.6))
        }
    }

    private var handAdvice: CoachAdvice? {
        guard (13...14).contains(tracker.hand.count) else { return nil }
        let table = TableState(
            concealed: tracker.hand, melds: [], bonusTiles: [],
            seenHistogram: tracker.seenHistogram,
            unseenCount: tracker.unseenCount, opponentMeldCount: 0,
            context: GameContext(seatWind: .east, prevailingWind: .east,
                                 houseRules: .standard)
        )
        return CoachAdvisor.advise(table)
    }

    private var statusText: String {
        if liveDetector?.isReady != true { return "Preparing Medium detector…" }
        if isBusy { return "Freezing current reading…" }
        if let error = liveDetector?.errorMessage { return error }
        if let shotReadout { return shotReadout }
        if coordinator.trackerCaptureIntent == .hand {
            return "Point the camera straight at your face-up hand tiles"
        }
        let visible = liveVisibleDetections.count
        return visible == 0 ? "Looking for tiles…" : "\(visible) tiles detected live"
    }

    private func configureLens() {
        if let onlyLens = coordinator.camera.availableBackLenses.first,
           !coordinator.camera.availableBackLenses.contains(selectedLens) {
            selectedLens = onlyLens
        }
        coordinator.camera.setLens(selectedLens)
    }

    private func guideROI(orientedImageSize: CGSize) -> TileBoundingBox? {
        guard previewFrame.width > 0, reticleFrame.width > 0,
              orientedImageSize.width > 0, orientedImageSize.height > 0 else {
            return nil
        }
        return AspectFillMapping.normalizedImageRect(
            of: reticleFrame,
            previewBounds: previewFrame,
            orientedImageSize: orientedImageSize
        )
    }

    private func scanTapped() {
        guard !isBusy else { return }
        switch coordinator.trackerCaptureIntent {
        case .table:
            Task { await captureTable() }
        case .hand:
            Task { await captureHand() }
        }
    }

    private func captureTable(newerThan sequence: UInt64? = nil) async {
        guard let liveDetector else { return }
        presentation.beginCapture()
        isBusy = true
        defer { isBusy = false }
        do {
            let snapshot = try await liveDetector.captureTableSnapshot(newerThan: sequence)
            guard let roi = guideROI(orientedImageSize: snapshot.orientedPixelSize) else {
                throw TrackerLiveDetectorError.cameraNotReady
            }
            let payload = TrackerLiveEvidenceBuilder.payload(
                from: snapshot,
                guideROI: roi,
                tuning: liveTuning
            )
            guard !payload.evidence.tiles.isEmpty else {
                throw TrackerLiveDetectorError.inferenceFailed("No visible tiles")
            }
            liveDetector.pause()
            presentation.showReview()
            reviewPayload = payload
        } catch {
            liveDetector.resume()
            presentation.cancelReviewOrCapture()
            scanError = error.localizedDescription
        }
    }

    private func captureHand() async {
        guard let liveDetector,
              let frame = coordinator.camera.latestFrame else {
            scanError = TrackerLiveDetectorError.cameraNotReady.localizedDescription
            return
        }
        let full = RecognizerFrame.buffer(
            frame.pixelBuffer,
            orientation: frame.imageOrientation
        )
        guard previewFrame.width > 0, reticleFrame.width > 0 else {
            scanError = "The hand guide is not ready yet."
            return
        }
        let roi = AspectFillMapping.normalizedImageRect(
            of: reticleFrame,
            previewBounds: previewFrame,
            orientedImageSize: full.orientedPixelSize
        )
        isBusy = true
        defer { isBusy = false }
        do {
            let snapshot = try await liveDetector.captureHandSnapshot(roi: roi)
            let recognized = snapshot.visibleDetections.compactMap { detection -> DetectedTile? in
                guard case let .tile(tile)? = TileFace(detectorLabel: detection.label) else {
                    return nil
                }
                return DetectedTile(
                    tile: tile,
                    confidence: detection.confidence,
                    box: detection.box
                )
            }
            guard !recognized.isEmpty else {
                throw TrackerLiveDetectorError.inferenceFailed("No hand tiles")
            }
            let ordered = RecognitionResult(tiles: recognized).faces
            coordinator.trackerCaptureIntent = .table
            handReview = TrackerHandReviewPayload(
                id: snapshot.id,
                image: snapshot.image,
                tiles: ordered
            )
        } catch {
            scanError = error.localizedDescription
        }
    }

    private func beginHandScan() {
        editingHand = false
        handReview = nil
        coordinator.trackerCaptureIntent = .hand
        presentation.rescan()
        liveDetector?.resume()
    }

    private func showShotReadout(count: Int) {
        shotReadout = "Found \(count) tiles this scan"
        Task {
            try? await Task.sleep(for: .milliseconds(1_500))
            if shotReadout == "Found \(count) tiles this scan" { shotReadout = nil }
        }
    }

    private func flash(_ changed: Set<Int>) {
        let tiles = Set(changed.compactMap(Tile.init(classIndex:)))
        guard !tiles.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { justChanged = tiles }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.4)) { justChanged = [] }
        }
    }

    private func pct(_ odds: Double) -> String {
        String(format: "%.1f%% next draw", odds * 100)
    }
}

private struct TrackerHandReviewPayload: Identifiable {
    var id: UUID
    var image: UIImage
    var tiles: [Tile]
}

private extension TileBoundingBox {
    func containsCenter(of box: TileBoundingBox) -> Bool {
        box.centerX >= x && box.centerX <= x + width
            && box.centerY >= y && box.centerY <= y + height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

#if DEBUG
private struct TrackerLiveTuningView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tuning: TrackerLiveTuning
    let onNMSChanged: (Double) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Live Detector") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Auto-confirm confidence")
                            Spacer()
                            Text(tuning.autoConfirmThreshold, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $tuning.autoConfirmThreshold,
                               in: 0.50...0.95, step: 0.01)
                            .accessibilityLabel("Auto-confirm confidence")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("NMS overlap")
                            Spacer()
                            Text(tuning.nmsIoUThreshold, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $tuning.nmsIoUThreshold,
                               in: 0.10...0.90, step: 0.01)
                            .accessibilityLabel("NMS overlap")
                    }

                    LabeledContent("Review floor", value: "0.30")
                }

                Section {
                    Button("Reset Defaults") {
                        tuning = .defaults
                        onNMSChanged(tuning.nmsIoUThreshold)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                } footer: {
                    Text("These values apply only until Tracker is closed.")
                }
            }
            .navigationTitle("Live Detection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: tuning.nmsIoUThreshold) { _, value in
                onNMSChanged(value)
            }
        }
    }
}
#endif
