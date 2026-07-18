import SwiftUI
import DesignSystem
import MahjongCore

/// Lane 4 · Learn — the interactive seat/round wind compass (spec screen 18).
/// A center round plate plus four seat chips; tapping any seat rotates the deal
/// so the winds move around the table. When your seat wind meets the East round,
/// the double-wind payoff lights up.
struct WindExplainerView: View {
    @Environment(\.dismiss) private var dismiss

    /// How far the deal has rotated (0…3); shifts the wind sitting at each seat.
    @State private var deal = 0

    private struct Seat: Identifiable {
        let id: String          // role, also the SwiftUI identity
        let base: Wind
        let offset: CGSize
        var isYou: Bool { id == "You" }
    }

    private let seats: [Seat] = [
        Seat(id: "Uncle",  base: .north, offset: CGSize(width: 0,   height: -96)),
        Seat(id: "Cousin", base: .west,  offset: CGSize(width: 96,  height: 0)),
        Seat(id: "Mum",    base: .south, offset: CGSize(width: -96, height: 0)),
        Seat(id: "You",    base: .east,  offset: CGSize(width: 0,   height: 96)),
    ]

    private static let windGlyphs = ["東", "南", "西", "北"]
    private static let windNames  = ["East", "South", "West", "North"]
    private static let windJyut   = ["dūng", "nàahm", "sāi", "bāk"]

    private func wind(at seat: Seat) -> Wind {
        Wind(rawValue: (seat.base.rawValue + deal) % 4) ?? seat.base
    }

    /// The wind currently under "You" (base East).
    private var yourWind: Wind {
        Wind(rawValue: (Wind.east.rawValue + deal) % 4) ?? .east
    }
    private var isDoubleEast: Bool { yourWind == .east }

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "Seats & winds") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Tap a seat to rotate the deal.")
                            .font(MJFont.ui(13))
                            .foregroundStyle(MJColor.cream(0.65))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        compass
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)

                        payoffPill
                        explainerCard
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Compass

    private var compass: some View {
        ZStack {
            roundPlate
            ForEach(seats) { seat in
                seatChip(seat)
                    .offset(seat.offset)
            }
        }
        .frame(width: 220, height: 220)
        .accessibilityElement(children: .contain)
    }

    private var roundPlate: some View {
        VStack(spacing: 3) {
            Text("Round").eyebrowStyle()
            Text("東")
                .font(MJFont.serif(26, weight: .bold))
                .foregroundStyle(MJColor.lightGold)
            Text("East round")
                .font(MJFont.ui(9, weight: .medium))
                .foregroundStyle(MJColor.cream(0.6))
            Text("dūng")
                .font(MJFont.ui(8, weight: .medium))
                .foregroundStyle(MJColor.gold(0.7))
        }
        .frame(width: 108, height: 108)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [MJColor.jade, MJColor.deepJade],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(MJColor.gold(0.3), lineWidth: 1)
        }
    }

    private func seatChip(_ seat: Seat) -> some View {
        let w = wind(at: seat)
        let doubled = seat.isYou && isDoubleEast
        let roleText = seat.isYou ? (doubled ? "You · Dealer" : "You") : seat.id
        return VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(Self.windGlyphs[w.rawValue])
                    .font(MJFont.serif(16, weight: .bold))
                    .foregroundStyle(seat.isYou ? MJColor.lightGold : MJColor.creamHeading)
                if doubled {
                    Text("×2")
                        .font(MJFont.ui(9, weight: .bold))
                        .foregroundStyle(MJColor.inkOnGold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(MJColor.gold, in: Capsule())
                }
            }
            Text("\(Self.windNames[w.rawValue]) · \(Self.windJyut[w.rawValue])")
                .font(MJFont.ui(8, weight: .semibold))
                .foregroundStyle(seat.isYou ? MJColor.lightGold : MJColor.gold(0.75))
            Text(roleText)
                .font(MJFont.ui(8, weight: .medium))
                .foregroundStyle(MJColor.cream(0.55))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            if seat.isYou {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [MJColor.jade, MJColor.deepJade],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MJColor.cardRaised)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(seat.isYou ? MJColor.gold : MJColor.gold(0.14),
                              lineWidth: seat.isYou ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            withAnimation(.snappy(duration: 0.25)) { deal = (deal + 1) % 4 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(seat.isYou ? "You" : seat.id), \(Self.windNames[w.rawValue])\(doubled ? ", double East" : "")"))
        .accessibilityHint(Text("Rotates the deal"))
    }

    // MARK: Payoff + explainer

    @ViewBuilder private var payoffPill: some View {
        if isDoubleEast {
            Text("Your East is seat + round → Double East · +2 faan")
                .font(MJFont.ui(11, weight: .semibold))
                .foregroundStyle(MJColor.inkOnGold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(MJColor.gold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text("\(Self.windNames[yourWind.rawValue]) seat · East round — a triplet of your seat wind still scores +1 faan.")
                .font(MJFont.ui(11, weight: .semibold))
                .foregroundStyle(MJColor.gold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(MJColor.gold(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(MJColor.gold(0.3), lineWidth: 1)
                }
        }
    }

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The double wind").eyebrowStyle()
            Text("Every player has a seat wind, and one wind rules the whole round. When your seat wind matches the round wind, a triplet of it scores twice — that's the double wind, and East's most common trap.")
                .font(MJFont.ui(12))
                .foregroundStyle(MJColor.cream(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mjCard()
    }
}
