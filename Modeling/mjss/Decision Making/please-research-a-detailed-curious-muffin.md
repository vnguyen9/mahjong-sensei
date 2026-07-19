# Create `Planning/Coach-Table-Status.md` — status summary of the table-aware Coach work

## Context
The user asked for a short markdown summary of the "Coach must see the whole table" workstream:
the plan, what's done, what's still needed. Single new file, no code changes. Location:
`Planning/` (alongside Design-Spec.md / MahjongMate-PRD.md). Content below is written from this
session's verified state (Stage D shipped + verified; Stages A–C pending; learned-model plan
approved separately).

## The file to create — exact content

```markdown
# Coach Table-Awareness — Status

*Updated 2026-07-17*

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
| **A** | `TableSceneParser` — auto-zone boxes via size-normalize → DBSCAN → RANSAC/Hough | ⏳ Next |
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

## What is still needed
1. **Capture path for the table** — today `tablePool` is only fed by the debug fixture; the camera
   flow doesn't populate it yet. This is what Stages A–C deliver.
2. **Stage A blocker: real labeled table photos** (~a handful, mid-game, hand + pond + melds from a
   normal phone angle) to tune/validate the geometric zoner — synthetic-only would be self-graded.
3. **Stages B–C need on-device testing** (Vision + tracking don't run in the simulator).
4. **Turn-over-turn accumulation UX** — confirm/correct overlay, re-open next turn, add new discards.
5. **Housekeeping**: the entire session's work is **uncommitted**; device QA of Stage D on a real
   melded hand.

## Related (separate workstream)
A learned **faan-maximizing decision model** (self-play RL over a HK simulator, CNN over C×34,
reward = faan gated at the 3-faan minimum) has an approved research plan — it complements this:
table-awareness feeds its inputs; it supplies early-game value judgment the deterministic engine
can't. Gated on compute + scope decisions.
```

## Verification
File exists at `Planning/Coach-Table-Status.md`, renders cleanly (one page, one table), and the
facts match the session record (Stage D verified, A–C pending, photo/device dependencies flagged).
