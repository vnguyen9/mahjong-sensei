# Mahjong Sensei · 麻雀先生

A scan-first iOS app for Hong Kong–style mahjong: point the camera at a hand, it
recognizes the tiles **on-device**, then scores the hand (HK faan) and coaches
discards — with the *reason why*. 100% local, works offline.

- **Platform:** iOS 26+, iPhone 15 and newer.
- **On-device only:** no backend, no cloud inference, images never leave the phone.
- **Detector:** a custom-trained tile detector (YOLO26n → Core ML on the Neural
  Engine via Vision) trains on a separate machine and drops in behind the
  `Recognizer` protocol. Until then every screen runs on `MockRecognizer`.

## Project layout

```
project.yml                 # XcodeGen spec (source of truth for the app target)
App/Sources/                # the SwiftUI app (MVVM)
Packages/
  MahjongCore/              # Tile / Meld / Hand + winning-shape parser (pure)
  ScoringEngine/            # HK Old Style faan scoring (pure, deterministic)
  EfficiencyEngine/         # shanten + ukeire + discard ranking (pure)
  Recognition/              # RecognitionResult + MockRecognizer (Core ML later)
  MahjongData/              # bilingual EN / 繁中 / Jyutping tile data
  DesignSystem/             # palette, type, MahjongTileView, components
Planning/                   # PRD, implementation plan, design spec
```

The pure packages are the durable asset and are fully unit-tested; the detector
model is swappable.

## Getting started

Requires **Xcode 26+** and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
# 1. Regenerate the checked-in Xcode project after changing project.yml
xcodegen generate

# 2. Build & run for the iOS 26 simulator
open MahjongSensei.xcodeproj      # then ⌘R, or:
xcodebuild -scheme MahjongSensei -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build

# 3. Run the engine/unit tests
swift test --package-path Packages/MahjongCore
swift test --package-path Packages/ScoringEngine
swift test --package-path Packages/EfficiencyEngine
```

### Debug launch hook

Force an initial screen for screenshots / UI checks:

```bash
SIMCTL_CHILD_MJ_SCREEN=result xcrun simctl launch booted com.lumiodatalabs.MahjongSensei
# values: onboarding | result | scan | learn | settings
```

## Release operations

- [Recover an Xcode Cloud signing/export failure](Docs/XCODE_CLOUD_SIGNING_RECOVERY.md)
- [Run a public TestFlight beta](Docs/TESTFLIGHT_PUBLIC_BETA_RUNBOOK.md)
