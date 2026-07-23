# Mahjong Game Mode → Fully Playable HK Match — HANDOFF PLAN ← CURRENT PLAN

> Written 2026-07-21 for cold handoff (credit-constrained: implementer sessions may be smaller models; credits reset Thursday). This file is self-contained: audits, decisions, per-workstream specs with file:line anchors, and **model assignments**. The planning loop (Fable) writes NO feature code — it delegates, reviews, and verifies.

## Model assignments — who does what

| Tier | Model | Use for |
|---|---|---|
| **Large** | Opus 4.8 (`claude-opus-4-8`) | Anything touching the certified engine: match state machine, rules-profile changes, settlement math, parity/replay migration, test SPECS |
| **Medium** | Sonnet 5 (`claude-sonnet-5`) | UI construction & wiring, bot difficulty tuning, animations, session/flow code |
| **Small/XS** | Haiku 4.5 (`claude-haiku-4-5-20251001`) | Mechanical work from explicit specs: settings rows, copy, MJ_SCREEN scenes, test-case authoring from a spec table, prefs plumbing |
| Planner | this loop | Plan, review diffs, run verification — no feature code |

Rule of thumb: **the engine package is Large-only** (it has byte-for-byte Python-parity fixtures; a subtle regression is expensive), UI is Medium, anything describable as a checklist is Small.

## Context — what exists (from two exhaustive audits, 2026-07-21)

**The hard part is already built and certified.** `Packages/MahjongGameEngine/` contains a deterministic single-hand HK engine: 144-tile seeded wall (SplitMix64, `GameState.swift:376`), deal/draw/discard, full claim system with priority (win > kong/pung > chow, `resolveReactions` `GameState.swift:245-253`), all four kong types + rob-the-kong (`:275-287`), flowers with rear-wall replacement + 7/8-flower instant wins (`:298-303`), exhaustive draw, zero-sum payments (`paymentVector` `:336-345`), per-mutation invariants (144-tile conservation, `:132-142`), replay serialization guarded by `rulesHash = "0e0ce106e67fbc42"`, a **stable 127-action encoding** (`GameAction`, `GameTypes.swift:31-50`) explicitly designed as the future **Core ML policy contract**, and Python-parity fixtures + a 1000-hand stress test (`MahjongGameEngineTests.swift`). Bots: `HeuristicMahjongPolicy` behind `protocol MahjongPolicy` (`GameTypes.swift:170`), discards ranked by the real `CoachAdvisor`.

UI exists too (`App/Sources/Features/Game/`): `GameLauncherView` (seed+seat → deal), `GameSession` (@Observable driver with async bot loop + `instantBots` test hook), `GameView` (table, opponent racks with `TileBack`, rivers, melds, `HumanRack` tap-to-select, legality-driven action bar), `GameSheets` (chow chooser, result sheet, dev inspector). DEBUG-only, reachable via Settings → Advanced and `MJ_SCREEN=game*`.

**Why it's "not a playable game":**
1. **Single hand, then dead end** — no dealer rotation/連莊, no wind rounds, no running score (this is the #1 fix).
2. **Human is always dealer/East** — `GameSession.init` calls `GameState.newGame(dealer: humanSeat)` (`GameSession.swift:31`); the launcher seat picker is cosmetic; header "EAST ROUND" hardcoded (`GameView.swift:64,177`); wind badges use seat index not `seatWind` (`GameView.swift:213,219`).
3. **Seven pairs & thirteen orphans cannot win** — `standardWinningShape` (`GameState.swift:330`) uses only `HandParser.standardDecompositions`; the engine's `hk3FaanV2Table` zeroes seven pairs (`:362-368`).
4. **Screenshot scaffolding looks broken** — `ReactionPreviewSheet` is a dead mock (`GameSheets.swift:38-51`); `GameResultSheet` has a hardcoded "4 FAAN" placeholder branch (`:75-84`).
5. Thin presentation: no animations, no sound, opponents never revealed at showdown.

**User decisions (locked):** full match (4 wind rounds); classic HK core rules (3-faan min, flowers, goulash draw, dealer repeats); **three bot difficulties + a plug-in seam for a Core ML policy being trained**; faan→points settlement, loser pays; **keep entry in the dev menu for now** (promotion is a later flip); **minimal system sounds** (net-new capability — app is haptics-only today).

**Research notes:** 3-faan minimum standard; payment variants differ by house → settlement table must be DATA (default half-spread 半辣上 curve; ref en.wikipedia.org/wiki/Hong_Kong_mahjong_scoring_rules). Mobile conventions: central compass (seat winds + dealer marker + wall count), tap-to-discard, claim panel with ~5s auto-pass timer.

## Reuse map (verified — do not rebuild)

| Need | Existing asset |
|---|---|
| Win shapes incl. 7 pairs / 13 orphans | `HandParser.isWinningHand` (`MahjongCore/HandParser.swift:50`), `ScoringEngine.isWinningShape` (`ScoringEngine.swift:68`) |
| Full HK faan catalog incl. limit hands | `ScoringEngine.score(hand:context:table:)` + `FaanTable.standard` (`FaanTable.swift:26`), `FaanCategory` list (`FaanCategory.swift:10`) |
| House rules model (engine-consumed) | `HouseRules` (`MahjongCore/Hand.swift:41`: minimumFaan/faanLimit/scoreFlowers) |
| Bot brains | `CoachAdvisor.advise` (`CoachEngine/CoachAdvisor.swift:41`), `EfficiencyEngine.rankDiscards` (`EfficiencyEngine.swift:134`), shanten/ukeire (`:29,:71`) |
| Tile rendering | `MahjongTileView(_:theme:width:showsBadge:)` (DesignSystem), `TileRow`, themes; `TileBack` already in `GameView.swift` |
| Wind labels | `WindPicker` / `windEnglish` / `windGlyph` (`ContextView.swift:116-121`) |
| Result card | `ResultView` (`Scoring/ResultView.swift`) — needs only `Hand`+`GameContext` (small init refactor) or `TerminalResult.patternBreakdown` |
| End-of-hand card layout | `HandEndedCard` (Coach Live) as template |
| Chrome | `MJColor`/`MJFont`/`.mjCard`/`ScreenBackground`/`MJBackHeader`/`GoldButton`/`FilterChip`/`SegmentedToggle` |
| Prefs idiom | enum-over-UserDefaults (`CoachLivePrefs`, `TileDetector`) |
| Haptics idiom | inline `UI*FeedbackGenerator` (see CoachLiveView usages) |

---

## Workstreams

### W1 — Match engine (`MatchState`) — **Large** · no dependencies · the #1 unlock
New pure type in `Packages/MahjongGameEngine/`: `MatchState` wrapping successive `GameState` hands. **Does NOT modify `GameState`** → rulesHash/parity fixtures untouched.
- Config: match seed (per-hand seeds derived via SplitMix64 on hand index → whole match replayable), human seat (0-3, FIXED at table), rules profile, settlement policy, bot difficulty.
- Rotation: initial dealer = seat 0; **dealer repeats on dealer win AND exhaustive draw** (連莊 counter); passes counter-clockwise otherwise; prevailing wind advances E→S→W→N after all 4 seats have held (and lost) dealership; match ends after North round completes. `GameState.newGame(dealer:prevailingWind:)` already accepts both (`GameState.swift:45`) — `GameSession.swift:31` must stop passing `dealer: humanSeat`.
- Ledger: append each hand's payment vector; running totals per seat; match terminal = standings + stats (hands won, biggest faan).
- Tests (spec by Large, may be authored by Small from the spec): 16-hand rotation truth table incl. 連莊 chains; draw-repeats-dealer; prevailing-wind advance; ledger zero-sum across a full match; match replay round-trip; deterministic same-seed same-match.

### W2 — Rules breadth + settlement in `GameState` — **Large** (certified-code care)
1. **Winnable shapes**: `standardWinningShape` (`GameState.swift:330`) → also accept `HandParser.sevenPairs`/`thirteenOrphans` (win offers at `canSelfWin`/`canClaimWin` `:309-319` follow automatically).
2. **Rules profile**: replace hardwired `hk3FaanV2Table` (`:362-368`) with an injectable `RulesProfile` — new default `hk_classic_v3` = `FaanTable.standard` values with min 3 / cap 13, seven pairs enabled, thirteen orphans at limit. **Keep the v2 profile available and pass it in the Python-parity fixture tests so they stay byte-valid**; new profile gets its own fixtures later. **Bump `rulesHash` per profile** (hash must include profile id).
3. **Settlement**: replace `paymentVector` (`:336-345`) internals with data-driven `SettlementPolicy`: base-points table (default half-spread: 3f=8, 4f=16, 5f=24, 6f=32, 7f=48, 8f=64, 9f=96, 10f=128, 11f=192, 12f=256, 13f=384 — encode as data, cite Wikipedia HK scoring) + style (default: discard → discarder pays winner the full amount; self-draw → each of 3 pays, total > discard case). Zero-sum invariant (`checkInvariants` `:132`) must keep passing.
4. Tests: seven-pairs/thirteen-orphans end-to-end wins (seeded walls); settlement table cases; v2 fixtures green under v2 profile; stress test green under classic profile.

### W3 — Match UI & flow — **Medium** · depends on W1
- `GameSession` drives `MatchState` (hand → interstitial → next hand); keep `instantBots`.
- **Launcher** → "New match" card: difficulty picker (E/N/H via `SegmentedToggle`), seat picker (now real), seed under an "Advanced" disclosure.
- **Header/compass**: live "{ROUND} ROUND · HAND n · 連x" (kill hardcoded EAST at `GameView.swift:64,177`); compass strip = 4 seat winds (`windGlyph`) + dealer marker + wall count. **Fix wind badges to `player.seatWind`** (`GameView.swift:213,219`).
- **Claim window**: ~5s auto-pass ring on the action bar when reactions are open (engine already resolves priority); timeout = Pass.
- **Between hands**: real result (delete the hardcoded placeholder branch `GameSheets.swift:75-84` and dead `ReactionPreviewSheet` `:38-51` — replace the `game-reaction` scene with a live seeded position) → scoreboard interstitial (ledger deltas, 連莊, next dealer; `HandEndedCard` layout as template) → Next hand.
- **Match end screen**: standings, hands won, biggest hand (reuse `ResultView` hero style; refactor `ResultView.init` to accept `(hand:context:isSelfDraw:photo:)` — body already only needs those).
- **Showdown reveal**: at terminal, reveal all concealed hands (engine `observation` hides them pre-terminal; add a terminal-only full-state read).
- MJ_SCREEN scenes: update `game`, replace `game-reaction`, add `game-scoreboard`, `game-match-end` (Small can author scene plumbing).

### W4 — Bot difficulties + Core ML seam — **Medium** (seam doc reviewed by Large)
- `Easy`: win/obvious claims, otherwise semi-random legal discard (seeded RNG — determinism preserved). `Normal`: current `HeuristicMahjongPolicy`. `Hard`: `CoachAdvisor` EV discards + light defense (prefer safe tiles when an opponent has ≥2 melds; never discard into an obvious last-tile win it can see from the river) — keep it honest: bots read ONLY `PublicObservationV3`.
- Difficulty selected per match (W3 launcher); wire through `MatchState` config.
- **`ModelMahjongPolicy` seam** (stub + doc, no model yet): conforms to `MahjongPolicy`, consumes `PublicObservationV3` + 127-wide `legalMask`, loads a bundled `.mlpackage` policy head when present — the action encoding is already the training contract (`GameTypes.swift:31-50`); document the observation→tensor layout expectations next to the protocol so the training side stays aligned.

### W5 — Polish: animation, haptics, minimal sound — **Medium** (sound + copy parts **Small**)
- Animations: discard flight to river, claim banner ("碰!" / "上!" / "槓!" / "食糊!"), draw slide, dealer-marker move, win reveal stagger. SwiftUI transitions; keep bot pacing (~420ms) as the animation budget.
- Haptics per house idiom: selection on tile tap, impact on discard/claim, notification on win/match end.
- **`GameSounds` (net-new, Small)**: tiny helper over `AudioToolbox`/short bundled `.caf`s — tile click, claim, win; respects silent switch; pref toggle (UserDefaults enum idiom). Keep it ≤1 file.
- Delete/replace remaining screenshot scaffolding.

### W6 — House-rules bridge + prefs — **Small** (spec below is the checklist)
- `HouseRulesView` is a static mock (`HouseRulesView.swift:5` "Values are static for now"). Wire Minimum faan (3/1), Limit cap (10/13), Flowers on/off, payment style to a `GameRulesPrefs` enum-over-UserDefaults; `MatchState` reads them at match start (mid-match changes don't apply).
- Entry point stays Settings → Advanced (**per user decision**); promotion later = moving one NavigationLink out of `#if DEBUG` — leave a `// PROMOTION:` comment marking the spot.

### W7 — Verification (every session, every workstream)
- `swift test --package-path Packages/MahjongGameEngine` (existing + new tests green; parity fixtures green under v2 profile). ScoringEngine/CoachEngine/EfficiencyEngine test suites untouched and green.
- `xcodegen generate` after any file add; build sim `id=38FB186D-F97B-4E30-A774-A759A12BEEE5` (iPhone 17, iOS 26) — note UDIDs are per-machine, `xcrun simctl list devices available`.
- UI check loop: install → `SIMCTL_CHILD_MJ_SCREEN=<scene> simctl launch` → screenshot (scenes are seed-deterministic; `instantBots` for programmatic full-match tests).
- Device QA checklist (user, M4 iPad): play a full match; observe dealer repeat after dealer win AND after a draw; prevailing wind advances; ledger sums to zero every hand; a seven-pairs win scores; claim timer auto-passes; showdown reveals hands; sounds/haptics fire; match-end standings correct.

## Sequencing & credit-budget priorities

```
W1 (Large) ──► W3 (Medium) ──► W5 (Medium/Small)
W2 (Large) ──┘                 W4 (Medium)   W6 (Small)
```
If credits run short, ship in this order — each stage is independently playable:
1. **P0 = W1 + W3** → "a real game": full match, rotation, scoreboard, honest seats/winds. (Biggest playability jump per token.)
2. **P1 = W2** → correct/complete HK rules + settlement.
3. **P2 = W4** → difficulties + model seam.
4. **P3 = W5 + W6** → feel + configurability.

## Handoff cautions
- **The working tree is shared with another active agent** (Tracker rework) — `git status` first, expect transient build failures in `Tracker*` files that are NOT yours; never "fix" their in-flight code.
- The parity fixtures are sacred: any engine change must either preserve v2-profile byte-parity or be isolated behind the profile switch (W2 strategy). When in doubt, don't touch `GameState` internals from a non-Large session.
- Two `try!`s exist (`GameSession.swift:31`, `GameState.swift:257`) — guarded today; W1's `MatchState` init should be `throws` and the session should surface errors, not crash.
