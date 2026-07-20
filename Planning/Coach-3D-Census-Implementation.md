# Coach Live — 3D World Census Implementation Handoff

> **Status (2026-07-20):** Phases 0–4 are implemented on
> `codex/world-census`. Automated tests and universal iOS Simulator builds
> pass. M4 iPad device acceptance is still required before enabling census
> counts by default.
>
> **Release gate:** `coachLive.useWorldCensus` remains `false` unless explicitly
> set in `UserDefaults`. Do not flip the default until the device checklist in
> §8 passes.

## 1. Outcome

Coach Live no longer enters a guided sweep after finding the table. Plane lock
now enters normal tracking immediately and schedules one full-table inference.
Recounts are explicit one-shot requests and never present a blocking card.

The AR path now:

1. Opts into LiDAR depth when the device supports it.
2. Reuses the existing detector output to create trustworthy 3D observations.
3. Associates physical tiles in the existing `PhysicalCensus`.
4. Counts a missing tile only when its location is in the processed image
   coverage, has trustworthy depth, is unoccluded, and has been observed empty
   five times for at least 0.8 seconds.
5. Fits one play-area origin to confirmed world tracks and allows a manual
   “Recenter pond” raycast correction.
6. Stores only that table origin in one named `ARAnchor` inside an
   `ARWorldMap`. Tile counts and tile anchors never persist.

Non-LiDAR and Simulator execution keep the legacy 2D tracker path.

## 2. Why the old popup existed

The recording’s “Table found — pan slowly…” popup was not a detector error. It
was the intentional `.sweeping` capture stage rendered by
`StartupStatusOverlay.swift` while `CoachLiveSession.swift` ran a mandatory
sweep recipe. That lifecycle and its UI/state were removed in commit
`d6f9713`.

`StartupStatusOverlay` now covers only initial camera/table loading and ARKit
relocalization. There is no startup or recount path that can render the old
sweep copy.

## 3. Implemented architecture

```text
ARFrame
  captured image + camera pose/intrinsics
  optional smoothedSceneDepth/sceneDepth + confidence
        |
        v
existing full-frame/crop recognizer calls
        |
        +--> legacy TableTracker (fallback + temporary event derivation)
        |
        v
DepthSampler (5x5 median, medium/high confidence only)
        |
        v
TableProjection.worldPoint
        |
        v
WorldCensusController
  exact processed-image coverage
  expected-depth occlusion test
  PhysicalCensus association/lifecycle
  TableOriginState fit and zoning
        |
        +--> DEBUG parity/timing/world-point overlays
        |
        v
CensusStateAdapter --[feature/device gate]--> Coach Live counts
        |
        v
one named table-origin ARAnchor + atomic ARWorldMap archive
```

No additional recognizer invocation was added. The census consumes the same
detections already produced by Coach Live.

## 4. Phase status and commits

### Phase 0 — complete (`d6f9713`)

- Removed `.sweeping`, sweep timers, zone-progress state, “Done,” and sweep UI.
- Table lock calls `enterTracking()` and forces the first full inference.
- Added `RecountRequest.fullTable` and `.zone(TableZoneID)`.
- Pending recounts survive motion, thermal suspension, and relocalization.
- A request clears only when its full-frame/crop plan actually executes.

### Phase 1 — complete (`af564ce`)

- Capability-checked `.smoothedSceneDepth`, falling back to `.sceneDepth`.
- Added optional depth and confidence buffers to `ARTableFrame`.
- Added platform-neutral `DepthSampler` with 5×5 median sampling.
- Added world unprojection, inverse projection, and expected camera-axis depth.
- Added optional `worldPosition` to `TileObservation`.
- Added DEBUG world-point rendering.

### Phase 2 — complete (`ea82089`)

- Extended the existing `PhysicalCensus`; no duplicate census engine exists.
- World match radius: 18 mm; position EMA: 25% new sample.
- Confirmation: three hits in five qualified opportunities.
- Retirement: five qualified visible misses and at least 0.8 seconds.
- Added `CensusAnchor`, `CensusFrameContext`, and `CensusTrackSnapshot`.
- Added `anchors` and deterministic track snapshots.
- App-side visibility requires exact inference coverage, normal tracking, and
  valid depth. Geometry more than 40 mm nearer than the expected track depth is
  treated as occlusion and never as a miss.
- Added births/matches/misses/retirements, depth rejection, per-zone parity, and
  timing diagnostics.

### Phase 3 — complete (`57e6743`)

- Added `TableOriginState`:
  - plane height;
  - initial yaw faces the lock-time camera;
  - first translation fit at eight confirmed world tracks;
  - 5th–95th percentile bounds plus 120 mm padding;
  - 0.65–1.20 m clamp;
  - expand-only for 30 seconds, then freeze;
  - manual recenter permanently disables auto-fit for that session.
- Added “Recenter pond”; the next feed tap performs an AR raycast.
- Geometry overlay, ROI projection, and semantic zones use `worldToTable`.
- Added `CensusStateAdapter` with deterministic zone-to-UI mapping.
- Census corrections cover face pin, zone override, deletion, and hand reset.
- Count switching is gated by `coachLive.useWorldCensus` and at least eight
  confirmed census tracks.

### Phase 4 — complete in source; device verification pending

- Added one named table-origin anchor:
  `mahjong-sensei.table-origin`.
- Added one atomic Application Support archive containing:
  - securely archived `ARWorldMap`;
  - versioned table extent metadata.
- Saves only while world mapping is `.extending` or `.mapped`.
- Restores through `configuration.initialWorldMap`.
- Allows eight seconds to relocalize; then deletes the stale archive and starts
  fresh plane lock automatically.
- Restores table calibration only. Census tiles always begin empty.
- Hand reset clears census tiles and keeps the table origin.

The legacy tracker is intentionally still present in AR mode for event/turn
derivation and fallback. When the feature flag is active it does not determine
published AR counts. Remove it only after device parity proves the census delta
stream preserves event behavior.

## 5. Important files

| Responsibility | File |
|---|---|
| AR lifecycle, depth semantics, one origin anchor, world-map restore/save | `App/Sources/Features/CoachLive/Capture/ARTableCapture.swift` |
| Atomic secure world-map archive | `App/Sources/Features/CoachLive/Capture/ARWorldMapStore.swift` |
| Same-frame image/depth/pose carrier | `App/Sources/Features/CoachLive/Capture/ARTableFrame.swift` |
| App visibility/occlusion policy and census ownership | `App/Sources/Features/CoachLive/Capture/WorldCensusController.swift` |
| Census-to-UI state mapping | `App/Sources/Features/CoachLive/Capture/CensusStateAdapter.swift` |
| Loop, recounts, feature gate, actions, diagnostics | `App/Sources/Features/CoachLive/CoachLiveSession.swift` |
| Recenter control and tap surface | `CoachLiveView.swift`, `LiveFeedPane.swift` |
| Fitted-origin/world-point diagnostics | `LiveGeometryDebugOverlay.swift` |
| Depth sampling | `Packages/Recognition/Sources/Recognition/Tracking/DepthSampler.swift` |
| Projection/unprojection | `Packages/Recognition/Sources/Recognition/Tracking/TableProjection.swift` |
| Census association/lifecycle/snapshots | `Packages/Recognition/Sources/Recognition/Census/PhysicalCensus.swift` |
| Table-origin fit | `Packages/Recognition/Sources/Recognition/Census/TableOriginState.swift` |
| Versioned persistence metadata | `Packages/Recognition/Sources/Recognition/Census/WorldMapCalibrationMetadata.swift` |

## 6. Invariants

- Never infer empty space from an unprocessed part of the image.
- Missing/rejected depth, recognizer failure, non-normal tracking, offscreen
  tracks, and occlusion do not increment misses.
- Never guess a world point when depth is unavailable.
- Never run a second recognizer for the census.
- Count confirmed, stale, and temporarily-missing tracks until retirement.
- Never create per-tile `ARAnchor`s.
- Never restore tile counts across a hand or launch.
- Keep non-LiDAR behavior on the legacy plane-projected tracker.
- Do not enable `coachLive.useWorldCensus` by default before device acceptance.

## 7. Automated verification

Latest verified baseline:

```text
swift test --package-path Packages/Recognition
272 tests, 0 failures

xcodebuild -project MahjongSensei.xcodeproj \
  -scheme MahjongSensei \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/mahjong-dd \
  CODE_SIGNING_ALLOWED=NO build
BUILD SUCCEEDED (arm64 + x86_64)
```

Added coverage includes depth rejection and medians, projection round trips,
world-space jitter matching, adjacent-tile separation, out-of-view/occluded
survival, exact retirement threshold, deterministic corrections, table-origin
fit/freeze/recenter, and persistence metadata/version fallback.

## 8. Required M4 iPad acceptance

Run these in order and capture the DEBUG HUD/overlay:

1. Fresh launch: plane lock enters normal tracking with no sweep card; the first
   full inference runs automatically.
2. Recount FAB: exactly one recognizer pass and no modal/card.
3. Hold a stationary table while moving viewpoint: no duplicate births.
4. Pan zones away for at least ten seconds and return: identities/counts hold.
5. Cover tiles with a hand: no qualified misses or retirements.
6. Remove one tile and expose its old spot: retire only after the fifth
   qualified visible-empty observation and 0.8 seconds.
7. Recenter pond: overlay and zone ownership move together.
8. End hand: census tiles clear; table origin remains.
9. Relaunch in the same room: origin restores after relocalization; counts start
   empty.
10. Relaunch elsewhere or force an eight-second relocalization failure: stale
    map is discarded and fresh table lock begins.
11. Confirm DEBUG `inferencesRun` is unchanged by enabling the shadow census and
    census timing remains acceptable.

After all checks pass:

1. Set the `coachLive.useWorldCensus` default to `true`.
2. Repeat scenarios 1–10 with census-published counts.
3. Compare legacy and census event streams for a complete scripted hand.
4. Feed census deltas directly into the event/turn machinery.
5. Remove the legacy AR counting branch and temporary parity logging, while
   retaining the non-LiDAR fallback.

## 9. Known release boundary

Simulator builds prove compilation and non-LiDAR fallback; they cannot prove
LiDAR sampling, world-point stability, occlusion behavior, ARWorldMap
relocalization, or torch behavior. Those are device acceptance items, not safe
assumptions. The code therefore ships dark behind the census count flag while
still removing the legacy sweep popup for everyone.
