# Coach Live — AR Onboarding & Calibration (Build Spec)

**Product:** Mahjong Sensei / MahjongMate — Coach Live (AR table tracker)
**Scope:** the ARKit onboarding + calibration flow and its in-session correction/recovery states. This is the UX layer the engineering handoff (`Coach-Live-AR-Handoff.md`) never designed.
**Platform:** iPhone only, portrait-locked. ARKit world-tracking.
**Source of truth for code seams:** `Packages/Recognition` (`TableTracker`, `ZoneModel`, `TurnEngine`, `TableProjection`, `TableCalibrationGeometry`), `Packages/EfficiencyEngine`, app `Features/CoachLive`.

---

## 0. First principles (do not violate)

- **Calibration is coarse by design.** The entire payload is a handful of world-anchored numbers, not a mesh.
- **Calibration runs automatically** after plane-find and **before** tracking begins (removes the read-once-at-lock footgun in handoff §7.1).
- **Point/pinch is the hero; tap is always the fallback.** Hand-pose can miss (dark rooms, gloves) — never dead-end.
- **The 3D hand region is placed, world-anchored geometry** (the Measure-app pattern), recomputed only when a handle moves. It is **NOT** a per-frame hand segmentation or a live hand-mesh — that class of workload is exactly what the Phase-0 thermal fix removed. Hand-pose fires **only during marking**, then stops.
- **Movement ≠ recalibration.** ARKit runs continuously and zones are world-anchored, so panning is free. Only a true interruption triggers recovery; only a failed recovery triggers recalibration.
- **Opponents = seats + melds, never hands.** Concealed hands are unreadable.

---

## 1. The calibration payload (`TrackerConfig.TableGeometry`, extended)

| Field | Meaning | Range / notes |
|---|---|---|
| `extent` | table span in metres | 0.40–1.60 (default 0.9) |
| `handBand {a, b, depth}` | **oriented** hand row: 2 end-post points on the plane + inward depth | replaces the old scalar `handBandDepth`; still tiny; follows the row even at an angle |
| `pondRadius` | central discard disk radius, fraction of extent | 0.10–0.45 |
| `seats[4]` | wind per seat (`RelativeSeat` → `Wind`) | your seat = +Z edge; others counter-clockwise E→S→W→N |
| `meldBands` | per-opponent meld zone hugging that seat's inner edge | reuses `handBandDepth` for depth |

`ZoneModel` in `.tableSpace` mode treats `tableGeometry != nil` as calibrated and bypasses the image-space heuristics. Geometry is read **once** at tracker build (`CoachLiveSession` table-lock), so it must resolve before lock→tracking.

---

## 2. Flow contract (sequence)

```
primer (first run only)
  → ARCoachingOverlayView(.horizontalPlane)          // Apple onboarding + grey plane grid
  → PlaneLockPolicy lock (+Z-toward-user yaw)         // grid tints gold on lock
  → AUTO-PRESENT ARCalibrationView:
        MarkStage.handBand   (pinch posts A + B, oriented band auto-spans)
        MarkStage.pondEdge   (point/tap the pond centre)
        MarkStage.seats      (auto-derived, tap-nudge)
        MarkStage.done       (confirm; draggable end-caps)
  → onComplete(TableGeometry) → calibratedTableGeometry
  → sweep pass (one-time full-frame, ROI scheduler bypassed)
  → beginSession → steady-state tracking
```

**Runtime:** ARKit runs continuously; geometry is world-anchored. On interruption → recover silently (`limited(.relocalizing)`); prompt a full recalibrate only if it can't recover past the 25 s deadline.

---

## 3. Screens — Section A: Onboarding & calibration

### 1 · Illustrated primer *(first run only)*
- Explains **why** the table geometry is needed, before any camera-permission prompt. Doubles as the soft permission primer; OS prompt fires on "Set up table".
- Three plain-language steps: find the table → bracket your tiles → point at the pond. Privacy line: "Camera is used live only. Nothing is recorded or uploaded."
- Skipped on subsequent sessions; re-reachable from Settings.

### 2 · Plane finding
- Apple `ARCoachingOverlayView`, goal `.horizontalPlane`: device-nudge animation + system copy ("Move iPhone to find the table").
- Beneath it, the default grey `ARPlaneAnchor` grid mesh grows as ARKit refines `extent`. Overlay auto-hides on lock.
- 25 s deadline (`arLockDeadline`) or ARKit unavailable → **2D fallback** (screen 15).

### 3 · Plane lock *(auto, ~1 s)*
- Grid tints **gold** to confirm lock (`PlaneLockPolicy`: same candidate 2 s, centre drift < 0.02 m, within 1.5 m). Plane detection turns off to save power.
- Show the **+Z-toward-user** arrow so the user confirms the near edge is theirs (the locked yaw contract the whole geometry stack depends on). Auto-advances.

### 4 · Bracket your hand row  `MarkStage.handBand`
- **Pinch** (thumb + index, from `HandPoseFingertip`) to drop a **post at each end** of your tile row (A, then B). Each fingertip is raycast to the plane by `TableProjection.tablePoint`.
- The band **auto-spans and orients to the A→B line**, so it follows your row even at an angle.
- Posts are world-anchored 3D, recomputed only on drag (cheap). 21-joint skeleton overlay shown as live feedback; hide once a mark lands.
- **Fallback:** tap two points on the grid.
- Sets `handBand {a, b, depth}`.

### 5 · Mark pond  `MarkStage.pondEdge`
- Same point/tap interaction; single point at the pond edge/centre.
- Sets `pondRadius = hypot(pond.x, pond.y) / extent`.

### 6 · Seats & opponent melds  `ZoneModel · RelativeSeat`
- **Derivation:** the locked plane gives the table square; its 4 edge-midpoints become the seats. Your seat = the +Z edge (`mySeatWind`); the other three are assigned **counter-clockwise E→S→W→N** — Right = next, Across = +2, Left = +3. Zero taps to place; tapping a seat re-labels its edge (never moves the plane).
- **Per opponent:** a meld zone hugging that seat's inner edge (reuses `handBandDepth`). Tiles landing there = exposed melds → `state.opponentMelds[RelativeSeat]`.
- **Discards** still go to the central pond; the seat only **attributes** who discarded, feeding `TurnEngine` + `WindRotation`.
- **Not marked:** concealed hands (faces hidden, unreadable). v1 assumes 4 seats; 3-player is a later flag.

### 7 · Confirm zones  `MarkStage.done`
- Geometry rendered back onto the plane: the **oriented hand band** (A→B segment + depth, with draggable end-caps) and the pond disk.
- Live `cal:` HUD, e.g. `cal: extent 0.92m · row 34cm @ −4° · pond r30cm`.
- Confirm returns `TableGeometry` via `onComplete` → stored in `calibratedTableGeometry`, read once at tracker build.

### 8 · Sweep pass
- One-time full-frame pass (ROI scheduler bypassed). Coverage ring fills as zones are seen.
- Exits on **Skip** or (≥ 12 s AND coverage complete) → forces one inference → steady-state tracking.

### 9 · Hand-off to Coach Live
- Onboarding dissolves into the tracking screen (see the **Coach Live View** design). One-time "Calibrated · tracking live" toast.
- Feed keeps **faint zone overlays**: your oriented hand band (same oriented display as screen 7), the pond, and each opponent's meld tag. Your band brightens on your turn. Opponents' full detail lives in the top-down Map.
- Steady-state. To correct counts: **tap the Counts tab** → tap a tile (→ screen 11).

---

## 4. Screens — Section B: In-session corrections & recovery

### 10 · Force recount
- Default cadence is event-driven (recount **only when tiles move** — protects the thermal win).
- Floating ↻ FAB forces a full-frame re-read; long-press → **per-zone recount** (just the pond / just my hand) so one messy zone doesn't cost a whole sweep.

### 11 · Adjust tile counts & see stats
- **Getting here:** from tracking (screen 9) → **Counts** tab → tap any tile.
- Tap a tile → **inline stepper** (± copies seen, shown as *seen / 4*). **More ›** → full sheet: set exact count, mark all-dead, reassign zone.
- Each edit calls a tracker correction API — `insertMissedTile` / `removeTrack` / `overrideZone` / `pin` — which recomputes `seenHistogram + unseenCount` and bumps `state.revision`.
- A **LIVE stats strip** re-runs instantly on that revision bump: `EfficiencyEngine.rankDiscards(hand, tableSeen:)` for shanten + ukeire, and `winOdds(liveOuts:unseen:)` for the draw %.

### 12 · Correct my hand
- Freeze the last frame, split into two labelled zones (MY HAND / TABLE), **drag mis-assigned tiles** between them.
- Each drop = an `overrideZone` call; the whole edit commits as one settled correction batch.

### 13 · Big-table corner nudge  *(fallback · D2 · AR-anchored)*
- For a table larger than the auto extent. Each dragged corner is **raycast onto the locked plane** (`TableProjection.tablePoint`) so it sticks to the real surface at correct depth (not floating in 2D screen space).
- One-tap **"Snap to detected plane"** grabs ARKit's own `planeAnchor.extent / boundaryVertices`.
- Only adjusts `extent`; hand/pond fractions ride along. Secondary path, never primary.

### 14 · ARKit recovery  `limited(.relocalizing)`
- ARKit tracking **always runs**; geometry is world-anchored → panning needs no recalibration.
- Only a true interruption drops to `limited(.relocalizing)`: **freeze state, dim feed, "point back at the table" nudge, auto-resume** on recovery. Last state held; advice paused.
- Past the 25 s deadline → surface **Recalibrate** (also always available in the menu) → 2D fallback.

### 15 · Lock-failed → 2D fallback
- If the plane never locks within 25 s (`arLockDeadline`) or ARKit is unavailable, degrade gracefully to the 2D full-frame loop — no crash, no calibration, still counts.
- Full-frame scanning reticle + banner. "Retry AR setup" re-enters the flow at screen 2.

---

## 5. Design decisions worth flagging

- **Pinch-to-bracket the row, point/tap the pond.** Hand region = 2 world-anchored posts (oriented band); pond = one point. Every mark screen keeps a Tap fallback.
- **The 3D region is anchored geometry, not a tracked hand** — recomputed only on drag; no per-frame segmentation.
- **Skeleton overlay is feedback, not chrome** — it proves detection is live; hide it once a mark lands.
- **Corrections mirror the tracker's public API 1:1** (`overrideZone / insertMissedTile / removeTrack / pin`) so wiring is mechanical.
- **Recount is event-driven by default** — the manual ↻ is an escape hatch, not the norm.
- **Opponents = seats + melds, never hands** — auto-place 4 seats (tap to nudge) + a meld zone per edge for attribution + wind rotation.
- **Movement ≠ recalibration** — world-anchored zones survive panning; recover silently on interruption, recalibrate only on timeout (manual option always in the menu).

---

## 6. Key code seams (implementing agent)

| Concern | Symbol |
|---|---|
| Plane lock + yaw | `PlaneLockPolicy` (+Z toward user) |
| Screen-point → plane (finger/tap/corner raycast) | `TableProjection.tablePoint(ofNormalizedOrientedPoint:orientedImageSize:)` |
| Fingertip detection | `HandPoseFingertip` (`VNDetectHumanHandPoseRequest`, index tip; pinch = thumb+index) |
| Marks → geometry | `TableCalibrationGeometry.geometry(extentMetres:handBandInnerEdge:pondEdge:)` (extend for oriented band + seats) |
| Geometry storage / read-once | `CoachLiveSession.calibratedTableGeometry` (read at table lock) |
| Game state | `TableTracker` → `TrackedTableState` (`seenHistogram`, `unseenCount`, `opponentMelds[RelativeSeat]`, `revision`) |
| Corrections | `TableTracker.pin / overrideZone / insertMissedTile / removeTrack` |
| Advice / stats | `EfficiencyEngine.rankDiscards(_:tableSeen:)`, `ukeire(_:melds:seen:)`, `winOdds(liveOuts:unseen:)` |
| Seat attribution / winds | `TurnEngine`, `WindRotation` |
| Recovery | `ARCamera.TrackingState.limited(.relocalizing)`; `arLockDeadline` (25 s) → 2D `startLoop` |

---

*Companion to the visual spec `Coach-AR-Onboarding-standalone.html` (15 annotated device frames). Where the two differ, the code seams above and `Coach-Live-AR-Handoff.md` win.*
