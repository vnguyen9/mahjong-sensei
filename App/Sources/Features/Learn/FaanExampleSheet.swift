import SwiftUI
import DesignSystem
import MahjongCore
import ScoringEngine

/// Identifiable wrapper so a `FaanCategory` can drive `.sheet(item:)`.
struct FaanSelection: Identifiable {
    let category: FaanCategory
    var id: String { category.rawValue }
    init(_ category: FaanCategory) { self.category = category }
}

/// Plain-English description + a representative example hand for each HK scoring
/// pattern. Shared by the scoring cheat sheet and the example sheet.
enum FaanInfo {
    static func description(_ c: FaanCategory) -> String {
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

    /// A representative example hand, grouped into its sets (each inner array is one
    /// meld / pair) so it renders with the shape visible. Empty for circumstance
    /// patterns that are about *how* you win, not the tiles.
    static func example(_ c: FaanCategory) -> [[Tile]] {
        func trip(_ t: Tile) -> [Tile] { Array(repeating: t, count: 3) }
        func pair(_ t: Tile) -> [Tile] { [t, t] }

        switch c {
        case .dragonPung:         return [trip(.redDragon)]
        case .prevailingWindPung: return [trip(.east)]
        case .seatWindPung:       return [trip(.south)]
        case .allTriplets:        return [trip(.p(5)), trip(.east), trip(.s(9)), trip(.m(3)), pair(.whiteDragon)]
        case .halfFlush:          return [[.p(1), .p(2), .p(3)], trip(.p(5)), [.p(7), .p(8), .p(9)], trip(.redDragon), pair(.east)]
        case .fullFlush:          return [[.p(1), .p(2), .p(3)], [.p(4), .p(5), .p(6)], [.p(7), .p(8), .p(9)], [.p(2), .p(3), .p(4)], pair(.p(5))]
        case .smallThreeDragons:  return [trip(.redDragon), trip(.greenDragon), pair(.whiteDragon), [.p(1), .p(2), .p(3)], trip(.s(5))]
        case .smallFourWinds:     return [trip(.east), trip(.south), trip(.west), pair(.north), trip(.p(5))]
        case .sevenPairs:         return [pair(.p(1)), pair(.p(3)), pair(.m(5)), pair(.east), pair(.redDragon), pair(.s(9)), pair(.s(2))]
        case .bigThreeDragons:    return [trip(.redDragon), trip(.greenDragon), trip(.whiteDragon), [.p(1), .p(2), .p(3)], pair(.s(5))]
        case .bigFourWinds:       return [trip(.east), trip(.south), trip(.west), trip(.north), pair(.p(5))]
        case .allHonors:          return [trip(.east), trip(.south), trip(.redDragon), trip(.whiteDragon), pair(.greenDragon)]
        case .allTerminals:       return [trip(.p(1)), trip(.p(9)), trip(.s(1)), trip(.s(9)), pair(.m(1))]
        case .thirteenOrphans:    return [[.m(1), .m(9), .p(1), .p(9), .s(1), .s(9), .east, .south, .west, .north, .redDragon, .greenDragon, .whiteDragon, .whiteDragon]]
        case .nineGates:          return [[.p(1), .p(1), .p(1), .p(2), .p(3), .p(4), .p(5), .p(6), .p(7), .p(8), .p(9), .p(9), .p(9)]]
        case .seatFlower:         return [[.flower(.plum)]]
        case .chickenHand:        return [[.m(2), .m(3), .m(4)], [.p(5), .p(6), .p(7)], [.s(3), .s(4), .s(5)], [.s(7), .s(8), .s(9)], pair(.p(2))]
        case .selfDraw, .fullyConcealed, .noFlowers, .winOnKongReplacement, .robbingKong, .lastTile:
            return []
        }
    }
}

/// Example sheet for a scoring pattern: name, faan value, example hand, and the
/// plain-English "why". Styled like `TileDetailSheet` — single pinned grabber,
/// system drag indicator hidden.
struct FaanExampleSheet: View {
    let category: FaanCategory

    private var groups: [[Tile]] { FaanInfo.example(category) }

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
                        header

                        Text(FaanInfo.description(category))
                            .font(MJFont.ui(13))
                            .foregroundStyle(MJColor.cream(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)

                        if groups.isEmpty {
                            Text("This one is about how you win — the timing or the way you take the tile — not a fixed shape of tiles.")
                                .font(MJFont.ui(12))
                                .foregroundStyle(MJColor.cream(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Example").eyebrowStyle()
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                                            TileRow(group, theme: .ivory, width: 28, spacing: 2)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(category.englishName)
                .font(MJFont.serif(20, weight: .bold))
                .foregroundStyle(MJColor.creamHeading)
            Text(category.traditionalChineseName)
                .font(MJFont.serif(15))
                .foregroundStyle(MJColor.gold)
            Spacer(minLength: 0)
            faanBadge
        }
    }

    private var faanBadge: some View {
        let value = FaanTable.standard[category]
        return VStack(alignment: .trailing, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)")
                    .font(MJFont.serif(18, weight: .bold))
                    .foregroundStyle(value == 0 ? MJColor.cream(0.5) : MJColor.gold)
                Text("番")
                    .font(MJFont.serif(11))
                    .foregroundStyle(value == 0 ? MJColor.cream(0.4) : MJColor.gold(0.7))
            }
            if category.isLimitHand {
                Text("limit 滿")
                    .font(MJFont.ui(8.5, weight: .semibold))
                    .foregroundStyle(MJColor.cream(0.45))
            }
        }
    }
}
