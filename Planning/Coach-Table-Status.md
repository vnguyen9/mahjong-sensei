# Coach Table-Awareness — Status

*Updated 2026-07-18*

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
every device incl. base iPhone 15 — the on-device LLM and LiDAR need iPhone 15 Pro+ and are
optional extras only):

| Stage | What | Status |
|---|---|---|
| **D** | Engine + session + Coach display (live outs, draw %, dead waits, melded hands) | ✅ **Done, verified** |
| **A** | `TableSceneParser` — auto-zones boxes (size-aware clustering → principal-axis lines/runs) | ✅ **Built** — 40/40 tests incl. 2 real-photo fixtures; tune on real photos |
| **B** | Vision homography (table → top-down quadrants) + foreground mask | ⏳ Device-only |
| **C** | **Live tracker (target)** — ByteTrack IDs, majority-vote faces, discard event log, live overlay | ⏳ Depends on A+B |
| **E** | Optional Pro-only extras (Foundation-Models verifier, LiDAR), detector retrain | ⏸ Future |

## What has been done (Stage D — the coaching payoff)
- **EfficiencyEngine**: `ukeire`/`rankDiscards` accept a `seen` 34-slot histogram folded into the
  existing `4 − visible` math; dead waits drop out; `winOdds(liveOuts:unseen:)` added.
  **23/23 tests** (6 new: reduced outs, dead wait, over-count clamp, nil ≡ unseeded, re-rank, odds).
- **ScanSession**: `myMelds` + `tablePool` buckets, `seenHistogram`, `unseenCount`; `hand` now
  passes `melds:`; coach count gate generalized to `14 − 3 × melds` (melded hands supported).
- **Coach UI**: "Reading N table tiles — outs below are live" caption; rows show live counts;
  dead-wait warning; wait sheet adds "~X% you draw one on your next pick"; locked meld strip in
  the hand tray.
- **Verified**: sim + device builds green; `MJ_SCREEN=coach-table` debug scene shows the proof —
  a 1m/4m wait reads **5 live** (not raw 8) with two 1m + one 4m in the pond.

## What has been done (Stage A — the auto-zoner)
- **`TableSceneParser`** (Recognition) implements the human rule — *closest, bottom-most line
  of big tiles = mine; everything else = the table's* — in measurable terms: size-aware
  clustering (apparent size as the depth cue), principal-axis line/run decomposition (tilted
  ranks stay whole), plus the carve-outs: adjacent 3–4 runs = my melds, adjacent lone tile =
  my draw, adjacent bonus tiles = my flowers. Far/small clusters → TABLE; leftovers →
  unresolved + a per-scene confidence for the future confirm/correct UI.
- **`Tools/detect-dump`** (macOS CLI) runs the *production* detector on photos and writes
  `.boxes.json` fixtures — photos become permanent regression tests.
  **40/40 Recognition tests**, including two real-photo fixtures (see
  `Planning/Mahjong Tables/fixtures/README.md`).
- **Finding:** the detector never fires on strongly *rotated* tiles (aotomo's pond 北 is
  invisible even at threshold 0.12). Pond recall on full-res photos is the key open question —
  if poor, a rotation-augmented retrain is the Stage E fix.

## What is still needed
1. **Capture path for the table** — today `tablePool` is only fed by the debug fixture; wiring
   `TableSceneParser` output into the session (+ confirm/correct UI) is the next build step.
2. **Real table photos to validate/tune the zoner** — folder curated at
   `Planning/Mahjong Tables/` with a `SHOOTING-GUIDE.md`; a handful of full-res player's-seat
   shots decide pond recall and thresholds.
3. **Stages B–C need on-device testing** (Vision + tracking don't run in the simulator).
4. **Turn-over-turn accumulation UX** — confirm/correct overlay, re-open next turn, add new discards.
5. **Housekeeping**: the entire session's work is **uncommitted**; device QA of Stage D on a real
   melded hand.

## Related (separate workstream)
A learned **faan-maximizing decision model** (self-play RL over a HK simulator, CNN over C×34,
reward = faan gated at the 3-faan minimum) has an approved research plan — it complements this:
table-awareness feeds its inputs; it supplies early-game value judgment the deterministic engine
can't. Gated on compute + scope decisions.
