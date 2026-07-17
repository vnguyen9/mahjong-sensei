# PRD — MahjongMate
### A scan-first (camera/AR) iOS assistant for Hong Kong–style mahjong

**Version:** 0.2 (camera/AR-first rewrite)
**Platform:** iOS 17+, iPhone 15 and newer as the performance target (A16/A17+ Neural Engine)
**Owner:** [You]
**Status:** Draft for design + scaffolding
**Working codename:** MahjongMate

> **What changed from v0.1:** Camera/AR tile recognition is now the **primary interaction and hero feature**, not a phase-2 add-on. Manual tile entry is demoted to a **correction/fallback surface** reachable from the recognition overlay. Nobody should have to tap in 14 tiles — they point the phone, the app reads the tiles, and they fix any misread with one tap.

---

## 1. Overview & Vision

Reading tiles, understanding winds, and calculating faan are the three things that slow beginners and improving players at a real Hong Kong mahjong table. MahjongMate removes all three by **looking at the tiles for you**.

You point the camera at your hand (or, later, at the table). The app recognizes the tiles on-device in real time, shows them as an **editable overlay**, and instantly gives you the score or the best discard. If a tile is misread, you tap it and pick the right one — a one-tap fix, not a form to fill out.

**Design principle: Scan-first, correct-on-screen.** Recognition does the heavy lifting; the correction overlay guarantees the result is always right. Manual entry is only ever the fallback.

**Positioning:** the friendly, English-first (bilingual) HK mahjong tutor and scorer — for learning, self-scoring, and practice among players who are fine with it.

---

## 2. Goals & Success Metrics

| Goal | Metric | MVP target |
|---|---|---|
| Scanning beats typing | Median scan→confirmed-hand time | < 8s |
| Recognition is trustworthy | Per-tile recognition accuracy (own hand, flat, good light) | ≥ 95% |
| Correction is painless | Median taps to fix a scanned hand | ≤ 1 |
| Scoring is effortless | % scoring sessions completed without abandonment | > 85% |
| Teach, not just compute | % results where user opens "why this score" | > 40% |
| Retention | D7 retention (TestFlight cohort) | > 25% |
| Correctness | Scoring engine unit-test pass rate | 100% |

**North-star:** weekly scan-driven scoring + trainer sessions per active user.

---

## 3. Target Users / Personas

**P1 — "New at the family table."** Can't read all tiles or the winds. Wants to point the phone and get "did I win, and how much?"

**P2 — "Improving casual."** Plays at a Toronto club (Four Winds, Hong Shing social, 17 Tiles). Wants fast scoring in their house rules + discard coaching without slowing the game.

**P3 — "Riichi crossover" (Phase 4).** Wants efficiency stats; justifies the pluggable engine.

---

## 4. Scope

### In scope — MVP (Phases 0–1)
- **F1 Camera/AR Tile Recognition** — the core input. Scan your hand → editable overlay of detected tiles.
- **F2 Scoring** — consumes the recognized hand + light context → faan, points, breakdown.
- **F3 Discard Trainer** — consumes the recognized hand → best discard + why.
- **F4 Correction Overlay** — tap any detected tile to fix; add/remove tiles; the manual palette lives here.
- **F5 House Rules** configuration.
- **F6 Learn** — tile dictionary + interactive wind explainer + hand/yaku catalog.
- **F7 Onboarding + camera permission.**
- Bilingual EN / Traditional Chinese; fully offline; on-device inference; local-only data.

### Phase 2 (fast-follow)
- **Live AR table overlay** — real-time annotation of tiles in the camera view (your hand + face-up discards) rather than a single still capture.

### Phase 3–4 (later)
- Session/score-sheet tracking across a night of play.
- **Riichi** second variant. iPad. Taiwanese 16-tile; MCR.

### Non-goals
- Real-money gambling/bet-tracking as a betting tool.
- Reading opponents' **concealed** tiles (impossible, off-mission).
- Playing the game itself vs bots (different product).
- Positioning as a device to beat non-consenting opponents in live competitive play — the product is framed for learning, self-scoring, and practice/among-friends use. (Matters for eventual App Review of a public release; irrelevant to a private TestFlight build.)

---

## 5. Feature Specifications

### F1 — Camera / AR Tile Recognition (hero feature)

**Purpose:** Turn physical tiles into a digital hand instantly, on-device.

**Capture contexts (MVP):**
1. **Scan my hand (flat).** User lays their hand face-up; camera detects and labels all tiles. Primary path — highest achievable accuracy.
2. **Scan for scoring** vs **scan for coaching** — same capture, different destination (Scoring vs Trainer).

**Interaction:**
- Live camera view with a lightweight alignment guide (a framing rectangle sized for ~13–14 tiles in a row).
- On-device model detects tile bounding boxes + classes in real time; when the frame is stable/confident, it "locks" and presents the **Correction Overlay** (F4).
- Each detected tile renders as a chip/box with a **confidence indicator** (e.g., subtle color/opacity). Low-confidence tiles are visually flagged for review.

**On-device processing:** custom object detector (YOLO family) exported to **Core ML**, run via **Vision** over `AVCaptureSession` frames on the Neural Engine. No network. (See §10 Recognition Strategy.)

**Acceptance criteria:** own-hand-flat scan reaches ≥95% per-tile accuracy in good light; capture→overlay < 3s; every detected tile is individually correctable; nothing is submitted without passing through the overlay.

---

### F2 — Scoring (HK faan)

**Purpose:** From a confirmed hand + minimal context, compute faan, points, and a "why."

**Inputs:** the confirmed tiles from F1/F4, plus quick context taps — **seat wind, round wind, self-draw vs by-discard, dealer?, special wins** (last tile, kong replacement, robbing a kong). House rules come from F5.

**Processing:** validate winning shape (4 melds + pair or special hand) → run **Scoring Engine** (§11): enumerate faan criteria, resolve subset/stacking, auto-apply wind logic, cap at limit → compute payments.

**Output:** big **N faan → M points**; expandable **breakdown** (each element + one-line reason); **payment summary**; actions: "Why this score", "Rescan", "Edit tiles", "Save".

**Edge cases:** incomplete/illegal hand → inline guidance; below min faan → "Chicken hand — can't win under your house rules"; multiple interpretations → take the highest, show alternates.

**Acceptance:** matches a curated corpus of ≥50 hand+context cases; wind faan correct for every seat×round incl. double wind; house-rule toggles change results correctly.

---

### F3 — Discard Trainer

**Purpose:** From a confirmed 14-tile hand, coach the best discard and teach why.

**Processing (Efficiency Engine, §12):** compute **shanten**; for each candidate discard compute resulting shanten + **ukeire** (advancing tiles and live copies); apply an **HK value overlay** — because HK needs a faan minimum, nudge toward scoring shapes (flush / all-pungs / dragon-wind pungs) and flag "this fast line makes a chicken hand"; model **open hands / calling** (HK opens far more than Riichi).

**Output:** ranked discards with shanten + ukeire; best highlighted on the scanned hand; tap a tile → "discard this: X-shanten, accepts Y tiles (Z live)"; teaching note on wait quality + value trade-off.

**Modes:** scan-and-analyze · drill (app deals a hand, you choose, it grades) · optional timer.

**Acceptance:** shanten/ukeire match reference outputs on a test corpus; value overlay never recommends a strictly worse-shanten discard without flagging the trade-off.

---

### F4 — Correction Overlay (the reliability layer)

**Purpose:** Guarantee the digital hand is correct, fast.

**Interaction:**
- Detected tiles shown as an editable strip/overlay aligned to the capture.
- **Tap a tile → tile picker** (the palette, grouped by suit/honor/bonus) to change it.
- **Long-press → remove**; **"+" → add** a missed tile; drag to reorder into melds if needed.
- Low-confidence tiles pre-flagged so the eye goes straight to likely errors.
- "Looks right" confirms and routes to Scoring or Trainer.

**Note:** the manual tile palette from v0.1 lives *here*, as correction UI — not as the primary entry method.

**Acceptance:** any misread fixable in ≤1 tap; adding/removing a tile ≤2 taps; overlay usable one-handed (thumb reach).

---

### F5 — House Rules

Configurable (HK faan tables aren't standardized): **min faan** 1/2/3(default)/4/5 · **All Pungs** 2/3 · **Half Flush** 2/3 · **conversion** full/half-spicy · **limit cap** 8/10/13 · flowers on/off, no-flower bonus · payments (self-draw all-pay, dealer double, discarder-pays-double). Presets: Family default / Common club / Custom. Feeds F2, F3, F6c.

---

### F6 — Learn Module

**F6a Tile Dictionary** — all 42 faces; tap → EN + 繁中 name, Jyutping, notes (e.g., 1-bamboo is a bird); search + quiz.
**F6b Interactive Wind Explainer** — four-seat diagram; set round + seat → highlights seat wind, round wind, double-wind overlap (=2 faan), matching flowers; animated seat rotation. Kills the #1 confusion.
**F6c Hand/Yaku Catalog** — scoring hands with example tiles + faan (per house rules) + plain description; filter by faan; deep-link to Trainer.

---

### F7 — Onboarding + Permissions

3–4 skippable screens: experience level → house-rules preset → **camera permission primer** ("MahjongMate reads tiles on your device; images never leave your phone") → one-line tour. No account.

---

## 6. Key User Flows

**A — Scan & score (primary):** Home → point camera at hand → overlay of detected tiles → fix any misread (≤1 tap) → set seat/round/win-type → Result + breakdown. *Target < 20s total.*

**B — Scan & coach:** Home → Trainer → scan hand → confirm overlay → ranked discards + why.

**C — What is this tile?:** Home → Learn → Dictionary → search/visual → detail. *< 10s.*

**D — Understand winds:** Home → Learn → Wind Explainer → set round+seat → highlights + rotation.

**E — Live AR (Phase 2):** point at table → real-time annotated tiles → tap to correct → score/coach.

---

## 7. Screen Inventory (for wireframes / design mock)

Each: **purpose · components · states.**

1. **Onboarding (3–4)** — level, rules preset, camera primer, tour. *first-run.*
2. **Home / Mode Hub** — big "Scan to Score" + "Scan to Train" + Learn + Settings. *default.*
3. **Camera Capture** — live view, alignment guide, capture/auto-lock, real-time boxes. *scanning, locked, low-light warning, error.*
4. **Correction Overlay** — editable detected-tile strip w/ confidence, tile-picker sheet, add/remove, confirm. *high-confidence, has-flagged-tiles, edited.*
5. **Scoring — Context** — seat wind, round wind, self-draw/discard, dealer, special-wins. *default.*
6. **Scoring — Result** — faan→points, expandable breakdown, payments, actions (why/rescan/edit/save). *valid, chicken, incomplete.*
7. **Trainer — Analysis** — scanned hand, ranked discards, per-tile detail, teaching note. *results, empty.*
8. **Trainer — Drill** — dealt hand, pick discard, grade, streak, timer. *dealt, answered, summary.*
9. **House Rules** — grouped controls, presets, reset. *preset, custom(dirty).*
10. **Learn — Tile Dictionary** — grid, search, quiz; detail sheet. *browse, search, quiz.*
11. **Learn — Wind Explainer** — seat diagram, controls, legend, rotate anim. *per seat×round, double-wind callout.*
12. **Learn — Hand/Yaku Catalog** — list w/ tiles + faan, filter, detail. *browse, filtered.*
13. **Settings** — language (EN/繁), appearance, house-rules shortcut, camera perm status, about, feedback.

**Design direction:** camera-forward, minimal chrome over the live view; tactile ivory/jade/red tile aesthetic; confidence shown subtly (not alarming); large one-handed tap targets; bilingual labels never truncate. Use the frontend-design skill / Apple HIG for the mock; follow ARKit/camera HIG for the capture screen.

---

## 8. Information Architecture

Home surfaces the two scan actions first. Camera → Correction Overlay is the shared front door for both Scoring and Trainer (same `RecognitionSession` + overlay component). Learn and Settings are secondary tabs. House Rules reachable from Settings and from any scoring/catalog context.

---

## 9. Data Models (scaffolding)

**Tile encoding:** `1m–9m` characters · `1p–9p` dots · `1s–9s` bamboo · `E S W N` winds · `RD GD WD` dragons · `F1–F4` flowers · `S1–S4` seasons. 34 base + 8 bonus = **42 classes** (matches HK CV datasets).

```swift
enum Suit { case characters, dots, bamboo, wind, dragon, flower, season }

struct Tile: Hashable, Codable {
    let suit: Suit
    let rank: Int
    var code: String            // "1m", "E", "RD", "F1"...
}

// Recognition output — the new first-class citizen
struct DetectedTile: Codable {
    var tile: Tile
    var confidence: Double      // 0–1
    var boundingBox: CGRect     // normalized, for overlay placement
    var userCorrected: Bool
}

struct RecognitionResult: Codable {
    var tiles: [DetectedTile]
    var capturedAt: Date
    var lowConfidenceCount: Int
}

enum MeldKind { case chow, pung, kong, pair }
struct Meld: Codable { let kind: MeldKind; let tiles: [Tile]; let isConcealed: Bool }

struct Hand: Codable {
    var concealed: [Tile]
    var melds: [Meld]
    var bonus: [Tile]
    var winningTile: Tile?
}

enum Wind { case east, south, west, north }

struct GameContext: Codable {
    var seatWind: Wind; var roundWind: Wind
    var selfDraw: Bool; var isDealer: Bool
    var lastTile: Bool; var kongReplacement: Bool; var robbingKong: Bool
}

struct HouseRules: Codable {
    var minFaan: Int; var allPungsFaan: Int; var halfFlushFaan: Int
    var spicy: SpicyMode; var limitCap: Int
    var flowersEnabled: Bool; var noFlowerBonus: Bool
    var dealerDouble: Bool; var selfDrawAllPay: Bool
}

struct ScoreComponent: Codable { let nameEN, nameZH, explanation: String; let faan: Int }
struct ScoreResult: Codable {
    let components: [ScoreComponent]
    let totalFaan, cappedFaan, points: Int
    let isValidWin: Bool
    let payments: [Payment]
    let notes: [String]
}
```

Persistence: **SwiftData** for history + drill stats; `HouseRules` in UserDefaults/SwiftData. All local. Captured images are processed in-memory and **not stored** unless the user saves.

---

## 10. Technical Architecture & Recognition Strategy

**UI:** SwiftUI, iOS 17+, MVVM. Shared `CameraCaptureView` + `CorrectionOverlayView` feed both Scoring and Trainer.

**Modular Swift packages:**
- `Recognition` — `AVCaptureSession` + **Vision** (`VNCoreMLRequest`) + **Core ML** model wrapper; emits `RecognitionResult`. Core, not optional.
- `MahjongCore` — Tile/Meld/Hand + winning-shape validation.
- `ScoringEngine` — HK faan + wind logic + payments (pure, deterministic, unit-tested).
- `EfficiencyEngine` — shanten + ukeire + HK value overlay.
- `MahjongData` — dictionary, catalog, bilingual strings.

**Recognition pipeline:** custom **YOLO-family object detector** → exported to **Core ML** (.mlpackage) → run via **Vision** on live frames → map detections to `DetectedTile`s → stability/confidence gate → overlay. Runs on the **Neural Engine**; model is single-digit MB; real-time on A16/A17.

**Why hardware is not the risk (and what is):** iPhone 15+ runs modern detectors in real time comfortably — the bottleneck is **model accuracy on real, varied tile sets**. Public models degrade out-of-domain (~70%). Therefore the **critical-path workstream is data**: collect and label images of the tile designs actually used at target Toronto venues; augment for lighting/angle; fine-tune. The **Correction Overlay is the safety net** that makes any residual error a one-tap fix.

**Capture-difficulty ladder (build in this order):**
1. **Own hand, laid flat, single row, good light** → high accuracy achievable → MVP.
2. Own hand at slight angle / dimmer light → data + augmentation.
3. **Live AR table overlay** (Phase 2): tiles across the table, angled, partially occluded, at distance → hardest; needs the most data and possibly LiDAR/depth on Pro models for framing. Sequenced last *because of accuracy*, not device capability.

**ARKit:** not required for the flat-hand MVP (Vision alone suffices). Introduce ARKit for the Phase-2 live overlay if anchoring annotations to the physical table improves UX.

**Efficiency engine:** pure-Swift port of shanten/ukeire (well-documented). Use open-source `garyleung142857/mahjong-tile-efficiency` (supports Hong Kong Old Style) as a **reference oracle** for the test corpus.

**No backend for MVP.** Everything offline/on-device.

---

## 11. Scoring Engine Spec

Validate 4 melds + pair across all decompositions (+ special hands); score each decomposition, keep max. **Faan:** patterns (Common Hand 1, All Pungs house 2/3, Half/Full Flush, Dragons, Winds, All Honors, Four Concealed Pungs…); **wind faan** auto-derived (seat 1, round 1, double 2); win-condition (self-draw +1, concealed +1, robbing kong +1, last tile +1, kong replacement +2); bonus flowers/seasons. Resolve subset overlaps (count higher only); cap at `limitCap`; enforce `minFaan` (special hands may bypass, configurable). Convert faan→points via spicy table; apply dealer double; distribute payments. 100% corpus pass before ship.

---

## 12. Efficiency Engine Spec

**Shanten** `= 8 − 2×melds − partials(capped) − pairBonus`, minimized over decompositions incl. seven-pairs/thirteen-orphans. **Ukeire:** tile types lowering shanten, with live-copy counts (subtract visible tiles). **Discard ranking:** per-tile post-discard shanten+ukeire, sorted. **HK value overlay:** bias toward faan-reaching shapes; flag speed-vs-value trade-offs; model calling/open hands. **Wait quality:** classify (two-sided > edge/closed) for teaching text.

---

## 13. Non-Functional Requirements

Offline-first; **on-device inference only**, images never leave device, not stored unless saved; EN + Traditional Chinese throughout; Dynamic Type + VoiceOver (announce tile names) + ≥44pt targets; scoring < 200ms, trainer < 500ms, recognition real-time (< ~50ms/frame) with capture→overlay < 3s; engine packages gated by unit tests.

---

## 14. Analytics (privacy-respecting, opt-in)

Local aggregate counters: scans, scan→confirm time, correction taps per scan, per-tile accuracy (flagged vs corrected), sessions per mode, "why this score" opens, drill accuracy. Validates §2.

---

## 15. Roadmap & Sequencing

| Phase | Scope | Notes |
|---|---|---|
| **0 — Scan→Score core** | `Recognition` (flat-hand model v1) + Correction Overlay + Scoring + House Rules + Onboarding | UI/engine build fast with LLM pairing **in parallel** with the data-collection/model workstream, which is the critical path. |
| **1 — Coach & Learn** | Discard Trainer on scanned hand + Learn (dictionary, wind explainer, catalog) | Wind explainer = retention hook. |
| **2 — Live AR overlay** | Real-time table annotation, angled/occluded tiles | Hardest recognition; sequenced for accuracy, not hardware. |
| **3 — Sessions** | Score-sheet across a play night | |
| **4 — Riichi** | Second variant via pluggable engine | Targets Toronto Riichi Club. |

**Data workstream (starts day 1):** capture + label real tile-set images at Four Winds Toronto / Hong Shing social / 17 Tiles; build a labeled set; fine-tune; track per-tile accuracy as the go/no-go for expanding the capture ladder. **Beta:** TestFlight via those venues (and TORI for Phase 4).

---

## 16. Open Decisions

1. **Default house-rules preset** (min faan / spicy / cap) — confirm your table's numbers.
2. **App name** (MahjongMate is a placeholder).
3. **Model start:** train from scratch on your captures vs fine-tune a public HK/Chinese-42-class model as a base? (Recommend: fine-tune a base, then adapt with your data.)
4. **Chinese script:** Traditional-only for MVP? (Recommend yes.)
5. **Pro-only features:** use LiDAR/depth on Pro models to improve framing, or keep parity across all iPhone 15+? 

---

## 17. Appendix A — Tile Encoding
`1m–9m` · `1p–9p` · `1s–9s` · `E S W N` · `RD GD WD` · `F1–F4` · `S1–S4`. (34 + 8 = 42.)

## 18. Appendix B — Representative HK Faan Table (house-configurable)
Common Hand 1 · dragon/wind pung 1 · double-wind pung 2 · All Pungs 3 (house 2/3) · Half Flush 3 (2/3) · Seven Pairs 4 · Small Dragons 5 · Small Winds 6 · Full Flush 7 · Great Dragons 8 · All Honors 10 · Four Concealed Pungs 10 · Great Winds / Thirteen Orphans / All Kongs / Heavenly Hand = limit 13. Win-condition: self-draw +1, concealed +1, robbing kong +1, last tile +1, kong replacement +2.
