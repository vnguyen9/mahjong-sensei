import SwiftUI
import DesignSystem

/// Four dots showing how many copies of a tile have been seen — lit gold for
/// each seen copy, dim for the rest (UI plan §3/§9). Used by `CountsTab` and
/// `WaitChips`.
///
/// Per the plan this is pure, dependency-free SwiftUI that belongs in
/// `DesignSystem` — kept app-local here for the same `Packages/` ownership
/// reason as `CoachLivePalette.swift`; trivial to relocate later.
struct SeenPips: View {
    let seen: Int
    let total: Int
    /// Scales the 4.5pt dot / 2pt gap pair uniformly (the Counts-adjust sheet
    /// renders these at 2× per the plan).
    let scale: CGFloat

    init(seen: Int, of total: Int = 4, scale: CGFloat = 1) {
        self.seen = seen
        self.total = total
        self.scale = scale
    }

    var body: some View {
        HStack(spacing: 2 * scale) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < seen ? MJColor.gold(0.9) : Color.white.opacity(0.12))
                    .frame(width: 4.5 * scale, height: 4.5 * scale)
            }
        }
        .animation(.easeOut(duration: 0.2), value: seen)
        .accessibilityLabel("Seen \(seen) of \(total)")
    }
}

#if DEBUG
#Preview("SeenPips") {
    VStack(spacing: 12) {
        SeenPips(seen: 0)
        SeenPips(seen: 2)
        SeenPips(seen: 4)
        SeenPips(seen: 2, scale: 2)
    }
    .padding()
    .screenBackground(.content)
}
#endif
