import SwiftUI

// MARK: - Buttons

/// Primary gold CTA (spec §3.4).
public struct GoldButton: View {
    private let title: String
    private let withShadow: Bool
    private let action: () -> Void

    public init(_ title: String, withShadow: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.withShadow = withShadow
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(MJFont.ui(15, weight: .bold))
                .foregroundStyle(MJColor.inkOnGold)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    LinearGradient(colors: [MJColor.lightGold, MJColor.gold],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .shadow(color: withShadow ? MJColor.gold(0.3) : .clear,
                radius: withShadow ? 11 : 0, y: withShadow ? 8 : 0)
    }
}

/// Secondary gold-outline button (spec §3.4).
public struct SecondaryButton: View {
    private let title: String
    private let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(MJFont.ui(13, weight: .semibold))
                .foregroundStyle(MJColor.gold)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(MJColor.gold(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(MJColor.gold(0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

/// Bare text link ("Maybe later").
public struct TextLink: View {
    private let title: String
    private let action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title).font(MJFont.ui(13, weight: .medium)).foregroundStyle(MJColor.cream(0.55))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pills, tags, chips

/// Gold status pill ("1-shanten", "→ 128 points").
public struct StatusPill: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(MJFont.ui(12, weight: .semibold))
            .foregroundStyle(MJColor.inkOnGold)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(MJColor.gold, in: Capsule())
    }
}

/// Amber warning pill ("1 to fix").
public struct WarningPill: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(MJFont.ui(11, weight: .semibold))
            .foregroundStyle(MJColor.amberWarn)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(MJColor.amberLowConf.opacity(0.16), in: Capsule())
    }
}

/// BEST / AVOID / detail tag (spec §3.6).
public struct MJTag: View {
    public enum Kind { case best, avoid, detail }
    private let text: String
    private let kind: Kind
    public init(_ text: String, kind: Kind) { self.text = text; self.kind = kind }

    public var body: some View {
        Text(text)
            .font(MJFont.ui(kind == .detail ? 10 : 9, weight: kind == .detail ? .semibold : .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, kind == .detail ? 10 : 6)
            .padding(.vertical, kind == .detail ? 4 : 2)
            .background(bg, in: Capsule())
    }

    private var fg: Color {
        switch kind {
        case .best: return MJColor.inkOnGold
        case .avoid: return .white
        case .detail: return MJColor.gold
        }
    }
    private var bg: Color {
        switch kind {
        case .best: return MJColor.gold
        case .avoid: return MJColor.rustAvoid
        case .detail: return MJColor.gold(0.12)
        }
    }
}

/// Suit / category filter chip (spec §3.6).
public struct FilterChip: View {
    private let text: String
    private let active: Bool
    private let action: () -> Void
    public init(_ text: String, active: Bool, action: @escaping () -> Void) {
        self.text = text; self.active = active; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(text)
                .font(MJFont.ui(11, weight: .semibold))
                .foregroundStyle(active ? MJColor.inkOnGold : MJColor.cream(0.6))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(active ? AnyShapeStyle(MJColor.gold) : AnyShapeStyle(MJColor.cardRaised),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards & sheets

public extension View {
    /// Standard info/list card, or a selected jade-gradient card.
    func mjCard(cornerRadius: CGFloat = 16, selected: Bool = false, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(colors: [MJColor.jade, MJColor.deepJade],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(MJColor.cardSurface))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(selected ? MJColor.gold : MJColor.gold(0.13),
                                          lineWidth: selected ? 1.5 : 1)
                    }
            }
    }
}

/// The grabber at the top of a bottom sheet.
public struct SheetGrabber: View {
    public init() {}
    public var body: some View {
        Capsule().fill(MJColor.gold(0.3)).frame(width: 34, height: 4)
    }
}

// MARK: - Segmented toggle (Score / Coach, Self-draw / By discard, …)

public struct SegmentedToggle<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [(value: Value, label: String)]
    private let fontSize: CGFloat
    private let hPad: CGFloat
    private let vPad: CGFloat

    public init(selection: Binding<Value>, options: [(value: Value, label: String)],
                fontSize: CGFloat = 11, hPad: CGFloat = 14, vPad: CGFloat = 5) {
        self._selection = selection
        self.options = options
        self.fontSize = fontSize
        self.hPad = hPad
        self.vPad = vPad
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isActive = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(MJFont.ui(fontSize, weight: .semibold))
                        .foregroundStyle(isActive ? MJColor.inkOnGold : MJColor.creamStatus)
                        .padding(.horizontal, hPad).padding(.vertical, vPad)
                        .background {
                            if isActive {
                                Capsule(style: .continuous).fill(MJColor.gold)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            Capsule().fill(MJColor.jade.opacity(0.25))
        }
        .overlay { Capsule().strokeBorder(MJColor.gold(0.3), lineWidth: 1) }
    }
}
