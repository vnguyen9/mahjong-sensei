import SwiftUI
import PhotosUI
import UIKit
import CoreVideo
import DesignSystem
import MahjongCore
import Recognition
import EfficiencyEngine
import CoachEngine

/// Tracker mode's bottom-region card: count grid, Record shutter, Reset, and a
/// compact hand summary. Tile/hand editing opens dedicated sheets
/// (`TrackerTileSheet` / `TrackerHandSheet`).
struct TrackerCard: View {
    @Environment(ScanCoordinator.self) private var coordinator
    /// The live preview + reticle window geometry, forwarded from `ScanView`
    /// so Record can map the reticle to a normalized image ROI exactly like
    /// `ScanView.shutterTapped()` does.
    let previewFrame: CGRect
    let reticleFrame: CGRect

    @State private var isBusy = false
    @State private var photoItem: PhotosPickerItem?
    @State private var statsTile: TileSelection?
    @State private var editingHand = false
    @State private var confirmingReset = false
    /// Tiles this shot's Record just changed — flashed via `TileCountGrid`'s
    /// gold highlight ring for a moment, then cleared.
    @State private var justChanged: Set<Tile> = []
    /// Deduped tile count from the latest Record — shown briefly so overcount
    /// is obvious without drawing detection boxes.
    @State private var shotReadout: String?

    private var tracker: TrackerSession { coordinator.tracker }

    var body: some View {
        VStack(spacing: 14) {
            header
            TileCountGrid(histogram: tracker.seenHistogram,
                          handHistogram: tracker.handHistogram,
                          highlight: justChanged,
                          tileWidthCap: 28, showHonorCaptions: true,
                          onTap: { statsTile = TileSelection($0) })
                .frame(height: 210)
            recordSection
            handSummary
        }
        .mjCard(cornerRadius: 20)
        .sheet(item: $statsTile) { sel in
            TrackerTileSheet(tile: sel.tile, tracker: tracker)
        }
        .sheet(isPresented: $editingHand) {
            TrackerHandSheet(tracker: tracker)
        }
        .confirmationDialog("Start a new game? This clears all counts.",
                             isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { tracker.reset() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("\(tracker.totalCounted) counted · \(tracker.unseenCount) unseen")
                .font(MJFont.ui(13, weight: .semibold))
                .foregroundStyle(MJColor.creamHeading)
            Spacer(minLength: 8)
            TextLink("Reset") { confirmingReset = true }
        }
    }

    // MARK: Record + photo test

    private var recordSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(MJColor.gold).frame(width: 6, height: 6)
                Text(recordStatusText)
                    .font(MJFont.ui(12, weight: .semibold))
                    .foregroundStyle(MJColor.cream(0.85))
            }
            Button(action: recordTapped) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [MJColor.lightGold, MJColor.gold],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 56, height: 56)
                        .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 3).padding(3) }
                        .shadow(color: MJColor.gold(0.4), radius: 6, y: 4)
                    if isBusy {
                        ProgressView().tint(MJColor.inkOnGold)
                    } else {
                        Text("Record")
                            .font(MJFont.ui(11, weight: .bold))
                            .foregroundStyle(MJColor.inkOnGold)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("Record")

            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                Label("Test with a photo", systemImage: "photo.on.rectangle.angled")
                    .font(MJFont.ui(12, weight: .semibold))
                    .foregroundStyle(MJColor.cream(0.9))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background { Capsule().fill(Color(hex: 0x0A241D, alpha: 0.55)) }
                    .overlay { Capsule().strokeBorder(MJColor.gold(0.2), lineWidth: 1) }
            }
            .disabled(isBusy)
        }
    }

    private var recordStatusText: String {
        if isBusy { return "Reading the table…" }
        if let shotReadout { return shotReadout }
        return "Frame the table"
    }

    private func recordTapped() {
        guard !isBusy, let cameraFrame = coordinator.camera.latestFrame else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            let buffer = cameraFrame.pixelBuffer
            let orientation = cameraFrame.imageOrientation
            let orientedSize = RecognizerFrame.buffer(buffer, orientation: orientation).orientedPixelSize
            var roi: TileBoundingBox?
            if previewFrame.width > 0, reticleFrame.width > 0 {
                roi = AspectFillMapping.normalizedImageRect(of: reticleFrame,
                                                             previewBounds: previewFrame,
                                                             orientedImageSize: orientedSize)
            }
            let detections = await coordinator.recordScan(
                buffer: buffer,
                roi: roi,
                imageOrientation: orientation
            )
            commit(detections)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data), let cgImage = image.cgImage else { return }
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            isBusy = true
            let detections = TiledTileRecognizer.accepting(
                await coordinator.recognizeAllTiles(frame: .image(cgImage, orientation: orientation)))
            isBusy = false
            commit(detections)
            photoItem = nil
        }
    }

    private func commit(_ detections: [DetectedTile]) {
        let faceUp = detections.filter { !$0.tile.isBonus }
        showShotReadout(count: faceUp.count)
        apply(coordinator.tracker.recordReplaceFromShot(detections))
    }

    private func showShotReadout(count: Int) {
        shotReadout = "Found \(count) tiles this shot"
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if shotReadout == "Found \(count) tiles this shot" {
                shotReadout = nil
            }
        }
    }

    private func apply(_ changed: Set<Int>) {
        let tiles = Set(changed.compactMap(Tile.init(classIndex:)))
        guard !tiles.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { justChanged = tiles }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.4)) { justChanged = [] }
        }
    }

    // MARK: Hand summary (edit opens TrackerHandSheet)

    private var handSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { editingHand = true } label: {
                HStack(spacing: 5) {
                    Text(tracker.hand.isEmpty ? "+ Add your hand" : "Edit hand")
                        .font(MJFont.ui(12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(MJColor.gold)
            }
            .buttonStyle(.plain)

            if !tracker.hand.isEmpty {
                TrackerHandTilesView(tiles: tracker.hand, tileWidth: 26) { tile in
                    statsTile = TileSelection(tile)
                }
                handOddsReadout
            }
        }
    }

    @ViewBuilder
    private var handOddsReadout: some View {
        if let advice = handAdvice {
            VStack(alignment: .leading, spacing: 6) {
                if let best = advice.best {
                    HStack(spacing: 6) {
                        Text("Discard").font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.6))
                        MahjongTileView(best.tile, theme: .jade, width: 22)
                        Text("→ \(shantenLabel(best.shantenAfter)) · \(best.ukeireTotal) live · \(pct(best.nextDrawOdds))")
                            .font(MJFont.ui(11, weight: .semibold)).foregroundStyle(MJColor.creamHeading)
                    }
                } else if let waitSet = advice.waitSet {
                    Text("\(shantenLabel(waitSet.shanten)) · \(waitSet.totalLive) live · \(pct(waitSet.nextDrawOdds)) next draw")
                        .font(MJFont.ui(11, weight: .semibold)).foregroundStyle(MJColor.creamHeading)
                } else {
                    Text(shantenLabel(advice.currentShanten))
                        .font(MJFont.ui(11, weight: .semibold)).foregroundStyle(MJColor.creamHeading)
                }
            }
        } else if tracker.hand.count > 14 {
            Text("Odds need a 13–14 tile shape")
                .font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.5))
        } else {
            Text("Add \(max(0, 13 - tracker.hand.count)) more tiles for hand odds")
                .font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.5))
        }
    }

    private var handAdvice: CoachAdvice? {
        guard (13...14).contains(tracker.hand.count) else { return nil }
        let table = TableState(concealed: tracker.hand, melds: [], bonusTiles: [],
                                seenHistogram: tracker.seenHistogram, unseenCount: tracker.unseenCount,
                                opponentMeldCount: 0,
                                context: GameContext(seatWind: .east, prevailingWind: .east, houseRules: .standard))
        return CoachAdvisor.advise(table)
    }

    private func pct(_ odds: Double) -> String { String(format: "%.1f%% next draw", odds * 100) }
}
