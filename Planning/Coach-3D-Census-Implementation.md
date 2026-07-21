# Coach Live — Authoritative ARKit World Census Handoff

> **Source status (2026-07-20):** The authoritative census is integrated, and
> the fresh-session/tracking repair is split across commits `2fdb525`,
> `5027fac`, and `d00a47c`. Recognition has 293 tests; separate iPhone and
> iPad iOS 26.5 Simulator gates pass. The M4 iPad/LiDAR
> acceptance matrix in §9 remains a release gate
> because Simulator testing cannot validate depth, physical anchor stability,
> occlusion, or ARWorldMap relocalization.
>
> There is no `coachLive.useWorldCensus` feature flag and no production 2D
> fallback. Coach Live is temporarily restricted to LiDAR-equipped iPads.

## 1. User-visible outcome

Coach Live is no longer a camera-space counter with AR-shaped decoration:

- One AR/census pipeline starts before the primer or guided calibration and
  continues into Live without a confirmation-time restart.
- The marked pond, hand row, and revealed zones define one canonical table
  coordinate system.
- LiDAR detections become stable plane-projected world anchors.
- `PhysicalCensus` owns identity, lifecycle, semantic ownership, and every
  displayed AR count.
- Camera movement, panning away, missing depth, and hand occlusion cannot
  retire a tile.
- A tile retires only after five qualified visible-empty observations and at
  least 0.8 seconds.
- Recenter and recalibration update zoning, ROI planning, and overlays
  atomically.
- Exiting or relaunching discards calibration and counts. Every Coach Live
  entry starts the guided flow fresh while app-level first-run onboarding
  remains remembered independently.

The legacy “Table found — pan slowly…” sweep was removed in `d6f9713`. Plane
lock enters tracking and requests one full inference; recounts are one-shot
requests with no blocking popup.

## 2. Truthful source and health states

`CoachLiveCountSource` is the single count-source contract:

```swift
case spatialBootstrapping
case worldCensus
case legacy2D(LegacyFallbackReason)
```

`SpatialTrackingHealth` reports calibration, healthy tracking,
relocalization, depth loss, and limited tracking independently of count source.

On LiDAR hardware:

1. Coach Live starts in `spatialBootstrapping` and publishes an empty bootstrap
   state while calibration is in progress.
2. It publishes no legacy counts or production spatial overlays while
   calibration/confirmation is incomplete; guided calibration owns the review
   preview. Confirmation never reintroduces a blocking “Locking spatial
   tracking…” or “Looking for tiles…” screen.
3. Confirming valid calibration activates `worldCensus` immediately, even when
   zero tracks have confirmed yet.
4. If tracking is limited or depth disappears, the last census presentation
   is held and the overlays dim under “Recovering table tracking…”.
5. After two continuous seconds without depth, AR depth semantics restart once.
6. If pose or depth remains unhealthy for five continuous seconds, the current
   calibration and counts are cleared and guided calibration restarts.

Devices without supported scene depth cannot enter Coach Live. They see a
disabled, clearly labeled “Requires a LiDAR-equipped iPad” control. Spatial
polygons remain hidden unless calibration and tracking are healthy.

## 3. Coordinate and calibration architecture

### Continuous session

`ARTableCapture` starts before guided calibration. `ARCalibrationView` receives
that existing session and does not run, pause, reset, or replace it.

The guided flow has exactly three user-facing steps:

1. **Mark your hand row** — “Tap or pinch one end of your tiles, then the other.”
2. **Mark the pond** — “Tap or pinch two opposite corners of the discard area.”
3. **Review your table** — live AR preview with direct region dragging and
   “Confirm & Start”. Amber `person.fill` markers and the legend “Player
   marker — drag to the center of their exposed tiles.” identify the three
   opponent exposed-tile regions near the pond.

Step-3 edits emit a provisional `WorldTableCalibration` into the existing
`WorldCensusController`, legacy-compatibility geometry, AR origin, zones, ROI,
and overlays. They do not persist on every drag. Confirm finalizes that exact
calibration, queues one recount, and is a presentation-only handoff: it never
restarts the AR session, tracker, census controller, or pipeline generation.

`WorldTableCalibration` is the one geometry source:

```swift
tableToWorld
extent                         // independent X and Z
pondPolygon                    // exact marked polygon
handPolygon                    // exact marked orientation
revealedZonePolygons
source
```

The canonical table frame is constructed from the locked plane and guided
marks:

- origin = marked pond center projected onto the locked plane;
- `+Y` = plane normal;
- `+Z` = pond center toward the hand-row midpoint;
- `+X = cross(+Y, +Z)`;
- pond-to-hand distances below 150 mm and degenerate marks are rejected.

Width is `max(hand width + 120 mm, pond width + 240 mm)`. Depth is
`max(2 × pond-to-hand distance + 120 mm, pond depth + 240 mm)`. Each axis is
clamped independently to 0.65–1.20 m. The marked origin cannot be translated
or rotated by auto-fit. Depth tracks may only validate or expand bounds during
the first 30 seconds.

Recenter Pond raycasts the tap into the same AR world, then atomically updates
the table origin, polygons, semantic assignment, ROI geometry, overlays, and
persistence. Recalibration replaces the active calibration in the same session
and forces one full recount.

### iPadOS 26 image transform

Each `ARTableFrame` captures its current interface orientation and owns one
`FrameImageTransform`. That transform is used by recognition, tiled
recognition, crop mapping, depth sampling, table projection, hand pose,
raycasts, and overlays.

`ARFrame.displayTransform(for:viewportSize:)` maps raw camera pixels to the
preview. Production brackets and DEBUG polygons use
`ARCamera.projectPoint(_:orientation:viewportSize:)` against the same current
frame and shared orientation at 30 Hz, independent of recognizer cadence.
Portrait, upside-down portrait, landscape left, and landscape right are
supported on iPadOS 26. iPhone remains portrait-only.

An orientation transition skips the frame and cannot count as a miss.

## 4. Spatial observation and census lifecycle

The census reuses detections from the existing full-frame or crop recognizer
pass. It never invokes a recognizer.

For each detection:

1. Sample the center and inset centerline points.
2. At each point, take the median of a 5×5 medium/high-confidence depth
   neighborhood.
3. Reject non-finite, non-positive, low-confidence, or missing depth.
4. Reject geometry outside −10 to +60 mm relative to the table plane.
5. Take a robust median of accepted table-local X/Z points.
6. Project the identity anchor orthogonally onto the locked plane.
7. Retain measured surface depth separately for occlusion testing.

`PhysicalCensus` remains the only census implementation:

- association radius: 18 mm;
- position EMA: 25% new observation;
- confirmation: three hits in five qualified opportunities;
- retirement: five qualified misses and at least 0.8 seconds.

A miss is qualified only when the track projects inside the exact processed
coverage, AR tracking is normal, trustworthy depth exists, and geometry is not
more than 40 mm nearer than the expected track depth. Missing depth,
recognizer failure, orientation changes, limited tracking, relocalization,
offscreen positions, and occlusion never count as misses.

## 5. Authoritative state and event integration

`CensusStateAdapter` supplies every healthy LiDAR hand, bonus, meld, pond,
opponent, unresolved, histogram, and total count. Confirmed, stale, and
temporarily missing tracks remain counted until census retirement.

Semantic ownership is deterministic:

| Census zone | Published ownership |
|---|---|
| `mineHand` | my hand, or bonus by face |
| `mineMeld` | my meld |
| `tablePond` | pond |
| left/far/right revealed | matching opponent meld |
| `ignoredWall` | excluded |
| boundary/outside | unresolved |

The exact calibration polygons drive census ownership, ROI planning, production
brackets, production overlays, and DEBUG overlays. Independent X/Z extents are
preserved; no square `max(extent.x, extent.y)` normalization remains in the AR
pipeline.

The existing `TurnEngine` is retained, but the AR event read model is
synchronized from `CensusEventTrack`:

- census `TrackID` is preserved;
- face and lifecycle are copied exactly;
- semantic zone/seat are copied exactly;
- legacy association and `ZoneModel` are bypassed;
- legacy detection ingest is used only in explicit 2D mode.

Automated parity covers my discard, opponent discard, and meld events. This
bridge adds zero recognizer calls and keeps event-linked corrections addressable
by the same physical census ID.

Face pinning, zone correction, deletion, recount, recenter, recalibration,
histogram edits, and hand reset route according to `CoachLiveCountSource`.
End Hand clears census tiles while retaining calibration.

## 6. Fresh-session policy

AR world-map and tracker-session restoration are disabled while physical
tracking is stabilized:

- `ARTableCapture.start()` deletes any older world-map archive before starting;
- no AR world map is saved on pause, exit, or calibration confirmation;
- clean exit deletes calibration, counts, and in-flight Coach Live state;
- a killed and relaunched app opens Home, not Live;
- entering Coach Live always presents setup, primer, and guided calibration;
- app-level first-run onboarding remains a separate remembered preference.

The versioned metadata and world-map store remain dormant for future restore
work, but no current production route reads or writes them.

## 7. Diagnostics

The DEBUG HUD and console expose:

- count source and spatial health;
- calibration source;
- depth availability and acceptance rate;
- tentative, confirmed, stale, and temporarily missing tracks;
- births, matches, qualified misses, and retirements;
- anchor reprojection error;
- depth, height, orientation, and geometry rejection reasons;
- census processing time;
- existing recognizer invocation count.

The world-point overlay renders plane anchors at tile centers for device
validation. Diagnostics never cause another inference.

## 8. Phase commits and file map

| Phase | Commit | Outcome |
|---|---|---|
| 0 | `d7bbae2` | Truthful source/health characterization and continuity baseline |
| 1 | `b83b5a6` | Guided canonical calibration geometry near the pond |
| 2 | `c0fbd6c` | Three-step calibration review, direct drag, amber player markers |
| 3 | `7f377d8` | One pre-calibration AR/census pipeline and draft/final handoff |
| repair 1 | `2fdb525` | Fresh Coach Live sessions and LiDAR-only entry |
| repair 2 | `5027fac` | Five-second freeze-and-recalibrate recovery, no 2D fallback |
| repair 3 | `d00a47c` | Display-cadence projection from ARKit’s current camera |
| repair 4 | current commit | Shared orientation cleanup, diagnostics, documentation |

Important files:

| Responsibility | File |
|---|---|
| AR lifecycle, depth semantics, named anchor, relocalization | `App/Sources/Features/CoachLive/Capture/ARTableCapture.swift` |
| Dormant future ARWorldMap archive | `App/Sources/Features/CoachLive/Capture/ARWorldMapStore.swift` |
| Same-frame pose/image/orientation/depth carrier | `App/Sources/Features/CoachLive/Capture/ARTableFrame.swift` |
| Guided calibration UI using the shared session | `App/Sources/Features/CoachLive/Capture/ARCalibrationView.swift` |
| Visibility, occlusion, diagnostics, census controller | `App/Sources/Features/CoachLive/Capture/WorldCensusController.swift` |
| Census-to-UI adapter | `App/Sources/Features/CoachLive/Capture/CensusStateAdapter.swift` |
| Source transitions, loop, recounts, corrections | `App/Sources/Features/CoachLive/CoachLiveSession.swift` |
| Shared raw/oriented transform | `Packages/Recognition/Sources/Recognition/Tracking/FrameImageTransform.swift` |
| Projection/unprojection | `Packages/Recognition/Sources/Recognition/Tracking/TableProjection.swift` |
| Depth sampling | `Packages/Recognition/Sources/Recognition/Tracking/DepthSampler.swift` |
| Canonical guided calibration | `Packages/Recognition/Sources/Recognition/Census/WorldTableCalibration.swift` |
| Physical identities/lifecycle | `Packages/Recognition/Sources/Recognition/Census/PhysicalCensus.swift` |
| Census-to-event read model | `Packages/Recognition/Sources/Recognition/Census/CensusEventAdapter.swift` |
| Existing settle-diff event engine integration | `Packages/Recognition/Sources/Recognition/Tracking/TableTracker.swift` |
| Persistence metadata | `Packages/Recognition/Sources/Recognition/Census/WorldMapCalibrationMetadata.swift` |

## 9. Verification

Verified locally:

```text
swift test --package-path Packages/Recognition
293 tests, 0 failures

Xcode 26.5 SDK / deployment target iOS 26.0:
- generic iOS build: passed
- generic physical-device (`iphoneos`, arm64) build: passed
- separate iPhone iOS 26.5 Simulator gate: passed
- separate iPad iOS 26.5 Simulator gate: passed
```

Coverage includes canonical transform construction, exact polygons, independent
extent/clamping, invalid calibration, all four iPad orientation round trips,
depth rejection, stable plane anchors, 24 mm adjacent-tile separation,
pan-away and occlusion survival, exact fifth-miss retirement, deterministic
corrections, source-safe event parity, old persistence rejection, and v3
metadata round trip. The unrelated untracked `Modeling` directory is preserved.

Still required on an M4 iPad with LiDAR:

1. Confirm guided calibration and Live retain the same AR session.
2. Check pond/hand overlays within one tile width from three viewpoints.
3. Rotate through all four iPad orientations and verify the same anchor stays
   on each tile.
4. Confirm DEBUG reports `source=CENSUS`.
5. Confirm no spatial overlay is paired with legacy counts.
6. Pan a zone away for ten seconds; counts and identities must hold.
7. Cover tiles by hand; qualified misses and retirements must remain unchanged.
8. Remove one tile; retirement must occur only after five qualified
   visible-empty observations and 0.8 seconds.
9. Recenter; overlay and ownership must move together immediately.
10. Recalibrate live; no second coordinate system may appear.
11. End Hand; tiles clear and calibration remains for that active session.
12. Exit Coach Live; calibration and counts clear after confirmation.
13. Force-quit and relaunch; Home appears, and the next Coach Live entry starts
    fresh guided calibration.
14. Interrupt pose or depth temporarily; the last census state holds and
    degradation is visible. Recovery within five seconds resumes; sustained
    failure returns to fresh calibration without 2D counts.
15. Compare `inferencesRun` before/after census processing; the census must add
    zero invocations.

These are physical-device gates, not deferred source work. Do not declare the
LiDAR release accepted from Simulator results alone.
