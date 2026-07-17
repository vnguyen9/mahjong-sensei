import SwiftUI
import DesignSystem
import MahjongCore
import Recognition

/// Lane 2 · Tiles detected (spec screen 6). Bounding boxes + confidence over the
/// (simulated) camera ground; low-confidence tiles flagged amber.
struct DetectedView: View {
    @Environment(ScanCoordinator.self) private var coordinator
    private var session: ScanSession { coordinator.session }

    var body: some View {
        ZStack {
            ScreenBackground(.camera)
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 10) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 9) {
                            ForEach(row) { detected in
                                DetectedTileBox(detected: detected)
                            }
                        }
                    }
                }
                Spacer()

                VStack(spacing: 12) {
                    Text("\(session.recognized.tiles.count) tiles found")
                        .font(MJFont.ui(15, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)
                    Text(session.lowConfidenceCount > 0
                         ? "\(session.lowConfidenceCount) low-confidence · tap to review"
                         : "Looks clean")
                        .font(MJFont.ui(11, weight: .medium))
                        .foregroundStyle(session.lowConfidenceCount > 0 ? MJColor.gold : MJColor.cream(0.6))
                    GoldButton("Review tiles →") { coordinator.push(.correct) }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .glassPanel()
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Two rows of up to 7 for a flat 13–14 tile hand.
    private var rows: [[DetectedTile]] {
        let tiles = session.recognized.tiles
        return stride(from: 0, to: tiles.count, by: 7).map { Array(tiles[$0..<min($0 + 7, tiles.count)]) }
    }
}

private struct DetectedTileBox: View {
    let detected: DetectedTile

    var body: some View {
        MahjongTileView(detected.tile, theme: .ivory, width: 24)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(detected.isLowConfidence ? MJColor.amberLowConf : MJColor.gold(0.9),
                                  lineWidth: detected.isLowConfidence ? 2 : 1.5)
                    .padding(-3)
            }
            .overlay(alignment: .topTrailing) {
                if detected.isLowConfidence {
                    Text("?")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: 0x1A1A1A))
                        .frame(width: 14, height: 14)
                        .background(MJColor.amberLowConf, in: Circle())
                        .offset(x: 5, y: -6)
                }
            }
            .shadow(color: detected.isLowConfidence ? .clear : MJColor.gold(0.45), radius: 4)
    }
}

// MARK: - Shared glass panel (scan flow cards & sheets)

extension View {
    /// A dark frosted panel matching the scan-flow status cards (spec §3.5).
    func glassPanel(cornerRadius: CGFloat = 20, tint: Double = 0.5) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color(hex: 0x0D2D25, alpha: tint))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(MJColor.gold(0.16), lineWidth: 1)
        }
    }
}
