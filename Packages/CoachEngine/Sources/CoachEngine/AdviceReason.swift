import MahjongCore

/// A "why" chip explaining a ``RankedDiscard`` or the overall advice.
///
/// Cases carry the data needed to render the chip; `englishText` /
/// `traditionalChineseText` follow the `FaanCategory` in-code localization
/// pattern (no `.strings` files anywhere in this codebase).
///
/// Derivation is a single cross-option annotation pass after scoring, which
/// compares each option's category set and metrics against the field — no
/// extra engine calls. The advisor emits reasons ordered by salience; the UI
/// shows the first 1–2.
public enum AdviceReason: Sendable, Hashable {
    /// The 14-tile hand is already a winning shape that meets the minimum.
    case declaresWin
    /// This option's best reachable faan is below the table's minimum — the
    /// EV guardrail. The option is ranked last, not hidden.
    case breaksMinimumFaan(minimum: Int)
    /// Discarding elsewhere would break a flush that this option keeps alive.
    case keepsFlushAlive(suit: Suit, isFull: Bool)
    /// Keeps a completed dragon triplet that an alternative discard breaks.
    case keepsDragonPung(dragon: Dragon)
    /// Keeps a dragon pair (a potential triplet) that an alternative breaks.
    case keepsDragonPair(dragon: Dragon)
    /// Keeps a completed value-wind triplet that an alternative discard breaks.
    case keepsValueWindPung(wind: Wind, isSeat: Bool, isPrevailing: Bool)
    /// Keeps a value-wind pair (a potential triplet) that an alternative breaks.
    case keepsValueWindPair(wind: Wind, isSeat: Bool, isPrevailing: Bool)
    /// This option is EV-best but not the efficiency-best (`rankDiscards`'
    /// top pick); `extraFaan` is the faan gap that justifies trading speed
    /// for value.
    case valueOverSpeed(extraFaan: Int)
    /// Strictly the lowest `shantenAfter` among the options.
    case fastestToTenpai
    /// The widest ukeire among options at equal shanten.
    case widestWait(liveOuts: Int)
    /// Tenpai with a wait that has zero live copies left.
    case deadWait(tile: Tile)
    /// A live wait whose self-drawn faan is still below the minimum — a win
    /// that cannot legally be declared.
    case chickenWait(tile: Tile)
    /// Seven Pairs (七對子) is this option's top faan source.
    case sevenPairsLine
    /// All Triplets (對對糊) is this option's top faan source.
    case allTripletsLine
}

// MARK: - Display text

public extension AdviceReason {
    /// English chip text.
    var englishText: String {
        switch self {
        case .declaresWin:
            return "Declares the win"
        case let .breaksMinimumFaan(minimum):
            return "Best reachable faan falls below the \(minimum)-faan minimum"
        case let .keepsFlushAlive(suit, isFull):
            return isFull
                ? "Keeps a full \(suit.chipEnglish) flush alive"
                : "Keeps a half \(suit.chipEnglish) flush alive"
        case let .keepsDragonPung(dragon):
            return "Keeps the \(dragon.chipEnglish) triplet"
        case let .keepsDragonPair(dragon):
            return "Keeps the \(dragon.chipEnglish) pair for a triplet"
        case let .keepsValueWindPung(wind, isSeat, isPrevailing):
            return "Keeps the \(wind.chipEnglish) Wind triplet" + windValueSuffixEN(isSeat: isSeat, isPrevailing: isPrevailing)
        case let .keepsValueWindPair(wind, isSeat, isPrevailing):
            return "Keeps the \(wind.chipEnglish) Wind pair for a triplet" + windValueSuffixEN(isSeat: isSeat, isPrevailing: isPrevailing)
        case let .valueOverSpeed(extraFaan):
            return "Worth \(extraFaan) more faan than the fastest discard"
        case .fastestToTenpai:
            return "Fastest to tenpai"
        case let .widestWait(liveOuts):
            return "Widest wait — \(liveOuts) live outs"
        case let .deadWait(tile):
            return "\(tile.code) is dead — every copy is already visible"
        case let .chickenWait(tile):
            return "\(tile.code) is live, but too few faan to declare"
        case .sevenPairsLine:
            return "Seven Pairs (七對子) is the line"
        case .allTripletsLine:
            return "All Triplets (對對糊) is the line"
        }
    }

    /// Traditional Chinese chip text (繁中).
    var traditionalChineseText: String {
        switch self {
        case .declaresWin:
            return "食糊"
        case let .breaksMinimumFaan(minimum):
            return "未夠\(minimum)番，不能食糊"
        case let .keepsFlushAlive(suit, isFull):
            return isFull
                ? "保留\(suit.chipChinese)清一色"
                : "保留\(suit.chipChinese)混一色"
        case let .keepsDragonPung(dragon):
            return "保留\(dragon.chipChinese)刻子"
        case let .keepsDragonPair(dragon):
            return "保留\(dragon.chipChinese)對子，有機會湊成刻子"
        case let .keepsValueWindPung(wind, isSeat, isPrevailing):
            return "保留\(wind.chipChinese)風刻子" + windValueSuffixZH(isSeat: isSeat, isPrevailing: isPrevailing)
        case let .keepsValueWindPair(wind, isSeat, isPrevailing):
            return "保留\(wind.chipChinese)風對子，有機會湊成刻子" + windValueSuffixZH(isSeat: isSeat, isPrevailing: isPrevailing)
        case let .valueOverSpeed(extraFaan):
            return "比最快聽牌的選擇多\(extraFaan)番"
        case .fastestToTenpai:
            return "最快聽牌"
        case let .widestWait(liveOuts):
            return "\(liveOuts)張生張，聽牌範圍最廣"
        case let .deadWait(tile):
            return "\(tile.code) 已經出盡，沒有生張"
        case let .chickenWait(tile):
            return "\(tile.code) 仍有生張，但番數不足未能食糊"
        case .sevenPairsLine:
            return "七對子"
        case .allTripletsLine:
            return "對對糊"
        }
    }
}

// MARK: - Chip-text helpers

/// Suffix noting whether a value wind is the seat wind, the prevailing wind,
/// or both (double value) — English.
private func windValueSuffixEN(isSeat: Bool, isPrevailing: Bool) -> String {
    switch (isSeat, isPrevailing) {
    case (true, true):   return " (seat + prevailing — double value)"
    case (true, false):  return " (seat wind)"
    case (false, true):  return " (prevailing wind)"
    case (false, false): return ""
    }
}

/// Traditional Chinese counterpart of ``windValueSuffixEN(isSeat:isPrevailing:)``.
private func windValueSuffixZH(isSeat: Bool, isPrevailing: Bool) -> String {
    switch (isSeat, isPrevailing) {
    case (true, true):   return "（門風兼圈風）"
    case (true, false):  return "（門風）"
    case (false, true):  return "（圈風）"
    case (false, false): return ""
    }
}

private extension Suit {
    /// Short display name for chip text ("Characters", "Dots", "Bamboo").
    var chipEnglish: String {
        switch self {
        case .characters: return "Characters"
        case .dots:       return "Dots"
        case .bamboo:     return "Bamboo"
        }
    }
    var chipChinese: String {
        switch self {
        case .characters: return "萬"
        case .dots:       return "筒"
        case .bamboo:     return "索"
        }
    }
}

private extension Wind {
    var chipEnglish: String {
        switch self {
        case .east:  return "East"
        case .south: return "South"
        case .west:  return "West"
        case .north: return "North"
        }
    }
    var chipChinese: String {
        switch self {
        case .east:  return "東"
        case .south: return "南"
        case .west:  return "西"
        case .north: return "北"
        }
    }
}

private extension Dragon {
    var chipEnglish: String {
        switch self {
        case .red:   return "Red Dragon"
        case .green: return "Green Dragon"
        case .white: return "White Dragon"
        }
    }
    var chipChinese: String {
        switch self {
        case .red:   return "中"
        case .green: return "發"
        case .white: return "白"
        }
    }
}
