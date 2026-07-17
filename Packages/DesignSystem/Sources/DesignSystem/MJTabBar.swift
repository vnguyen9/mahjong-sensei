import SwiftUI
import MahjongCore

/// The three top-level destinations (spec §3.3 — Scan / Learn / Settings).
public enum MJTab: String, CaseIterable, Identifiable, Sendable {
    case scan, learn, settings
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var systemImage: String {
        switch self {
        case .scan: return "viewfinder"
        case .learn: return "book.closed"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// The floating, pill-shaped bottom tab bar (spec §3.3). Positioned by the caller
/// (design floats it ~16pt above the home indicator).
public struct MJTabBar: View {
    @Binding private var selection: MJTab
    public init(selection: Binding<MJTab>) { self._selection = selection }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(MJTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(6)
        .background {
            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            Capsule().fill(Color(hex: 0x1E1E20, alpha: 0.55))
        }
        .overlay { Capsule().strokeBorder(Color(white: 1, opacity: 0.16), lineWidth: 1) }
        .shadow(color: Color(white: 0, opacity: 0.45), radius: 15, y: 12)
    }

    private func tabButton(_ tab: MJTab) -> some View {
        let isActive = tab == selection
        return Button {
            withAnimation(.snappy(duration: 0.22)) { selection = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(tab.title).font(MJFont.tabLabel)
            }
            .foregroundStyle(isActive ? MJColor.cream : Color(white: 1, opacity: 0.55))
            .padding(.horizontal, 15).padding(.vertical, 6)
            .background {
                if isActive {
                    Capsule().fill(MJColor.jadeAccent)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.title))
    }
}

/// A horizontal row of tiles (hand tray / meld strip helper).
public struct TileRow: View {
    private let tiles: [Tile]
    private let theme: TileTheme
    private let width: CGFloat
    private let spacing: CGFloat
    private let showsBadges: Bool

    public init(_ tiles: [Tile], theme: TileTheme = .jade, width: CGFloat = 24,
                spacing: CGFloat = 3, showsBadges: Bool = true) {
        self.tiles = tiles; self.theme = theme; self.width = width
        self.spacing = spacing; self.showsBadges = showsBadges
    }

    public var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                MahjongTileView(tile, theme: theme, width: width, showsBadge: showsBadges)
            }
        }
    }
}
