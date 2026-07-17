import SwiftUI
import DesignSystem
import MahjongCore
import Recognition

/// Lane 2 · Aim at your hand (spec screen 5). Simulated camera ground for the
/// simulator; the live `AVCaptureVideoPreviewLayer` drops in behind this later.
struct ScanView: View {
    @Environment(ScanCoordinator.self) private var coordinator
    @State private var mode: ScanMode = .score
    @State private var camera = CameraCapture()

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            ScreenBackground(.camera)
            #else
            CameraPreview(session: camera.session).ignoresSafeArea()
            Color.black.opacity(0.2).ignoresSafeArea()
            #endif

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
                ScanReticle()
                    .frame(width: 300, height: 150)
                Spacer()

                ScanStatusCard(mode: mode) { coordinator.capture(mode) }
                    .padding(.bottom, 96)
            }
            .padding(.horizontal, 20)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            #if !targetEnvironment(simulator)
            camera.requestAndStart()
            #endif
        }
        .onDisappear {
            #if !targetEnvironment(simulator)
            camera.stop()
            #endif
        }
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
    let onShutter: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(MJColor.gold).frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.35)
                Text(mode == .score ? "Looking for tiles…" : "Ready to coach your hand")
                    .font(MJFont.ui(13, weight: .semibold))
                    .foregroundStyle(MJColor.cream)
            }

            Button(action: onShutter) {
                Circle()
                    .fill(LinearGradient(colors: [MJColor.lightGold, MJColor.gold],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 56, height: 56)
                    .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 3).padding(3) }
                    .shadow(color: MJColor.gold(0.4), radius: 6, y: 4)
            }
            .buttonStyle(.plain)
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
