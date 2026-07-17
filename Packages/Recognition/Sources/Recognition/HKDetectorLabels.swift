import Foundation
import MahjongCore

/// The single source of truth mapping the **detector's** 43 output labels to the
/// app's ``Tile`` model.
///
/// The `mjss` YOLO26n detector emits Tenhou-style labels (`m/p/s/z` + `1F–4F`,
/// `1S–4S`, `back`) in a fixed index order (see `Modeling/mjss/docs/ios-inference.md`).
/// **We map by label string, never by the model's integer index** — the model
/// orders the dragons `5z/6z/7z` = White/Green/Red, which is the *reverse* of
/// ``Tile/classIndex`` (31/32/33 = Red/Green/White). Mapping by string is also
/// robust to any future re-ordering of the class list.
public enum HKDetectorLabels {
    /// All 43 detector classes in model index order (0…42). Kept as a sanity
    /// reference (assert against `m.names` at export time) and for tests.
    public static let ordered: [String] = [
        "1m", "2m", "3m", "4m", "5m", "6m", "7m", "8m", "9m",   // 0–8   characters 萬
        "1p", "2p", "3p", "4p", "5p", "6p", "7p", "8p", "9p",   // 9–17  dots 筒
        "1s", "2s", "3s", "4s", "5s", "6s", "7s", "8s", "9s",   // 18–26 bamboo 索
        "1z", "2z", "3z", "4z",                                 // 27–30 E S W N
        "5z", "6z", "7z",                                       // 31–33 White/Green/Red dragon
        "1F", "2F", "3F", "4F",                                 // 34–37 flowers
        "1S", "2S", "3S", "4S",                                 // 38–41 seasons
        "back",                                                 // 42    face-down
    ]

    /// Maps a detector label (e.g. `"7z"`, `"3p"`, `"2F"`) to a ``Tile``.
    /// Returns `nil` for `"back"` (a face-down tile — never a playable face) and
    /// for any unrecognized label.
    ///
    /// - Note: Case matters. The model uses lowercase `s` for the bamboo suit
    ///   (`"1s"`) and uppercase `S` for seasons (`"1S"`); this method preserves
    ///   that distinction.
    public static func tile(for label: String) -> Tile? {
        switch label {
        case "1z": return .wind(.east)
        case "2z": return .wind(.south)
        case "3z": return .wind(.west)
        case "4z": return .wind(.north)
        case "5z": return .dragon(.white)   // model 5z/6z/7z = White/Green/Red —
        case "6z": return .dragon(.green)    // the REVERSE of Tile.classIndex order.
        case "7z": return .dragon(.red)
        case "back": return nil
        default: break
        }

        // Bonus tiles: the model writes digit-first ("1F".."4F" / "1S".."4S"),
        // while Tile.code is letter-first ("F1"/"S1") — remap by number. Scoring
        // keys off the flower/season *number*, so a positional map is correct.
        if label.count == 2, let n = label.first.flatMap({ Int(String($0)) }) {
            switch label.last {
            case "F": return Flower(rawValue: n).map(Tile.flower)
            case "S": return Season(rawValue: n).map(Tile.season)
            default: break
            }
        }

        // Suited tiles ("1m".."9s") already share the app's own code syntax.
        return Tile(code: label)
    }
}
