# Coach Table-Awareness — Status

*Updated 2026-07-18 (Coach Live build)*

## The ask
Coach only saw the player's own 14 tiles. To give real advice it must read the whole table —
the discard pond and revealed melds — so it can count which winning tiles are actually still
live, and advise with real odds. Capture should be as automatic as possible (no manual zone
labeling), building toward a live "watch the game" tracker.

## The plan (approved)
Everything reduces to **two buckets**:
- **MINE** — my concealed tiles + my own exposed melds (structure matters → drives shanten/ukeire).
- **TABLE** — all discards + opponents' melds (only counts matter → each visible copy is dead).

The engine already computed live outs as `4 − visible`; feeding it a TABLE histogram makes every
number table-aware. Automatic zoning is **geometry + Vision on the detector's boxes** (works on
every device incl. base iPhone 15).

| Stage | What | Status |
|---|---|---|
| **D** | Engine + session + coach display (live outs, draw %, dead waits, melded hands) | ✅ Done — advice since upgraded to the faan-EV blend (CoachEngine) |
| **A** | `TableSceneParser` — auto-zones boxes (size-aware clustering → principal-axis lines/runs) | ✅ Built — real-photo fixtures; tuning continues on real photos |
| **B** | Vision homography (table → top-down quadrants) + foreground mask | ⏸ **Deferred** — the static-camera calibration inside `ZoneModel` (hand band + pond centroid/covariance) is the stand-in; homography can slot in later as a pre-ingest transform |
| **C** | **Live tracker** — stable IDs, majority-vote faces, discard/meld event log, live overlay | ✅ **Built** — full stack + Coach Live UI (this build); device QA pending |
| **E** | Optional Pro-only extras (Foundation-Models verifier, LiDAR), detector retrain | ⏸ Future — less urgent: the large (Pro) model already reads rotated pond tiles the nano misses |

## What has been built (Stage C — Coach Live, 2026-07-18)

**Tracker stack** (`Packages/Recognition/Sources/Recognition/Tracking/`, 158/158 package tests):
- `TrackStore` — ByteTrack-style two-band association for a static camera: stable `TrackID`s
  through flicker/dropout, rebirth matching (nudged tiles keep their ID — no double counting),
  confidence-weighted face vote ring with hysteresis; user pins win forever.
- `ZoneModel` — Stage-A parser votes on settled frames + static-camera calibration (hand band,
  pond centroid/covariance), zone hysteresis, locked user overrides.
- `TurnEngine` — **settle-diff** event derivation (nothing commits mid-motion): opponent
  discards/melds, my draw/discard, win detection; seat attribution = turn-order prior + motion
  region + pond geometry → softmax confidence, amber-flagged below threshold; evidence-over-prior
  turn resync (opponent draws are invisible; observed discards self-correct the rotation).
- `HandBoundaryDetector` + `WindRotation` — semi-auto hand boundaries (mass-disappearance
  sustained → non-destructive proposal with predicted wind rotation; walk-by protection),
  HK dealer-repeat rules incl. draws.
- `TableTracker` facade + corrections API (pin / zone override / insert / remove / amend /
  delete-event / confirm-hand-end) — corrections stick to track IDs and recompute the histogram.
- `MotionDetector` (vImage 32×18 luma grid, ~0.5 ms) + `CadencePolicy` (≈1 Hz idle / ≈5.5 Hz
  burst / settle-burst / thermal suspend) — hours-long sessions by design; assume plugged-in.

**Advice engine** (`Packages/CoachEngine`, 28/28 tests + EfficiencyEngine 28/28):
- EV-blend ranking: P(win) via an absorbing-chain DP × expected payout in base points (2^faan),
  exact per-wait faan at tenpai (both win channels), `FaanPotential` estimator before tenpai,
  hard 3-faan guardrail (undeclarable lines rank last at EV 0), bilingual "why" chips.
  `HKValueOverlay`/`hkValueTiebreak` deleted — subsumed.

**Coach Live UI** (`App/Sources/Features/CoachLive/`, replaces the Discard Trainer entirely):
- Split screen per the approved mockup: breathing live feed (40–72%, motion-driven, drag
  override), privacy blur (render-server composited), zone corner brackets (gold MINE / cream
  POND / amber unresolved·tap), Map ⇄ Counts ⇄ Events tabs, hand strip with gold DISCARD ring,
  advice line + wait chips, hand-ended card, win banner → one-tap Score-flow handoff.
  Entry: gold button under the Scan screen's (now two-mode) pill. Settings: feed blur +
  auto-breathing only. 9 `MJ_SCREEN=coach-live*` debug scenes.

**Offline harness** (`Tools/detect-dump`): `video-dump` (video → per-frame detections JSONL) and
`track-replay` (JSONL → tracker → event timeline + deterministic `.events.jsonl` goldens).
Negative control frozen: the wall-building clip (`IMG_6249`) produces ≤4 phantom events and no
hand-end proposal.

## What is still needed
1. **Device QA at a real table** — the loop, brackets, blur, thermal behavior, and attribution
   quality only prove out on-device (simulator runs the mock scenes only).
2. **Real gameplay video** (see `Planning/Mahjong Tables/SHOOTING-GUIDE.md`, "Video for the live
   tracker") — one full hand start-to-finish is the highest-value footage; it becomes the first
   real event-golden and drives attribution/threshold tuning. Key learned fact: **framing
   tightness, not capture resolution, decides pond recall** (everything letterboxes to 640 px).
3. **Real table photos** for zoner tuning (unchanged ask; task #45).
4. **Housekeeping**: the entire workstream is **uncommitted** (incl. the gitignored bundled
   `.mlpackage` detectors — tracking decision still open).

## Related (separate workstream)
A learned **faan-maximizing decision model** (self-play RL over a HK simulator) has an approved
research plan — the deterministic CoachEngine advisor now provides both its baseline and its
feature extractor; the tracker supplies its inputs. Gated on compute + scope decisions.
