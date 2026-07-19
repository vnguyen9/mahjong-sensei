import SwiftUI
import PhotosUI
import UIKit
import CoreVideo
import DesignSystem
import MahjongCore
import Recognition
import EfficiencyEngine
import CoachEngine

/// Tracker mode's bottom-region card (Tracker plan §5): the big 34-tile count
/// grid, a gold Record shutter (record-triggered only — no live/continuous
/// detection), Reset, and a collapsed hand tray for optional real ukeire/win
/// odds. Reuses `TileCountGrid`/`CountAdjustSheet` (already decoupled from
/// CoachLiveSession) and `TrackerSession`/`ScanCoordinator.recordScan` (chunk 1).
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
    @State private var addingHandTile = false
    @State private var confirmingReset = false
    @State private var handExpanded = false
    /// Tiles this shot's Record just changed — flashed via `TileCountGrid`'s
    /// gold highlight ring for a moment, then cleared (nice-to-have per plan).
    @State private var justChanged: Set<Tile> = []

    private var tracker: TrackerSession { coordinator.tracker }

    var body: some View {
        VStack(spacing: 14) {
            header
            TileCountGrid(histogram: tracker.seenHistogram, highlight: justChanged,
                          tileWidthCap: 28, onTap: { statsTile = TileSelection($0) })
                .frame(height: 190)
            recordSection
            handDisclosure
        }
        .mjCard(cornerRadius: 20)
        .sheet(item: $statsTile) { sel in
            CountAdjustSheet(tile: sel.tile, initialCount: tracker.seenHistogram[sel.tile.classIndex],
                              onApply: { tracker.setCount(classIndex: sel.tile.classIndex, count: $0) }) {
                TrackerTileStats(tile: sel.tile, tracker: tracker)
            }
            .presentationDetents([.height(520)])
            .presentationBackground(.clear)
        }
        .sheet(isPresented: $addingHandTile) {
            CorrectionPicker(current: nil, confirmVerb: "Add", onConfirm: { tile in
                guard tracker.hand.count < 14 else { addingHandTile = false; return }
                tracker.setHand(tracker.hand + [tile])
                addingHandTile = false
            }, onRemove: nil)
            .presentationDetents([.height(360)])
            .presentationBackground(.clear)
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
                Text(isBusy ? "Reading discards…" : "Aim at the discards")
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

    /// Recognizes the latest live frame within the reticle band via the
    /// tiled native-res recognizer (`ScanCoordinator.recordScan`, chunk 1) and
    /// folds it into the tracker's running counts. A no-op if there's no live
    /// buffer yet (e.g. the Simulator, or before the camera warms up) — "Test
    /// with a photo" below is the fallback path there.
    private func recordTapped() {
        guard !isBusy, let buffer = coordinator.camera.latestBuffer else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            let orientedSize = RecognizerFrame.buffer(buffer, orientation: .right).orientedPixelSize
            var roi: TileBoundingBox?
            if previewFrame.width > 0, reticleFrame.width > 0 {
                roi = AspectFillMapping.normalizedImageRect(of: reticleFrame,
                                                             previewBounds: previewFrame,
                                                             orientedImageSize: orientedSize)
            }
            let detections = await coordinator.recordScan(buffer: buffer, roi: roi)
            apply(coordinator.tracker.recordMaxMerge(detections))
        }
    }

    /// Photo picker path — a single-pass (non-tiled) recognize is fine on a
    /// high-res photo, which is the whole point of tiling the live low-res
    /// buffer in the first place (Tracker plan §5).
    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data), let cgImage = image.cgImage else { return }
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            isBusy = true
            let detections = await coordinator.recognizeAllTiles(frame: .image(cgImage, orientation: orientation))
            isBusy = false
            apply(coordinator.tracker.recordMaxMerge(detections))
            photoItem = nil
        }
    }

    /// Briefly rings the changed tiles gold, then clears — reuses
    /// `TileCountGrid`'s existing wait-highlight styling for the flash rather
    /// than inventing a second animation language.
    private func apply(_ changed: Set<Int>) {
        let tiles = Set(changed.compactMap(Tile.init(classIndex:)))
        guard !tiles.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { justChanged = tiles }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.4)) { justChanged = [] }
        }
    }

    // MARK: Hand tray (§7)

    @ViewBuilder
    private var handDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { handExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(handExpanded ? "Your hand" : "+ Add your hand")
                        .font(MJFont.ui(12, weight: .semibold))
                    Image(systemName: handExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(MJColor.gold)
            }
            .buttonStyle(.plain)

            if handExpanded {
                handRow
                handOddsReadout
            }
        }
    }

    private var handRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(tracker.hand.enumerated()), id: \.offset) { index, tile in
                    Button {
                        var updated = tracker.hand
                        updated.remove(at: index)
                        tracker.setHand(updated)
                    } label: {
                        MahjongTileView(tile, theme: .jade, width: 26)
                    }
                    .buttonStyle(.plain)
                }
                if tracker.hand.count < 14 {
                    Button { addingHandTile = true } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(MJColor.gold(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: 26, height: 35)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(MJColor.gold(0.85))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a tile to your hand")
                }
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
        } else {
            Text("Add \(max(0, 13 - tracker.hand.count)) more tiles for hand odds")
                .font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.5))
        }
    }

    /// Only meaningful once the hand is a real 13/14-tile shape — `CoachAdvisor`
    /// degrades to `.invalid` outside that range, so this simply doesn't call
    /// it rather than risk showing a nonsense readout for a partial hand.
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

/// Tap-a-tile stats footer for `CountAdjustSheet` in Tracker mode (plan §6):
/// live copies remaining, next-draw probability, pung/kong feasibility, and —
/// when the player has entered their own hand — whether this tile actually
/// improves it, via the real `EfficiencyEngine.ukeire`.
struct TrackerTileStats: View {
    let tile: Tile
    let tracker: TrackerSession

    private var seen: Int {
        tracker.seenHistogram.indices.contains(tile.classIndex) ? tracker.seenHistogram[tile.classIndex] : 0
    }
    private var inHand: Int { tracker.hand.filter { $0 == tile }.count }
    private var live: Int { max(0, 4 - seen - inHand) }
    private var drawChance: Double { EfficiencyEngine.winOdds(liveOuts: live, unseen: tracker.unseenCount) }

    var body: some View {
        VStack(spacing: 8) {
            Divider().overlay(MJColor.gold(0.15))
            statRow("Live copies", "\(live) of 4")
            statRow("Draw chance", String(format: "%.1f%%", drawChance * 100))
            statRow("Pung", live >= 3 ? "Still possible" : "No longer possible")
            statRow("Kong", live >= 4 ? "Still possible" : "No longer possible")
            if let improves = handImprovement {
                Text("Improves your hand — \(improves) live")
                    .font(MJFont.ui(12, weight: .semibold))
                    .foregroundStyle(MJColor.gold)
                    .padding(.top, 2)
            }
        }
        .padding(.top, 4)
    }

    /// Only checked for a hand roughly at a pre-tenpai/tenpai concealed shape
    /// (10–13 tiles) — `EfficiencyEngine.ukeire` is pure/total over any tile
    /// list, but outside that range the result isn't a meaningful "does this
    /// help" answer, so this guards it rather than showing noise for a
    /// half-entered hand.
    private var handImprovement: Int? {
        guard (10...13).contains(tracker.hand.count) else { return nil }
        let uke = EfficiencyEngine.ukeire(tracker.hand, seen: tracker.seenHistogram)
        guard let count = uke[tile], count > 0 else { return nil }
        return count
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(MJFont.ui(12)).foregroundStyle(MJColor.cream(0.6))
            Spacer()
            Text(value).font(MJFont.ui(12, weight: .semibold)).foregroundStyle(MJColor.creamHeading)
        }
    }
}
