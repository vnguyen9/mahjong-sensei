import SwiftUI
import DesignSystem
import MahjongCore
import Recognition

/// Lane 2 · Aim at your hand (spec screen 5). Simulated camera ground for the
/// simulator; the live `AVCaptureVideoPreviewLayer` drops in behind this later.
struct ScanView: View {
    private enum Mode: Hashable { case score, coach }
    @State private var mode: Mode = .score
    @State private var showResult = false

    var body: some View {
        ZStack {
            ScreenBackground(.camera)

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    SegmentedToggle(selection: $mode,
                                    options: [(Mode.score, "Score"), (Mode.coach, "Coach")])
                    HintPill(text: mode == .score
                             ? "Lay your hand flat, face-up"
                             : "I'll suggest your best discard")
                }
                .padding(.top, 16)

                Spacer()
                ScanReticle()
                    .frame(width: 300, height: 150)
                Spacer()

                ScanStatusCard { showResult = true }
                    .padding(.bottom, 96)
            }
            .padding(.horizontal, 20)
        }
        .fullScreenCover(isPresented: $showResult) {
            ResultView(result: MockHands.winning)
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
    let onShutter: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(MJColor.gold).frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.35)
                Text("Looking for tiles…")
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
