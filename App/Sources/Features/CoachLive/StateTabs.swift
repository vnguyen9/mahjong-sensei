import SwiftUI
import DesignSystem

/// The Map ⇄ Counts ⇄ Events state pane tabs (UI plan §9).
enum LiveTab: String, CaseIterable, Hashable {
    case map, counts, events

    var label: String {
        switch self {
        case .map:    return "Map"
        case .counts: return "Counts"
        case .events: return "Events"
        }
    }
}

/// Full-width segmented bar for Map / Counts / Events — a distinct, app-local
/// geometry from `SegmentedToggle` (that one keeps its capsule-pill style for
/// Scan; this is a flex-equal rounded-rect bar). Fixed-height row: never
/// hides under compression (UI plan §8/§9).
struct LiveSegmentedBar: View {
    @Binding var selection: LiveTab
    @Environment(\.liveControlMetrics) private var metrics

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LiveTab.allCases, id: \.self) { item in
                let active = item == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = item }
                } label: {
                    Text(item.label)
                        .font(MJFont.ui(13 * metrics.scale, weight: .bold))
                        .foregroundStyle(active ? MJColor.inkOnGold : MJColor.cream(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: metrics.segmentedHeight)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 10 * metrics.scale, style: .continuous).fill(MJColor.gold)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3 * metrics.scale)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12 * metrics.scale, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}
