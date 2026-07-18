import SwiftUI
import DesignSystem
import MahjongCore

/// Semi-auto hand-boundary confirm card — slides over the state pane only
/// (the feed keeps running; the user can see the table being reset), dimming
/// the tabs behind (UI plan §11).
struct HandEndedCard: View {
    @Environment(CoachLiveSession.self) private var session
    @State private var selection: Wind?          // nil = Draw
    @State private var editingRotation = false

    var body: some View {
        if let boundary = session.handBoundary {
            ZStack {
                Color.black.opacity(0.65)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    SheetGrabber().frame(maxWidth: .infinity)
                    Text("Hand ended").font(MJFont.serif(17, weight: .bold)).foregroundStyle(MJColor.creamHeading)

                    winnerPicker

                    if editingRotation {
                        VStack(alignment: .leading, spacing: 10) {
                            labeled("Round wind") {
                                WindPicker(selection: Binding(
                                    get: { session.handBoundary?.predictedRoundWind ?? .east },
                                    set: { session.handBoundary?.predictedRoundWind = $0 }))
                            }
                            labeled("Your seat") {
                                WindPicker(selection: Binding(
                                    get: { session.handBoundary?.predictedSeatWind ?? .east },
                                    set: { session.handBoundary?.predictedSeatWind = $0 }))
                            }
                        }
                    } else {
                        HStack {
                            Text("Next hand: you're \(windEnglish(boundary.predictedSeatWind)) \(windGlyph(boundary.predictedSeatWind)) · round \(windEnglish(boundary.predictedRoundWind))")
                                .font(MJFont.ui(12)).foregroundStyle(MJColor.cream(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            TextLink("Edit") { editingRotation = true }
                        }
                    }

                    GoldButton("Continue →") {
                        session.confirmHandEnd(winner: selection, isDraw: selection == nil)
                    }
                    // Escape hatch for a mis-detected clear (walk-by, lean-over)
                    // — dismiss the proposal without ending the hand.
                    TextLink("Not yet — keep playing") { session.dismissHandEnd() }
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
                .frame(maxWidth: 360)
                .background {
                    // `.mjCard()`'s default fill (`MJColor.cardSurface`, 4%
                    // white) is meant to sit over an opaque screen
                    // background; floating here directly above live tab
                    // content, it read as a transparent ghost — use
                    // `sheetGlass` (90% opaque) instead, same rounded-rect +
                    // gold-border language.
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(MJColor.sheetGlass)
                    RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(MJColor.gold(0.25), lineWidth: 1)
                }
                .padding(20)
            }
            .onAppear { selection = boundary.guessedWinner }
        }
    }

    private var winnerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Wind.allCases, id: \.self) { wind in
                    FilterChip("\(windGlyph(wind)) \(windEnglish(wind))", active: selection == wind) {
                        selection = wind
                    }
                }
                FilterChip("Draw", active: selection == nil) { selection = nil }
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).eyebrowStyle()
            content()
        }
    }
}
