import Foundation
import MahjongCore
import MahjongGameEngine

/// Presentation-only opening stages. None of these values are serialized into
/// a match replay or fed back into the rules engine.
enum GameOpeningStage: String, Sendable, Equatable {
    case assemblingWalls
    case rollingDice
    case highlightingBreak
    case dealing
    case revealingHand
}

enum GamePresentationPhase: Sendable, Equatable {
    case opening(GameOpeningStage)
    case playing

    var openingStage: GameOpeningStage? {
        guard case let .opening(stage) = self else { return nil }
        return stage
    }
}

/// A short-lived visual interpretation of an already-accepted engine event.
/// The event remains the source of truth; this value only tells the table where
/// to animate the tile from and to.
struct GameTableMotion: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case frontWall
        case rearWall
        case rack(seat: Int)
        case river(seat: Int)
        case table
    }

    enum Destination: Sendable, Equatable {
        case rack(seat: Int)
        case river(seat: Int)
        case meldTray(seat: Int)
        case bonusTray(seat: Int)
        case result
        case table
    }

    let id: UUID
    let eventID: UUID
    let kind: GameEventKind
    let tile: Tile?
    let seat: Int
    let source: Source
    let destination: Destination
    let usesGoldCue: Bool

    init(event: GameEventV2, offerBeforeAction: PendingOffer?) {
        id = UUID()
        eventID = event.id
        kind = event.kind
        tile = event.tile
        seat = event.seat

        switch event.kind {
        case .draw:
            let replacement = event.drawKind == .flowerReplacement || event.drawKind == .kongReplacement
            source = replacement ? .rearWall : .frontWall
            destination = .rack(seat: event.seat)
            usesGoldCue = replacement
        case .flower:
            source = event.drawKind == .ordinary ? .frontWall : .rearWall
            destination = .bonusTray(seat: event.seat)
            usesGoldCue = true
        case .discard:
            source = .rack(seat: event.seat)
            destination = .river(seat: event.seat)
            usesGoldCue = false
        case .chow, .pung, .kong, .addedKong, .concealedKong:
            if let fromSeat = offerBeforeAction?.fromSeat {
                source = .river(seat: fromSeat)
            } else {
                source = .rack(seat: event.seat)
            }
            destination = .meldTray(seat: event.seat)
            usesGoldCue = true
        case .win:
            source = offerBeforeAction.map { .river(seat: $0.fromSeat) } ?? .rack(seat: event.seat)
            destination = .result
            usesGoldCue = true
        case .deal, .pass, .exhaustive:
            source = .table
            destination = .table
            usesGoldCue = false
        }
    }
}

/// Stable cosmetic values derived from a hand seed. This deliberately uses a
/// private mixer rather than consuming the simulator RNG.
struct GameOpeningLayout: Sendable, Equatable {
    let dice: [Int]
    let wallBreakStack: Int

    init(handSeed: UInt64, dealer: Int) {
        var mixer = PresentationSplitMix64(state: handSeed ^ 0x4D4A_5353_4449_4345)
        dice = (0..<3).map { _ in Int(mixer.next() % 6) + 1 }
        let pips = dice.reduce(0, +)
        // Four 18-stack wall sides, numbered clockwise. The dealer and dice
        // choose only the glowing cosmetic break; the engine wall stays intact.
        wallBreakStack = (dealer * 18 + pips - 1) % 72
    }
}

private struct PresentationSplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
