import SwiftUI
import DesignSystem

/// Four dots showing how many copies of a tile have been accounted for.
///
/// Tracker can pass separate `table` / `hand` counts so table pips stay gold
/// and hand pips use a cream accent — Coach Live keeps the single `seen` API.
struct SeenPips: View {
    let table: Int
    let hand: Int
    let total: Int
    let scale: CGFloat

    /// Coach Live / single-source counts — all lit pips are gold.
    init(seen: Int, of total: Int = 4, scale: CGFloat = 1) {
        self.table = seen
        self.hand = 0
        self.total = total
        self.scale = scale
    }

    /// Tracker split: gold = table, cream = hand, dim = remaining.
    init(table: Int, hand: Int, of total: Int = 4, scale: CGFloat = 1) {
        self.table = max(0, table)
        self.hand = max(0, hand)
        self.total = total
        self.scale = scale
    }

    var body: some View {
        let lit = min(total, table + hand)
        HStack(spacing: 2 * scale) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(fill(for: i))
                    .frame(width: 4.5 * scale, height: 4.5 * scale)
            }
        }
        .animation(.easeOut(duration: 0.2), value: lit)
        .accessibilityLabel(accessibilityText)
    }

    private func fill(for index: Int) -> Color {
        if index < table { return MJColor.gold(0.9) }
        if index < table + hand { return MJColor.cream(0.85) }
        return Color.white.opacity(0.12)
    }

    private var accessibilityText: String {
        if hand > 0 {
            return "Table \(table), hand \(hand), of \(total)"
        }
        return "Seen \(table) of \(total)"
    }
}

#if DEBUG
#Preview("SeenPips") {
    VStack(spacing: 12) {
        SeenPips(seen: 0)
        SeenPips(seen: 2)
        SeenPips(table: 1, hand: 2)
        SeenPips(table: 2, hand: 2, scale: 2)
    }
    .padding()
    .screenBackground(.content)
}
#endif
