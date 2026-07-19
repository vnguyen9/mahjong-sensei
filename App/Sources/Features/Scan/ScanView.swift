import SwiftUI
import PhotosUI
import UIKit
import ImageIO
import CoreImage
import CoreVideo
import DesignSystem
import MahjongCore
import Recognition

/// Lane 2 · Aim at your hand (spec screen 5). On device the live camera feeds the
/// bundled Core ML detector at shutter; the Simulator (no camera) walks on demo
/// data, or you can feed a still via the "Test with a photo" picker (device too).
struct ScanView: View {
    @Environment(ScanCoordinator.self) private var coordinator
    @State private var mode: ScanMode
    @State private var photoItem: PhotosPickerItem?
    @State private var previewFrame: CGRect = .zero
    @State private var reticleFrame: CGRect = .zero
    @State private var torchOn = false
    @State private var lookupTile: Tile?
    @State private var lookupRect: CGRect?
    @State private var sheetTile: TileSelection?

    init(initialMode: ScanMode = .lookup) {
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            ScreenBackground(.camera)
            #else
            CameraPreview(session: coordinator.camera.session)
                .ignoresSafeArea()
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) },
                                  action: { previewFrame = $0 })
            #endif

            // The viewfinder window anchor: a fixed spot (~42% down the screen) so
            // the window never shifts between modes with different bottom cards. Its
            // size adapts to the mode — Score frames a whole hand (wide, short band),
            // Lens frames one tile (tight box). This rect is also the Score crop.
            GeometryReader { geo in
                let size = reticleSize(for: mode, in: geo.size)
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) },
                                      action: { reticleFrame = $0 })
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.42)
            }
            .allowsHitTesting(false)

            if reticleFrame != .zero {
                ViewfinderBlurOverlay(window: reticleFrame)
                OrbitDots(window: reticleFrame)
            }

            #if !targetEnvironment(simulator)
            if mode == .lookup, let rect = lookupRect {
                LookupHighlight(rect: rect)
            }
            #endif

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    SegmentedToggle(selection: $mode,
                                    options: [(ScanMode.score, "Score"), (ScanMode.lookup, "What's this?"),
                                              (ScanMode.tracker, "Tracker")],
                                    fontSize: 12, hPad: 11, vPad: 9)
                    HintPill(text: hint)
                    CoachLiveButton { coordinator.startCoachLive() }
                        .padding(.top, 2)
                }
                .padding(.top, 16)

                Spacer()

                VStack(spacing: 12) {
                    switch mode {
                    case .lookup:
                        LookupCard(tile: lookupTile)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let tile = lookupTile { sheetTile = TileSelection(tile) }
                            }
                    case .tracker:
                        TrackerCard(previewFrame: previewFrame, reticleFrame: reticleFrame)
                    case .score:
                        ScanStatusCard(isBusy: coordinator.isRecognizing) { shutterTapped() }
                        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                            Label("Test with a photo", systemImage: "photo.on.rectangle.angled")
                                .font(MJFont.ui(12, weight: .semibold))
                                .foregroundStyle(MJColor.cream(0.9))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background { Capsule().fill(Color(hex: 0x0A241D, alpha: 0.55)) }
                                .overlay { Capsule().strokeBorder(MJColor.gold(0.2), lineWidth: 1) }
                        }
                        .disabled(coordinator.isRecognizing)
                    }
                }
                .padding(.bottom, 96)
            }
            .padding(.horizontal, 20)
        }
        .overlay(alignment: .topTrailing) {
            #if !targetEnvironment(simulator)
            torchButton
                .padding(.trailing, 20)
                .padding(.top, 16)
            #endif
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            #if !targetEnvironment(simulator)
            torchOn = false
            coordinator.camera.requestAndStart()
            #endif
        }
        .onDisappear {
            #if !targetEnvironment(simulator)
            coordinator.camera.stop()
            #endif
        }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        .task(id: mode) { await runLookupLoop() }
        .sheet(item: $sheetTile) { sel in
            TileDetailSheet(tile: sel.tile)
        }
    }

    private var hint: String {
        switch mode {
        case .score:   return "Lay your hand flat, face-up"
        case .lookup:  return "Point the camera at one tile"
        case .tracker: return "Aim at the discards, then Record"
        }
    }

    /// The viewfinder window (and, in Score, the capture crop) size per mode. A
    /// hand laid flat is a long horizontal strip, so Score gets a wide, short band
    /// spanning nearly the screen; Lens frames a single tile, so it stays tight.
    /// Tracker reuses Score's wide band — it's framing a spread-out discard pile.
    private func reticleSize(for mode: ScanMode, in screen: CGSize) -> CGSize {
        switch mode {
        case .score, .tracker: return CGSize(width: max(240, screen.width - 32), height: 132)
        case .lookup:          return CGSize(width: 280, height: 150)
        }
    }

    /// While in What's-this mode, poll the live frame ~3×/s and identify the largest
    /// (closest-to-camera) tile, updating the card + highlight. Paused while the detail
    /// sheet is open (so its tile stays put) and cancelled/cleared the moment the mode
    /// changes. The Simulator shows a fixed demo tile.
    private func runLookupLoop() async {
        guard mode == .lookup else { lookupTile = nil; lookupRect = nil; return }
        #if targetEnvironment(simulator)
        lookupTile = .redDragon
        lookupRect = nil
        #else
        var misses = 0
        while !Task.isCancelled, mode == .lookup {
            if sheetTile != nil {                       // pause identification while the sheet is open
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            if let buffer = coordinator.camera.latestBuffer {
                let frame = RecognizerFrame.buffer(buffer, orientation: .right)
                var roi: TileBoundingBox?
                if previewFrame.width > 0, reticleFrame.width > 0 {
                    roi = AspectFillMapping.normalizedImageRect(of: reticleFrame,
                                                                previewBounds: previewFrame,
                                                                orientedImageSize: frame.orientedPixelSize)
                }
                if let hit = await coordinator.lookup(frame, roi: roi) {
                    lookupTile = hit.tile
                    if previewFrame.width > 0 {
                        lookupRect = AspectFillMapping.previewRect(ofNormalized: hit.box,
                                                                   previewBounds: previewFrame,
                                                                   orientedImageSize: frame.orientedPixelSize)
                    }
                    misses = 0
                } else {
                    misses += 1
                    if misses >= 4 { lookupTile = nil; lookupRect = nil }
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        #endif
    }

    /// Flash toggle for the live camera (device only).
    private var torchButton: some View {
        Button {
            torchOn.toggle()
            coordinator.camera.setTorch(torchOn)
        } label: {
            Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(torchOn ? MJColor.gold : MJColor.cream(0.85))
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    Circle().fill(Color(hex: 0x0A241D, alpha: 0.55))
                }
                .overlay { Circle().strokeBorder(MJColor.gold(torchOn ? 0.5 : 0.2), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(torchOn ? "Turn flash off" : "Turn flash on")
    }

    /// Shutter: recognize the latest live frame (device) or the demo hand (Simulator).
    /// Only reachable in Score mode. The captured frame is cropped to the reticle band
    /// before recognition, so the detector spends its fixed input budget on the tiles
    /// (not the whole scene) — sharper reads on a long row. The live preview is never
    /// cropped; this is capture-only. Falls back to the full frame (ROI-filtered) if
    /// the crop can't be made.
    private func shutterTapped() {
        #if targetEnvironment(simulator)
        coordinator.capture(mode, frame: nil)
        #else
        guard let buffer = coordinator.camera.latestBuffer else {
            coordinator.capture(mode, frame: nil)
            return
        }
        let photo = Self.photo(from: buffer)
        let full = RecognizerFrame.buffer(buffer, orientation: .right)
        var roi: TileBoundingBox?
        if previewFrame.width > 0, reticleFrame.width > 0 {
            roi = AspectFillMapping.normalizedImageRect(of: reticleFrame,
                                                        previewBounds: previewFrame,
                                                        orientedImageSize: full.orientedPixelSize)
        }
        if let roi, let cropped = Self.croppedFrame(from: buffer, roiNormalized: roi, margin: 0.04) {
            // The crop already scopes to the ROI, so capture it with no post-filter.
            coordinator.capture(mode, frame: cropped, roi: nil, photo: photo)
        } else {
            coordinator.capture(mode, frame: full, roi: roi, photo: photo)
        }
        #endif
    }

    /// Photo picker: decode the chosen still and run recognition on it.
    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data), let cgImage = image.cgImage else { return }
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            await MainActor.run {
                coordinator.capture(mode, frame: .image(cgImage, orientation: orientation), photo: image)
                photoItem = nil
            }
        }
    }

    private static let ciContext = CIContext()
    /// Snapshot a camera pixel buffer into a UIImage for the post-scan backdrop.
    static func photo(from buffer: CVPixelBuffer) -> UIImage? {
        let image = CIImage(cvPixelBuffer: buffer).oriented(.right)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Crop the captured buffer to the reticle band (in oriented image space) and
    /// return it as a recognizer frame. `roi` is normalized with a top-left origin;
    /// CIImage uses a bottom-left origin, so y is flipped. The band is grown by a
    /// small margin so tiles straddling the edge stay whole. Returns nil if the crop
    /// is degenerate or can't be rendered (the caller then uses the full frame).
    static func croppedFrame(from buffer: CVPixelBuffer,
                             roiNormalized roi: TileBoundingBox,
                             margin: Double) -> RecognizerFrame? {
        let image = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let W = Double(image.extent.width), H = Double(image.extent.height)
        guard W > 0, H > 0 else { return nil }
        let mx = roi.width * margin, my = roi.height * margin
        let nx    = max(0.0, roi.x - mx)
        let ny    = max(0.0, roi.y - my)
        let nMaxX = min(1.0, roi.x + roi.width + mx)
        let nMaxY = min(1.0, roi.y + roi.height + my)
        let cropW = (nMaxX - nx) * W
        let cropH = (nMaxY - ny) * H
        guard cropW >= 1, cropH >= 1 else { return nil }
        let rect = CGRect(x: nx * W, y: (1 - nMaxY) * H, width: cropW, height: cropH)
        let cropped = image.cropped(to: rect)
        guard !cropped.extent.isInfinite, !cropped.extent.isEmpty,
              let cg = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }
        return .image(cg, orientation: .up)
    }
}

private struct HintPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(MJFont.ui(12, weight: .medium))
            .foregroundStyle(MJColor.cream(0.9))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background {
                Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                Capsule().fill(Color(hex: 0x0A241D, alpha: 0.55))
            }
            .overlay { Capsule().strokeBorder(MJColor.gold(0.2), lineWidth: 1) }
    }
}

/// The marquee entry to the live table coach — deliberately CONTRASTS with the
/// frosted pill above it: a solid gold capsule, always visible (not gated by
/// `mode`; the lookup card lives at the bottom, no collision).
private struct CoachLiveButton: View {
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(MJColor.liveRed).frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.35)
                Text("Coach Live").font(MJFont.ui(14, weight: .bold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(0.7)
                    .padding(.leading, 1)
            }
            .foregroundStyle(MJColor.inkOnGold)
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .frame(height: 40)
            .background(
                LinearGradient(colors: [MJColor.lightGold, MJColor.gold],
                               startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .shadow(color: MJColor.gold(0.35), radius: 8, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start Coach Live session")
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

private struct ScanStatusCard: View {
    var isBusy: Bool = false
    let onShutter: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(MJColor.gold).frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.35)
                Text(isBusy ? "Reading tiles…" : "Looking for tiles…")
                    .font(MJFont.ui(13, weight: .semibold))
                    .foregroundStyle(MJColor.cream)
            }

            Button(action: onShutter) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [MJColor.lightGold, MJColor.gold],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 56, height: 56)
                        .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 3).padding(3) }
                        .shadow(color: MJColor.gold(0.4), radius: 6, y: 4)
                    if isBusy {
                        ProgressView().tint(MJColor.inkOnGold)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel("Capture")
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x0F342B, alpha: 0.5))
        }
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(MJColor.gold(0.16), lineWidth: 1) }
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

/// De-privatized so `TrackerCard`'s "Test with a photo" path (Tracker plan §5)
/// can reuse the same `UIImage.imageOrientation` → `CGImagePropertyOrientation`
/// mapping as `ScanView.loadPhoto`.
extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
