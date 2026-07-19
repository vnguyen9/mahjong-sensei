import SwiftUI
import DesignSystem
import MahjongCore

/// The single end-of-hand card — slides over the state pane only (the feed
/// keeps running; the user can see the table being reset), dimming the tabs
/// behind (UI plan §11). Surfaces on EITHER signal so there's only ever one
/// prompt: a self-draw win (`winDetected`) shows a "Score this hand →" shortcut
/// into the Score flow; a table-clear (`handBoundary`) shows the winner picker +
/// wind rotation. When both fire, scoring is primary and advancing is secondary.
struct HandEndedCard: View {
    @Environment(CoachLiveSession.self) private var session
    let onScoreHandoff: () -> Void
    @State private var selection: Wind?          // nil = Draw
    @State private var editingRotation = false

    var body: some View {
        let boundary = session.handBoundary
        let win = session.winDetected
        if boundary != nil || win != nil {
            ZStack {
                Color.black.opacity(0.65)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    SheetGrabber().frame(maxWidth: .infinity)
                    Text(cardTitle(win)).font(MJFont.serif(17, weight: .bold)).foregroundStyle(MJColor.creamHeading)

                    if let boundary {
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
                    }

                    actions(boundary: boundary, win: win)
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
            .onAppear { selection = session.handBoundary?.guessedWinner }
        }
    }

    /// A win headline reads "Winning hand!"; a bare table-clear reads "Hand ended".
    private func cardTitle(_ win: WinInfo?) -> String {
        guard let win else { return "Hand ended" }
        return win.isSelfDraw ? "Winning hand! 自摸" : "Winning hand! 食糊"
    }

    /// One always-gold primary button. A detected win makes "Score this hand →"
    /// primary (the handoff into the Score flow that the old WinBanner owned);
    /// otherwise "Continue →" advances to the next hand. Secondaries dismiss
    /// without losing the other signal.
    @ViewBuilder
    private func actions(boundary: HandBoundaryPrediction?, win: WinInfo?) -> some View {
        if win != nil {
            GoldButton("Score this hand →") { onScoreHandoff() }
            if boundary != nil {
                TextLink("Next hand — skip scoring") {
                    session.confirmHandEnd(winner: selection, isDraw: selection == nil)
                }
                .frame(maxWidth: .infinity)
            } else {
                TextLink("Keep playing") { session.winDetected = nil }
                    .frame(maxWidth: .infinity)
            }
        } else {
            GoldButton("Continue →") {
                session.confirmHandEnd(winner: selection, isDraw: selection == nil)
            }
            // Escape hatch for a mis-detected clear (walk-by, lean-over)
            // — dismiss the proposal without ending the hand.
            TextLink("Not yet — keep playing") { session.dismissHandEnd() }
                .frame(maxWidth: .infinity)
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
