import AudioToolbox
import Foundation

/// Small, asset-free sound seam for Mahjong gameplay.
///
/// `AudioServicesPlaySystemSound` plays UI sounds through the system path, so it
/// follows the device's silent/ringer setting. Do not replace these calls with
/// `AudioServicesPlayAlertSound`, which is intended for alerts instead.
enum GameSounds {
    private static let enabledKey = "gameSounds.enabled"

    /// Unset defaults to on; users can opt out from House Rules → Experience.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func tileClick() { play(.tileClick) }
    static func tileMove() { play(.tileMove) }
    static func dice() { play(.dice) }
    static func claim() { play(.claim) }
    static func win() { play(.win) }

    private enum Cue {
        // System UI sound IDs: short UI feedback only, with no bundled assets.
        case tileClick
        case tileMove
        case dice
        case claim
        case win

        var soundID: SystemSoundID {
            switch self {
            case .tileClick: 1104
            case .tileMove: 1105
            case .dice: 1103
            case .claim: 1057
            case .win: 1025
            }
        }
    }

    private static func play(_ cue: Cue) {
        guard enabled else { return }
        AudioServicesPlaySystemSound(cue.soundID)
    }
}
