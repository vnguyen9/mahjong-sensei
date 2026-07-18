import SwiftUI
import DesignSystem
import MahjongCore

/// Identifiable wrapper so a `MeldKind` can drive `.sheet(item:)`.
struct MeldSelection: Identifiable {
    let kind: MeldKind
    var id: String { kind.rawValue }
    init(_ kind: MeldKind) { self.kind = kind }
}

/// Example sheet for a meld type (chow / pung / kong / pair): a few representative
/// groups plus a one-line description. Styled like `TileDetailSheet` — a single
/// pinned grabber, system drag indicator hidden (no double handle).
struct MeldExampleSheet: View {
    let kind: MeldKind

    var body: some View {
        ZStack {
            MJColor.sheetGlass.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetGrabber()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(title)
                                .font(MJFont.serif(20, weight: .bold))
                                .foregroundStyle(MJColor.creamHeading)
                            Text(zh)
                                .font(MJFont.serif(15))
                                .foregroundStyle(MJColor.gold)
                            Spacer(minLength: 0)
                        }

                        Text(blurb)
                            .font(MJFont.ui(13))
                            .foregroundStyle(MJColor.cream(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(examples.enumerated()), id: \.offset) { _, group in
                                TileRow(group, theme: .ivory, width: 34, spacing: 3)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(20)
                    .padding(.bottom, 28)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
    }

    private var title: String {
        switch kind {
        case .chow: return "Chow"
        case .pung: return "Pung"
        case .kong: return "Kong"
        case .pair: return "Pair"
        }
    }

    private var zh: String {
        switch kind {
        case .chow: return "順子"
        case .pung: return "刻子"
        case .kong: return "槓"
        case .pair: return "對子 · 眼"
        }
    }

    private var blurb: String {
        switch kind {
        case .chow: return "Three consecutive tiles of one suit. Honors and bonus tiles can't form runs."
        case .pung: return "Three identical tiles. A pung of dragons — or of your seat/round wind — scores faan."
        case .kong: return "Four identical tiles. You declare it and draw a replacement; it scores like a pung."
        case .pair: return "Two identical tiles — the “eyes” that complete a hand of four sets + one pair."
        }
    }

    private var examples: [[Tile]] {
        switch kind {
        case .chow: return [[.p(1), .p(2), .p(3)], [.s(4), .s(5), .s(6)], [.m(7), .m(8), .m(9)]]
        case .pung: return [[.redDragon, .redDragon, .redDragon], [.p(5), .p(5), .p(5)], [.east, .east, .east]]
        case .kong: return [[.greenDragon, .greenDragon, .greenDragon, .greenDragon], [.s(9), .s(9), .s(9), .s(9)]]
        case .pair: return [[.whiteDragon, .whiteDragon], [.east, .east], [.m(2), .m(2)]]
        }
    }
}
