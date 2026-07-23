import Foundation
import CoachEngine
import MahjongCore
import MahjongGameEngine
import ScoringEngine

/// User-controlled teaching aids for the practice table. These are presentation
/// preferences: they never affect a legal mask, replay, wall, or bot decision.
enum GameLearningPreferences {
    private static let tileInsightsKey = "gameLearning.tileInsightsEnabled"
    private static let claimTimerKey = "gameLearning.claimTimer"
    private static let coachMarkKey = "gameLearning.didShowTileCoachMark"
    private static let stepThroughKey = "gameLearning.stepThroughEnabled"
    private static let highlightNewestDiscardKey = "gameLearning.highlightNewestDiscard"
    private static let coachHintsKey = "gameLearning.coachHintsEnabled"

    /// Insights are on by default because the experimental table is a learning
    /// surface. `object(forKey:)` preserves that default for existing installs.
    static var tileInsightsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: tileInsightsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: tileInsightsKey) }
    }

    static var claimTimer: GameClaimTimer {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: claimTimerKey),
                  let value = GameClaimTimer(rawValue: rawValue) else { return .off }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: claimTimerKey) }
    }

    static var hasShownTileCoachMark: Bool {
        get { UserDefaults.standard.bool(forKey: coachMarkKey) }
        set { UserDefaults.standard.set(newValue, forKey: coachMarkKey) }
    }

    /// Normal play remains automatic by default. Learners can opt into brief
    /// pauses after visible actions so an explanation can be read before the
    /// next actor proceeds.
    static var stepThroughEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: stepThroughKey) }
        set { UserDefaults.standard.set(newValue, forKey: stepThroughKey) }
    }

    /// Public-action highlighting is structural table feedback, so existing
    /// installs receive it unless the player explicitly turns it off.
    static var highlightNewestDiscard: Bool {
        get { UserDefaults.standard.object(forKey: highlightNewestDiscardKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: highlightNewestDiscardKey) }
    }

    /// Short phase-aware teaching copy is progressive disclosure: on for a new
    /// learner, independently dismissible without removing the permanent cues.
    static var coachHintsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: coachHintsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: coachHintsKey) }
    }
}

/// Optional automatic pass timing. The session owns countdown scheduling; this
/// enum only persists the user's chosen duration.
enum GameClaimTimer: String, CaseIterable, Identifiable, Hashable, Sendable {
    case off
    case sevenSeconds
    case tenSeconds

    var id: String { rawValue }
    var seconds: Int? {
        switch self {
        case .off: nil
        case .sevenSeconds: 7
        case .tenSeconds: 10
        }
    }
    var title: String { seconds.map { "\($0) seconds" } ?? "Off" }
    var accessibilityDescription: String {
        seconds.map { "Automatically passes a claim after \($0) seconds" }
            ?? "Does not automatically pass a claim"
    }
}

/// Where an inspectable, face-up tile appears. Concealed opponent racks and
/// wall backs intentionally have no corresponding case.
enum GameTileInsightOrigin: Hashable, Sendable {
    case humanHand
    case river(ownerSeat: Int)
    case meld(ownerSeat: Int)
    case flower(ownerSeat: Int)
    case offered(ownerSeat: Int, isRobKong: Bool)

    var ownerSeat: Int? {
        switch self {
        case .humanHand: nil
        case let .river(ownerSeat), let .meld(ownerSeat), let .flower(ownerSeat): ownerSeat
        case let .offered(ownerSeat, _): ownerSeat
        }
    }

    var title: String {
        switch self {
        case .humanHand: "Your hand"
        case .river: "Discard river"
        case .meld: "Exposed meld"
        case .flower: "Flower or season"
        case .offered(_, let isRobKong): isRobKong ? "Offered for robbing a kong" : "Offered discard"
        }
    }
}

/// A legal response that is relevant to the tile currently offered to the
/// human player. It is intentionally an action ID rather than a custom action:
/// callers submit it through the existing engine bridge unchanged.
struct GameOfferedTileAction: Hashable, Sendable, Identifiable {
    let id: Int
    let kind: String
    let title: String
    let isRobKongWin: Bool

    init(action: GameAction, isRobKongWin: Bool) {
        id = action.id
        kind = action.kind.rawValue
        self.isRobKongWin = isRobKongWin
        switch action.kind {
        case .pass: title = "Pass"
        case .win: title = isRobKongWin ? "Win · Rob Kong" : "Win"
        case .chow: title = "Chow"
        case .pung: title = "Pung"
        case .exposedKong: title = "Kong"
        case .discard, .concealedKong, .addedKong: title = action.kind.rawValue
        }
    }
}

/// Public, human-safe tile facts used by the learning drawer. This value is
/// built exclusively from `PublicObservationV3`; it cannot reveal an opponent
/// hand, identify a wall tile, or infer where an unseen copy physically is.
struct GameTileInsightContext: Hashable, Sendable, Identifiable {
    let tile: Tile
    let origin: GameTileInsightOrigin
    let humanHeldCopies: Int
    let publiclyVisibleCopies: Int
    let remainingUnseenCopies: Int
    /// Probability only among unseen *base* tiles. Bonus tiles use replacement
    /// draws, so they deliberately have no wall-frequency claim.
    let estimatedUnseenFrequency: Double?
    let unseenBaseTileCount: Int
    let wallRemaining: Int
    let seatWind: Wind
    let prevailingWind: Wind
    let meldCount: Int
    let flowerCount: Int
    let discardCount: Int
    let offeredTile: Tile?
    let offeredFromSeat: Int?
    let legalOfferedActions: [GameOfferedTileAction]
    let observationTurn: Int

    var id: String { "\(tile.classIndex)-\(origin)-\(observationTurn)" }
    var isHumanHeld: Bool { origin == .humanHand }
    var isOffered: Bool { offeredTile == tile }
    var estimatedUnseenPercent: String? {
        estimatedUnseenFrequency.map(TileInsight.percent)
    }

    init(tile: Tile, origin: GameTileInsightOrigin, observation: PublicObservationV3) {
        let humanCounts = observation.concealed
        let publicCounts = Self.safePublicHistogram(observation: observation)
        let ownConcealedCounts = Self.histogram(
            observation.melds.filter(\.isConcealed).flatMap(\.tiles)
        )
        self.tile = tile
        self.origin = origin
        humanHistogram = humanCounts
        publicHistogram = publicCounts
        ownConcealedMeldHistogram = ownConcealedCounts
        observationMelds = observation.melds
        observationFlowers = observation.flowers
        opponentMeldsCount = observation.opponentMelds.flatMap { $0 }.count
        observationTurn = observation.turn
        wallRemaining = observation.wallRemaining
        seatWind = observation.seatWind
        prevailingWind = observation.prevailingWind
        meldCount = observation.melds.count + observation.opponentMelds.flatMap { $0 }.count
        flowerCount = observation.flowers.count + observation.opponentFlowers.flatMap { $0 }.count
        discardCount = observation.ownDiscards.count + observation.opponentDiscards.flatMap { $0 }.count
        offeredTile = observation.offerTile
        offeredFromSeat = observation.offerFromAbsolute

        humanHeldCopies = Self.count(tile, in: observation.concealed)
        publiclyVisibleCopies = tile.isBonus
            ? Self.publicBonusCount(tile, observation: observation)
            : Self.count(tile, in: publicCounts)
        let copyLimit = tile.isBonus ? 1 : 4
        let humanConcealedMeldCopies = Self.count(tile, in: ownConcealedCounts)
        remainingUnseenCopies = max(0, copyLimit - humanHeldCopies - publiclyVisibleCopies - humanConcealedMeldCopies)
        unseenBaseTileCount = max(0, (0..<Tile.baseClassCount).reduce(0) { partial, index in
            partial + max(0, 4 - humanCounts[index] - publicCounts[index] - ownConcealedCounts[index])
        })
        estimatedUnseenFrequency = tile.isBonus || unseenBaseTileCount == 0
            ? nil
            : Double(remainingUnseenCopies) / Double(unseenBaseTileCount)

        let offeringThisTile = observation.offerTile == tile
        let robKong = origin.isRobKongOffer
        legalOfferedActions = offeringThisTile
            ? Self.legalOfferActions(mask: observation.legalMask, isRobKong: robKong)
            : []
    }

    /// Converts only the human player's public observation into the advisor's
    /// value input. Own exposed melds are public, but excluded from `seen` per
    /// `TableState`'s contract so they are not counted twice.
    var advisorTableState: TableState {
        let ownMelds = melds(from: observationMelds)
        let ownMeldHistogram = Self.histogram(observationMelds.flatMap(\.tiles))
        let seen = zip(publicHistogram, ownMeldHistogram).map { max(0, $0 - $1) }
        return TableState(
            concealed: Self.expandHistogram(humanHistogram),
            melds: ownMelds,
            bonusTiles: observationFlowers,
            seenHistogram: seen,
            unseenCount: max(1, unseenBaseTileCount),
            drawsRemaining: wallRemaining,
            opponentMeldCount: opponentMeldsCount,
            context: GameContext(seatWind: seatWind, prevailingWind: prevailingWind, houseRules: .standard)
        )
    }

    // Stored public ingredients preserve a complete, actor-free advisor input.
    private let humanHistogram: [Int]
    private let publicHistogram: [Int]
    private let ownConcealedMeldHistogram: [Int]
    private let observationMelds: [GameMeld]
    private let observationFlowers: [Tile]
    private let opponentMeldsCount: Int

    /// The compiler synthesizes this memberwise initializer for tests and
    /// previews only through the public-observation initializer above.
    private static func count(_ tile: Tile, in histogram: [Int]) -> Int {
        guard tile.classIndex < histogram.count else { return 0 }
        return histogram[tile.classIndex]
    }

    /// `PublicObservationV3` carries engine bookkeeping for every declared
    /// meld. Filter it here instead of using `physicalPublic` / `remainingBelief`:
    /// an opponent's concealed kong must remain unknown to this learning UI.
    private static func safePublicHistogram(observation: PublicObservationV3) -> [Int] {
        let ownExposed = observation.melds.filter { !$0.isConcealed }.flatMap(\.tiles)
        let opponentExposed = observation.opponentMelds
            .flatMap { $0 }
            .filter { !$0.isConcealed }
            .flatMap(\.tiles)
        let rivers = observation.ownDiscards + observation.opponentDiscards.flatMap { $0 }
        var result = Array(repeating: 0, count: Tile.baseClassCount)
        for tile in rivers + ownExposed.map(\.tile) + opponentExposed.map(\.tile) where !tile.isBonus {
            result[tile.classIndex] += 1
        }
        return result
    }

    private static func publicBonusCount(_ tile: Tile, observation: PublicObservationV3) -> Int {
        observation.flowers.filter { $0 == tile }.count
            + observation.opponentFlowers.flatMap { $0 }.filter { $0 == tile }.count
    }

    private static func legalOfferActions(mask: [Bool], isRobKong: Bool) -> [GameOfferedTileAction] {
        mask.indices.compactMap { index in
            guard mask[index], let action = try? GameAction(id: index) else { return nil }
            switch action.kind {
            case .pass, .win, .chow, .pung, .exposedKong:
                return GameOfferedTileAction(action: action, isRobKongWin: isRobKong && action.kind == .win)
            case .discard, .concealedKong, .addedKong:
                return nil
            }
        }
    }

    private static func histogram(_ tiles: [TileInstance]) -> [Int] {
        var result = Array(repeating: 0, count: Tile.baseClassCount)
        for instance in tiles where !instance.tile.isBonus { result[instance.tile.classIndex] += 1 }
        return result
    }

    private static func expandHistogram(_ histogram: [Int]) -> [Tile] {
        histogram.enumerated().flatMap { index, copies -> [Tile] in
            guard let tile = Tile(classIndex: index) else { return [] }
            return Array(repeating: tile, count: copies)
        }
    }

    private func melds(from gameMelds: [GameMeld]) -> [Meld] {
        gameMelds.map { gameMeld in
            let kind: MeldKind
            switch gameMeld.kind {
            case .chow: kind = .chow
            case .pung: kind = .pung
            case .exposedKong, .concealedKong, .addedKong: kind = .kong
            }
            return Meld(kind: kind, tiles: gameMeld.tiles.map(\.tile), isConcealed: gameMeld.isConcealed)
        }
    }
}

private extension GameTileInsightOrigin {
    var isRobKongOffer: Bool {
        if case let .offered(_, isRobKong) = self { return isRobKong }
        return false
    }
}

extension GameTileInsightContext {
    init?(tile: Tile, origin: GameTileInsightOrigin, observation: PublicObservationV3, requireInspectable: Bool = true) {
        guard !requireInspectable || Self.isInspectable(origin: origin) else { return nil }
        self.init(tile: tile, origin: origin, observation: observation)
    }

    static func isInspectable(origin: GameTileInsightOrigin) -> Bool {
        // This deliberately remains a whitelist. New table zones must opt in;
        // a concealed opponent rack can never accidentally become inspectable.
        switch origin {
        case .humanHand, .river, .meld, .flower, .offered: true
        }
    }
}

/// Compact, Sendable advisor output for the sheet. `rank` is one-based among
/// discard choices and only appears for a tile in the human hand.
struct GameTileCoachSummary: Hashable, Sendable {
    let rank: Int?
    let shanten: Int
    let outs: Int
    let nextDrawOdds: Double?
    let reasons: [AdviceReason]
    let isRecommended: Bool
}

/// The compact result shown by the table's Suggest action. It intentionally
/// contains only public-observation-derived advice and never an engine action.
struct GameDiscardSuggestion: Hashable, Sendable {
    let tile: Tile
    let shanten: Int
    let outs: Int
    let reasons: [AdviceReason]
}

enum GameLearningAdvisor {
    static func suggestedDiscard(observation: PublicObservationV3) async -> GameDiscardSuggestion? {
        guard let tileIndex = observation.concealed.firstIndex(where: { $0 > 0 }),
              let seedTile = Tile(classIndex: tileIndex) else { return nil }
        let context = GameTileInsightContext(tile: seedTile, origin: .humanHand, observation: observation)
        let table = context.advisorTableState
        return await Task.detached(priority: .userInitiated) {
            guard let best = CoachAdvisor.advise(table).best else { return nil }
            return GameDiscardSuggestion(
                tile: best.tile,
                shanten: best.shantenAfter,
                outs: best.ukeireTotal,
                reasons: best.reasons
            )
        }.value
    }

    /// Runs the deterministic advisor off the main actor. The input contains
    /// only the human's observation and public table state; callers should drop
    /// the result if their observation revision changes while this is running.
    static func summary(for context: GameTileInsightContext) async -> GameTileCoachSummary? {
        guard context.isHumanHeld else { return nil }
        let tile = context.tile
        let table = context.advisorTableState
        return await Task.detached(priority: .userInitiated) {
            let advice = CoachAdvisor.advise(table)
            if let index = advice.options.firstIndex(where: { $0.tile == tile }) {
                let option = advice.options[index]
                return GameTileCoachSummary(
                    rank: index + 1,
                    shanten: option.shantenAfter,
                    outs: option.ukeireTotal,
                    nextDrawOdds: option.nextDrawOdds,
                    reasons: option.reasons,
                    isRecommended: index == 0
                )
            }
            if let wait = advice.waitSet {
                return GameTileCoachSummary(rank: nil, shanten: wait.shanten, outs: wait.totalLive,
                                             nextDrawOdds: wait.nextDrawOdds, reasons: [], isRecommended: false)
            }
            return GameTileCoachSummary(rank: nil, shanten: advice.currentShanten, outs: 0,
                                         nextDrawOdds: nil, reasons: [], isRecommended: false)
        }.value
    }
}
