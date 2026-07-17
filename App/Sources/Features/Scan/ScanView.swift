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
    @State private var mode: ScanMode = .score
    @State private var camera = CameraCapture()
    @State private var photoItem: PhotosPickerItem?
    @State private var previewFrame: CGRect = .zero
    @State private var reticleFrame: CGRect = .zero
    @State private var torchOn = false

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            ScreenBackground(.camera)
            #else
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) },
                                  action: { previewFrame = $0 })
            #endif

            if reticleFrame != .zero {
                ViewfinderBlurOverlay(window: reticleFrame)
                OrbitDots(window: reticleFrame)
            }

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    SegmentedToggle(selection: $mode,
                                    options: [(ScanMode.score, "Score"), (ScanMode.coach, "Coach")])
                    HintPill(text: mode == .score
                             ? "Lay your hand flat, face-up"
                             : "I'll suggest your best discard")
                }
                .padding(.top, 16)

                Spacer()
                Color.clear
                    .frame(width: 300, height: 150)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) },
                                      action: { reticleFrame = $0 })
                Spacer()

                VStack(spacing: 12) {
                    ScanStatusCard(mode: mode, isBusy: coordinator.isRecognizing) { shutterTapped() }
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
            camera.requestAndStart()
            #endif
        }
        .onDisappear {
            #if !targetEnvironment(simulator)
            camera.stop()
            #endif
        }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
    }

    /// Flash toggle for the live camera (device only).
    private var torchButton: some View {
        Button {
            torchOn.toggle()
            camera.setTorch(torchOn)
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
    private func shutterTapped() {
        #if targetEnvironment(simulator)
        coordinator.capture(mode, frame: nil)
        #else
        let buffer = camera.latestBuffer
        let frame = buffer.map { RecognizerFrame.buffer($0, orientation: .right) }
        var roi: TileBoundingBox?
        if let frame, previewFrame.width > 0, reticleFrame.width > 0 {
            roi = AspectFillMapping.normalizedImageRect(of: reticleFrame,
                                                        previewBounds: previewFrame,
                                                        orientedImageSize: frame.orientedPixelSize)
        }
        coordinator.capture(mode, frame: frame, roi: roi, photo: buffer.flatMap(Self.photo(from:)))
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

private struct ScanStatusCard: View {
    let mode: ScanMode
    var isBusy: Bool = false
    let onShutter: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(MJColor.gold).frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.35)
                Text(isBusy ? "Reading tiles…"
                            : (mode == .score ? "Looking for tiles…" : "Ready to coach your hand"))
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

private extension CGImagePropertyOrientation {
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
