import SwiftUI
import DesignSystem
import MahjongCore

/// Lane 1 · Onboarding — the four-step first run (spec screens 1–4):
/// Welcome → Pick your style → Set your table → Camera primer. No account; the
/// final step finishes via `app.completeOnboarding()`.
struct OnboardingView: View {
    @Environment(AppState.self) private var app

    @State private var step = 1
    @State private var style: Style = .hongKong
    @State private var preset: TablePreset = .family

    private enum Style: Hashable { case hongKong, riichi, taiwanese }
    private enum TablePreset: Hashable { case family, club, custom }

    var body: some View {
        ZStack {
            ScreenBackground(step == 1 || step == 4 ? .welcome : .content)
            Group {
                switch step {
                case 1:  welcome
                case 2:  pickStyle
                case 3:  setTable
                default: cameraPrimer
                }
            }
            .id(step)
            .transition(.opacity)
            // Readable-width column so onboarding content stays centered rather
            // than stretching edge-to-edge on a wide iPad.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func advance() { withAnimation(.smooth) { step += 1 } }
    private func finish()  { withAnimation(.smooth) { app.completeOnboarding() } }

    // MARK: 1 · Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()

            MahjongTileView(.redDragon, theme: .jade, width: 62, showsBadge: false)
                .padding(.bottom, 26)

            Text("Mahjong Sensei")
                .font(MJFont.serif(30, weight: .bold))
                .foregroundStyle(MJColor.lightGold)

            Text("麻雀先生")
                .font(MJFont.ui(12))
                .tracking(6)
                .foregroundStyle(MJColor.cream(0.5))
                .padding(.top, 10)

            VStack(spacing: 3) {
                Text("Point your phone at the tiles.")
                Text("Get the score, and the reason why.")
            }
            .font(MJFont.ui(16))
            .foregroundStyle(MJColor.cream(0.7))
            .multilineTextAlignment(.center)
            .padding(.top, 24)

            Spacer()

            GoldButton("Get started", withShadow: true) { advance() }
            Text("100% on-device · works offline")
                .font(MJFont.ui(11, weight: .medium))
                .foregroundStyle(MJColor.cream(0.5))
                .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 44)
    }

    // MARK: 2 · Pick your style

    private var pickStyle: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepDots.padding(.top, 12)

            heading("Which style do you play?",
                    "Tunes scoring & coaching to your table.")
                .padding(.top, 20)

            VStack(spacing: 12) {
                OptionRow(tile: .redDragon, name: "Hong Kong", meta: "廣東麻雀 · 13 · faan",
                          selected: style == .hongKong) { style = .hongKong }
                OptionRow(tile: .p(1), name: "Riichi", meta: "日本麻雀 · 13",
                          selected: style == .riichi) { style = .riichi }
                OptionRow(tile: .s(1), name: "Taiwanese 16", meta: "台灣麻將 · 16",
                          selected: style == .taiwanese) { style = .taiwanese }
            }
            .padding(.top, 24)

            Spacer()

            GoldButton("Continue") { advance() }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 44)
    }

    // MARK: 3 · Set your table

    private var setTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepDots.padding(.top, 12)

            heading("How does your table score?",
                    "Faan tables aren't standardized. Start from a preset — fine-tune anytime.")
                .padding(.top, 20)

            VStack(spacing: 12) {
                PresetRow(name: "Family default", detail: "3 faan min · half-spicy · limit 10 · flowers on",
                          style: .selectable(selected: preset == .family)) { preset = .family }
                PresetRow(name: "Common club", detail: "3 faan · full-spicy · limit 13",
                          style: .selectable(selected: preset == .club)) { preset = .club }
                PresetRow(name: "Custom…", detail: nil,
                          style: .disclosure) { preset = .custom }
            }
            .padding(.top, 24)

            Spacer()

            GoldButton("Continue") { advance() }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 44)
    }

    // MARK: 4 · Camera primer

    private var cameraPrimer: some View {
        VStack(spacing: 0) {
            stepDots.padding(.top, 12)

            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(MJColor.gold(0.12))
                    .frame(width: 76, height: 76)
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(MJColor.gold(0.35), lineWidth: 1)
                    }
                Image(systemName: "viewfinder")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(MJColor.gold)
            }
            .padding(.bottom, 24)

            Text("Read tiles with the camera")
                .font(MJFont.serif(22, weight: .bold))
                .foregroundStyle(MJColor.creamHeading)
                .multilineTextAlignment(.center)

            Text(primerBody)
                .font(MJFont.ui(14))
                .foregroundStyle(MJColor.cream(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .padding(.horizontal, 4)

            Spacer()

            GoldButton("Enable camera", withShadow: true) { finish() }
            TextLink("Maybe later") { finish() }
                .padding(.top, 14)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 44)
    }

    /// Body copy with "on your device" / "never leave your phone" emphasized.
    private var primerBody: AttributedString {
        func emphasized(_ text: String) -> AttributedString {
            var container = AttributeContainer()
            container.foregroundColor = MJColor.lightGold
            return AttributedString(text, attributes: container)
        }
        var body = AttributedString("Mahjong Sensei reads tiles ")
        body.append(emphasized("on your device"))
        body.append(AttributedString(". Images are processed live and "))
        body.append(emphasized("never leave your phone"))
        body.append(AttributedString(" — nothing is uploaded or stored."))
        return body
    }

    // MARK: Shared pieces

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MJFont.serif(24, weight: .bold))
                .foregroundStyle(MJColor.creamHeading)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(MJFont.ui(14))
                .foregroundStyle(MJColor.cream(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(1...4, id: \.self) { i in
                Capsule()
                    .fill(i == step ? AnyShapeStyle(MJColor.gold) : AnyShapeStyle(MJColor.cream(0.22)))
                    .frame(width: i == step ? 18 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text("Step \(step) of 4"))
    }
}

// MARK: - Selectable style row (spec screen 2)

private struct OptionRow: View {
    let tile: Tile
    let name: String
    let meta: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                MahjongTileView(tile, theme: .jade, width: 30, showsBadge: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(MJFont.ui(15, weight: .semibold))
                        .foregroundStyle(MJColor.creamHeading)
                    Text(meta)
                        .font(MJFont.serif(12, weight: .regular))
                        .foregroundStyle(MJColor.gold(0.8))
                }
                Spacer()
                SelectionMark(selected: selected)
            }
            .mjCard(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Table preset row (spec screen 3)

private struct PresetRow: View {
    enum Style { case selectable(selected: Bool), disclosure }

    let name: String
    let detail: String?
    let style: Style
    let onTap: () -> Void

    private var isSelected: Bool {
        if case let .selectable(selected) = style { return selected }
        return false
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(MJFont.ui(15, weight: .semibold))
                        .foregroundStyle(MJColor.creamHeading)
                    if let detail {
                        Text(detail)
                            .font(MJFont.ui(11.5))
                            .foregroundStyle(MJColor.cream(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                switch style {
                case .selectable(let selected):
                    SelectionMark(selected: selected)
                case .disclosure:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MJColor.gold(0.7))
                }
            }
            .mjCard(selected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Selection indicator

private struct SelectionMark: View {
    let selected: Bool
    var body: some View {
        if selected {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MJColor.inkOnGold)
                .frame(width: 22, height: 22)
                .background(MJColor.gold, in: Circle())
        } else {
            Circle()
                .strokeBorder(MJColor.gold(0.35), lineWidth: 1.5)
                .frame(width: 22, height: 22)
        }
    }
}
