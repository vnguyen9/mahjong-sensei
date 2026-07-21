import SwiftUI
import DesignSystem
import MahjongCore

/// Event log rows: tile faces + amber wait-impact chips + relative
/// timestamps (UI plan §9 EventsTab).
struct EventsTab: View {
    @Environment(CoachLiveSession.self) private var session
    @Environment(\.liveControlMetrics) private var metrics
    let onTapEvent: (UUID) -> Void

    private var newestFirst: [TableEvent] { Array(session.events.reversed()) }

    var body: some View {
        // 5s cadence is enough to keep "8s / 26s / 1m" ages fresh without
        // re-rendering the whole log every tick.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            ScrollView {
                VStack(spacing: 6) {
                    if newestFirst.isEmpty {
                        Text("No events yet.")
                            .font(MJFont.ui(12 * metrics.scale)).foregroundStyle(MJColor.cream(0.5))
                            .padding(.top, 20)
                    }
                    ForEach(newestFirst) { event in
                        Button { onTapEvent(event.id) } label: { row(event) }
                            .buttonStyle(.plain)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func row(_ event: TableEvent) -> some View {
        HStack(spacing: 8) {
            Text(windEnglish(event.actor))
                .font(MJFont.ui(12.5 * metrics.scale, weight: .semibold)).foregroundStyle(MJColor.cream)
            Text(event.verb)
                .font(MJFont.ui(12.5 * metrics.scale)).foregroundStyle(MJColor.cream(0.6))
            TileRow(event.tiles, theme: .jade, width: 18 * metrics.scale, spacing: 1.5 * metrics.scale)
            if let delta = event.waitDelta {
                Text("wait \(delta > 0 ? "+" : "")\(delta)")
                    .font(MJFont.ui(10 * metrics.scale, weight: .bold))
                    .foregroundStyle(MJColor.inkOnAmber)
                    .padding(.horizontal, 7 * metrics.scale).padding(.vertical, 3 * metrics.scale)
                    .background(MJColor.amberZone, in: Capsule())
            }
            Spacer(minLength: 0)
            Text(Self.compactAge(event.date))
                .font(MJFont.ui(11 * metrics.scale)).foregroundStyle(MJColor.cream(0.4))
        }
        .padding(.horizontal, 10 * metrics.scale).padding(.vertical, 8 * metrics.scale)
        .frame(minHeight: metrics.minimumEditHitTarget)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10 * metrics.scale, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10 * metrics.scale, style: .continuous).strokeBorder(MJColor.gold(0.12), lineWidth: 1) }
    }

    /// "8s", "26s", "1m", "1m 20s" — custom because `RelativeDateTimeFormatter`
    /// is too verbose for a dense log row.
    static func compactAge(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60, s = seconds % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}
