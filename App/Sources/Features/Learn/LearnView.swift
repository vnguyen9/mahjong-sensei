import SwiftUI
import DesignSystem
import MahjongCore

/// Lane 4 · Learn — the hub (spec §1 lane 4). A `NavigationStack` whose root
/// links to four teaching destinations: the tiles primer, the faan cheat
/// sheet, the searchable tile dictionary, and the interactive wind explainer.
struct LearnView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground(.content)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        NavigationLink { LearnBasicsView() } label: {
                            hubCard(title: "The tiles", zh: "牌",
                                    subtitle: "Suits, honors, and how a hand is built.") {
                                MahjongTileView(.p(5), theme: .jade, width: 40)
                            }
                        }
                        .buttonStyle(.plain)

                        NavigationLink { ScoringCheatSheetView() } label: {
                            hubCard(title: "Scoring cheat sheet", zh: "番數",
                                    subtitle: "Every faan pattern and what it's worth.") {
                                faanBadge
                            }
                        }
                        .buttonStyle(.plain)

                        NavigationLink { TileDictionaryView() } label: {
                            hubCard(title: "Tile dictionary", zh: "字典",
                                    subtitle: "All 42 faces — names, sounds, and lore.") {
                                MahjongTileView(.s(1), theme: .jade, width: 40)
                            }
                        }
                        .buttonStyle(.plain)

                        NavigationLink { WindExplainerView() } label: {
                            hubCard(title: "Seats & winds", zh: "門風",
                                    subtitle: "The compass behind the #1 confusion.") {
                                MahjongTileView(.east, theme: .jade, width: 40)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Learn 學")
                .font(MJFont.serif(26, weight: .bold))
                .foregroundStyle(MJColor.creamHeading)
            Text("The basics, the tiles, and the points — between the games.")
                .font(MJFont.ui(13))
                .foregroundStyle(MJColor.cream(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var faanBadge: some View {
        Text("番")
            .font(MJFont.serif(24, weight: .bold))
            .foregroundStyle(MJColor.gold)
            .frame(width: 40, height: 54)
            .background(MJColor.gold(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MJColor.gold(0.3), lineWidth: 1)
            }
    }

    private func hubCard<Leading: View>(title: String, zh: String, subtitle: String,
                                        @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 14) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(MJFont.ui(15, weight: .semibold))
                        .foregroundStyle(MJColor.creamHeading)
                    Text(zh)
                        .font(MJFont.serif(13, weight: .regular))
                        .foregroundStyle(MJColor.gold(0.8))
                }
                Text(subtitle)
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MJColor.cream(0.4))
        }
        .mjCard(cornerRadius: 16)
    }
}

/// Shared back header for pushed Learn / Settings destinations (spec screens 7,
/// 10, 21 — "‹ Title" in the serif face). Defined once here and reused across
/// the app module.
struct MJBackHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MJColor.gold)
                    Text(title)
                        .font(MJFont.serif(20, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityAddTraits(.isHeader)
    }
}
