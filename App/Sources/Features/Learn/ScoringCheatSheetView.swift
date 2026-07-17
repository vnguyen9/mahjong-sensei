import SwiftUI
import DesignSystem
import ScoringEngine

/// Lane 4 · Learn — the faan reference table. Iterates `FaanCategory.allCases`,
/// shows each pattern's EN + 繁中 name, its value from `FaanTable.standard`, and
/// a one-line plain-English description, grouped into readable tiers.
struct ScoringCheatSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "Scoring 番數") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        introCard
                        ForEach(Tier.allCases, id: \.self) { tier in
                            section(tier)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Intro

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How points work").eyebrowStyle()
            Text("Every winning hand adds up its faan (番). Your table sets a minimum to win and a limit that caps the top hands — more faan means exponentially more points.")
                .font(MJFont.ui(12))
                .foregroundStyle(MJColor.cream(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            Text("Values shown are Hong Kong Old Style — the Family preset.")
                .font(MJFont.ui(11))
                .foregroundStyle(MJColor.gold(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mjCard()
    }

    // MARK: Sections

    private func section(_ tier: Tier) -> some View {
        let items = FaanCategory.allCases.filter { self.tier(for: $0) == tier }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(tier.title).eyebrowStyle()
                if let zh = tier.zh {
                    Text(zh)
                        .font(MJFont.serif(11, weight: .regular))
                        .foregroundStyle(MJColor.gold(0.6))
                }
            }
            .padding(.leading, 2)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, category in
                    row(category)
                    if i < items.count - 1 {
                        Divider().overlay(MJColor.gold(0.12))
                    }
                }
            }
            .mjCard(padding: 4)
        }
    }

    private func row(_ c: FaanCategory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.englishName)
                        .font(MJFont.ui(13, weight: .semibold))
                        .foregroundStyle(MJColor.creamHeading)
                    Text(c.traditionalChineseName)
                        .font(MJFont.serif(12, weight: .regular))
                        .foregroundStyle(MJColor.gold(0.75))
                }
                Text(description(c))
                    .font(MJFont.ui(11.5))
                    .foregroundStyle(MJColor.cream(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
            }
            Spacer(minLength: 8)
            faanValue(c)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func faanValue(_ c: FaanCategory) -> some View {
        let value = FaanTable.standard[c]
        return VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)")
                    .font(MJFont.serif(16, weight: .bold))
                    .foregroundStyle(value == 0 ? MJColor.cream(0.5) : MJColor.gold)
                Text("番")
                    .font(MJFont.serif(10, weight: .regular))
                    .foregroundStyle(value == 0 ? MJColor.cream(0.4) : MJColor.gold(0.7))
            }
            if c.isLimitHand {
                Text("limit 滿")
                    .font(MJFont.ui(8.5, weight: .semibold))
                    .foregroundStyle(MJColor.cream(0.45))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(c.isLimitHand ? "\(value) faan, a limit hand" : "\(value) faan"))
    }

    // MARK: Tiers

    private enum Tier: Int, CaseIterable, Hashable {
        case circumstance, common, big, limit
        var title: String {
            switch self {
            case .circumstance: return "Circumstance"
            case .common:       return "Common patterns"
            case .big:          return "Big hands"
            case .limit:        return "Limit hands"
            }
        }
        var zh: String? {
            switch self {
            case .circumstance: return "出牌"
            case .common:       return "常見"
            case .big:          return "大牌"
            case .limit:        return "滿糊"
            }
        }
    }

    private func tier(for c: FaanCategory) -> Tier {
        if c.isLimitHand { return .limit }
        switch c {
        case .chickenHand, .selfDraw, .fullyConcealed, .seatFlower, .noFlowers,
             .winOnKongReplacement, .robbingKong, .lastTile:
            return .circumstance
        case .dragonPung, .prevailingWindPung, .seatWindPung, .allTriplets, .halfFlush:
            return .common
        case .fullFlush, .smallThreeDragons, .smallFourWinds, .sevenPairs:
            return .big
        default:
            return .common
        }
    }

    // MARK: Plain-English descriptions

    private func description(_ c: FaanCategory) -> String {
        switch c {
        case .chickenHand:          return "A complete shape with no scoring pattern — worth zero, so it can't clear the minimum."
        case .selfDraw:             return "You drew your own winning tile from the wall."
        case .fullyConcealed:       return "You won on a discard, having never revealed a meld."
        case .seatFlower:           return "A flower or season matching your seat — one faan each."
        case .noFlowers:            return "You finished without drawing any flower or season."
        case .winOnKongReplacement: return "You won on the replacement tile drawn after a kong."
        case .robbingKong:          return "You won by claiming the tile added to another player's kong."
        case .lastTile:             return "You won on the very last tile of the wall or the last discard."
        case .dragonPung:           return "A triplet of dragons (中/發/白) — one faan per set, whatever your seat."
        case .prevailingWindPung:   return "A triplet of the round's prevailing wind."
        case .seatWindPung:         return "A triplet of your own seat wind."
        case .allTriplets:          return "Every set is a triplet or kong — no runs at all."
        case .halfFlush:            return "One number suit plus honor tiles only."
        case .fullFlush:            return "A single number suit end to end, with no honors."
        case .smallThreeDragons:    return "Two dragon triplets plus a pair of the third dragon."
        case .smallFourWinds:       return "Three wind triplets plus a pair of the fourth wind."
        case .sevenPairs:           return "Seven distinct pairs instead of four sets and a pair."
        case .bigThreeDragons:      return "Triplets of all three dragons — scored at the limit."
        case .bigFourWinds:         return "Triplets of all four winds — scored at the limit."
        case .allHonors:            return "Every tile is a wind or dragon — scored at the limit."
        case .allTerminals:         return "Every tile is a terminal 1 or 9, no honors — scored at the limit."
        case .thirteenOrphans:      return "One of each terminal and honor, plus a duplicate — scored at the limit."
        case .nineGates:            return "A concealed 1-1-1-2-3-4-5-6-7-8-9-9-9 flush — scored at the limit."
        }
    }
}
