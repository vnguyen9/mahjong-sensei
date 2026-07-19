# Coach Table-Awareness — Status

*Updated 2026-07-18 (Coach Live v2: ARKit world-anchored tracking)*

## The ask
Coach only saw the player's own 14 tiles. To give real advice it must read the whole table —
the discard pond and revealed melds — so it can count which winning tiles are actually still
live, and advise with real odds. Capture should be as automatic as possible, building toward a
live "watch the game" tracker that survives the phone being picked up and moved.

## The plan (approved)
Everything reduces to **two buckets**:
- **MINE** — my concealed tiles + my own exposed melds (structure matters → drives shanten/ukeire).
- **TABLE** — all discards + opponents' melds (only counts matter → each visible copy is dead).

| Stage | What | Status |
|---|---|---|
| **D** | Engine + session + coach display (live outs, draw %, dead waits, melded hands) | ✅ Done — advice runs the faan-EV blend (CoachEngine) |
| **A** | `TableSceneParser` — auto-zones boxes in image space | ✅ Built — now the *fallback* path (see v2) |
| **B** | Vision homography | ✅ **Superseded** by the ARKit table-plane projection (v2) |
| **C** | Live tracker — stable IDs, majority-vote faces, event log, live overlay | ✅ Built + device-proven (pipeline verified live: VisionRecognizer, 14/14 rank tracked) |
| **v2** | **ARKit world-anchored capture** — see below | ✅ **Built** — device QA pending |
| **E** | Detector retrain (low-light/rotation recall) | ⏸ Future — ROI native-res crops (v2) expected to recover much of the gap first |

## Coach Live v2 (2026-07-18) — what was built

**UX fix bundle (Lane A):**
- Staged startup loading (`StartupStage` waterfall + center-feed `StartupStatusOverlay`; instant
  Start-button feedback) — "Start tracking did nothing" fixed.
- Hand-end nag cooldown (`handEndDismissCooldown` 20s; suppresses re-proposal while the *same*
  tiles are missing; new evidence overrides) — "keeps asking next hand" fixed.
- Corrections, full control: tap the MINE/POND bracket chip (pencil affordance) to bulk-reassign
  the zone (`TableTracker.overrideZone(tracks:)`); Counts tap-to-edit stepper made discoverable
  (hint line + one-time banner); hand-strip face fix already existed.
- Interim zoner rescue: a ≥8-tile single-row bottom-band cluster votes `.myHand` when the parser
  misses the rank (the observed rank→POND lock is dead in both modes).
- Dark-table torch chip (`MotionSample.meanLuma` → `DarkTableDetector` hysteresis → one-tap
  flash suggestion; ARKit lux drives it in AR mode).
- **Session persistence**: `TrackerSnapshot` state-export (TrackID-preserving) + throttled
  `CoachLiveSessionStore` writes + monotonic-clock remap on restore → the setup card offers
  "Resume session →" after a kill/crash (<12h). Debug scene `coach-live-setup-resume`.

**ARKit capture rebuild (Lane B):** `App/Sources/Features/CoachLive/Capture/`
- `ARTableCapture` + `PlaneLockPolicy` (pure): world tracking → largest stable horizontal plane
  → lock (plane detection off after) with **yaw alignment** so table-space +y points toward the
  player; `CaptureStage` lifecycle; torch + light estimate.
- `TableProjection`/`DetectionProjector` (Recognition package, simd-only, unit-tested): pixel
  ray ∩ plane → normalized table coordinates ((0.5,0.5)-anchored); detections ingest as
  synthetic table-space boxes → `TrackStore`/`TurnEngine` unchanged.
- `ZoneModel` table-space branch (`TrackerConfig.coordinateSpace` + `TableGeometry`): geometric
  zones — hand band + my melds at my edge, central pond, per-edge opponent melds. Image space
  stays the default (harness) and the live fallback (plane never locks / ARKit unavailable →
  the classic loop, verbatim).
- `CameraMotionGate`: pose-velocity freeze — nothing ingests while the camera moves ("Hold
  steady…" chip); full-frame re-sync on settle. **This is the "memory" fix** — table state now
  survives any camera move.
- `ARCameraPreview` (Metal/CoreImage blit, 30fps) replaces the AVCapture preview in AR mode;
  brackets project table-space zone rects through the current pose (overlay code unchanged).
  Scan tab and Coach Live no longer share a camera (AVCapture ↔ ARSession handover).
- **Smart ROI inference** (`ROIScheduler` + `ROICropMapper` + `PixelBufferCropper` +
  `MotionDetector.sampleField`): change-grid ∩ projected zone ROIs → native-resolution crops
  (3–4× pixel density on far tiles) with a 20s full-frame safety net; partial views are honest —
  `TableTracker.ingest(visibleRegion:)` stops off-crop tracks from being retired. Bypassable
  (`useROIScheduler`); harness untouched.
- **Guided sweep + rescan prompts**: after table lock, a "pan slowly across the table" card
  (coverage-tracked, Done link, plugged-in hint); per-zone staleness → directional "Pan left to
  check the pond ←" chips; "Rescan table" link re-enters sweeping anytime.

**Verified:** Recognition 197/197 (was 159 at arc start), detect-dump 6/6, negative-control
golden byte-identical throughout, sim + device builds green, all MJ_SCREEN mock scenes
unchanged. A cross-seam review pass (orientation math, loop lifecycle, partial-view semantics,
camera handover, concurrency) ran before handoff.

## What is still needed
1. **Device QA of the AR stack** (nothing below runs in the simulator): plane lock quality/
   timing, brackets staying glued through camera moves, sweep coverage + prompt directions,
   torch-during-ARSession, motion-gate thresholds, ROI crop recall vs full-frame, thermal over a
   long session, kill→relaunch resume, Scan↔CoachLive camera handover.
2. **Real gameplay video** (SHOOTING-GUIDE, "Video for the live tracker") — one full hand is
   still the highest-value footage for event-golden + attribution tuning.
3. **Housekeeping**: the entire workstream is **uncommitted** (two-plus arcs now, incl. the
   gitignored bundled `.mlpackage` detectors — tracking decision still open).

## Related (separate workstream)
A learned **faan-maximizing decision model** (self-play RL over a HK simulator) has an approved
research plan — gated on compute + scope decisions.
