# Coach Live — Authoritative ARKit World Census Handoff

> **Source status (2026-07-21):** The authoritative census now stays on one
> persistent AR surface from marking through Live, exposes endpoint-defined
> player regions, publishes unknown physical tiles, schedules every region
> fairly, and requires depth-proven bare table before retirement. Post-
> calibration recognition is clipped to the calibrated table, uses split
> 45% birth/30% continuation confidence, and publishes faces only from two
> qualified 80% detail reads. Optional tile measurement drives every physical
> geometry consumer. Recognition has 339 tests; iPhone and iPad iOS 26 Debug
> and Release Simulator builds pass. The
> M4 iPad/LiDAR
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
6. If pose remains limited for five continuous seconds, the same AR surface
   returns to editable review while holding the last census snapshot. It does
   not replace the renderer, reset the session, or delete the calibration.

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
   “Confirm & Start”. Each opponent region is a 40 mm-deep strip with two
   endpoint controls: drag the body to translate it, or either endpoint to
   resize and rotate it. Regions have a 72 mm minimum length, stay clamped to
   the calibrated extent, provide 44-point projected hit targets, selection
   haptics, and VoiceOver-labelled start/end/body controls.

Step-3 edits emit a provisional `WorldTableCalibration` into the existing
`WorldCensusController`, legacy-compatibility geometry, AR origin, zones, ROI,
and overlays. They do not persist on every drag. Confirm finalizes that exact
calibration, queues one recount, and is a presentation-only handoff: it never
restarts the AR session, tracker, census controller, or pipeline generation.

One `CoachLiveARSurface`/`ARSCNView` remains mounted above the flow switch.
Confirmation changes its mode from editable review to read-only Live. The same
SceneKit region nodes and labels remain visible; only handles, grid, coaching
instructions, and edit gestures hide. Production Live uses a full-screen AR
surface with a draggable gameplay bottom sheet, so expanding Map/Counts/Events
never crops or resizes the camera renderer.

`WorldTableCalibration` is the one geometry source:

```swift
tableToWorld
extent                         // independent X and Z
pondPolygon                    // exact marked polygon
handPolygon                    // exact marked orientation
revealedZoneMarks             // exact start/end/depth controls
revealedZonePolygons
tileDimensions                 // width, length, height
tileDimensionsSource           // standard, measured, or manual
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

Step 3 also contains an optional Tile Size card. Standard dimensions are
24×32×16 mm. The user may measure one isolated face-up tile using five stable,
depth-backed samples over at least one second, accept the preview explicitly,
or adjust width/length manually in 1 mm increments. Rejected or skipped
measurement never blocks calibration. A single `tileDimensions` value drives
association gates, tile footprints, depth-empty sampling, crop margins,
overlay geometry, and map presentation without restarting ARKit.

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

- birth confidence: 45%; existing-track continuation/reacquisition: 30%;
- primary association radius: `min(18 mm, 0.75 × measured width)`;
- stale/missing reacquisition radius:
  `min(22 mm, 0.95 × measured width)`, mutual-best only;
- position EMA: 25% new observation;
- confirmation: three hits in five qualified opportunities;
- retirement: five qualified misses and at least 0.8 seconds.

Association is deterministic global one-to-one assignment rather than greedy
nearest-neighbour matching. An unmatched observation close to a viable stale
identity cannot immediately birth a replacement. Tentative duplicates may
merge only within `min(10 mm, 0.45 × measured width)`; confirmed adjacent tiles
are never merged.

A miss is qualified only when the camera and image are still, AR tracking is
normal, the exact executed ROI covers the anchor, and at least three
medium/high-confidence samples across its physical footprint prove bare table.
The table-local median height must be −10...+8 mm and the upper percentile no
higher than +12 mm. Geometry 12...40 mm above the plane is occupied; geometry
more than 40 mm nearer than expected is occluded; missing or inconsistent depth
is unknown. All three cases hold the identity. Missing depth, recognizer
failure, orientation changes, camera motion, thermal suspension, limited
tracking, relocalization, offscreen positions, and occlusion never count as
misses.

## 5. Authoritative state and event integration

`CensusStateAdapter` supplies every healthy LiDAR hand, bonus, meld, pond,
opponent, unresolved, histogram, and total count. Confirmed, stale, and
temporarily missing tracks remain counted until census retirement.

`CensusPresentation` separates resolved gameplay tiles from confirmed physical
anchors whose face is unknown. Unknown anchors still count toward their exact
hand/pond/player/unresolved region and render as tappable `?` placeholders, but
do not enter scoring, face histograms, advice, or conservation until corrected.
The displayed Live total is the sum of census physical zone counts—never a mix
of census and legacy tracker state.

After confirmation, the existing recognition loop verifies Hand → Pond → Left
→ Far → Right. Each region receives up to three successful still-frame reads,
ending early when census identities and faces repeat stably. The two-crop limit
lives in `ROIScheduler`; deferred/offscreen work remains queued with age-based
fairness, and DEBUG labels report only recognizer calls that actually executed.
The census never invokes a recognizer.

All production recognition after calibration is table-only. The calibrated
table polygon is projected into the current oriented frame; the adaptive grid
skips cells outside it, masks pixels outside the polygon, and rejects detection
centres outside it. Semantic-region and detail work uses each exact projected
polygon with one measured-tile margin, clipped to the table. Oversized work is
subdivided so the tile short side reaches at least 32 model pixels. Unknown,
conflicted, and weak-face tracks enter a fair shared detail queue, still under
the two-crop normal-tick budget. Camera movement suspends Core ML while world
anchors continue rendering; queued work runs immediately after settling. The
20-second recovery pass is the same table-only adaptive grid, never a room-wide
camera pass.

Face evidence carries inference pass ID, pass kind, timestamp, crop, model-
space tile size, and camera-still state. Broad discovery may maintain identity
and improve suggestions, but cannot publish a face. Automatic publication
requires two matching ≥80% depth-valid detail reads from distinct successful
passes, at least 0.5 seconds apart, with a model-space short side of at least
32 pixels. Duplicate boxes in one pass count once. Moving, undersized, broad,
or low-confidence reads cannot advance or contradict publication. Two
contradictory qualified detail reads return an automatic face to `?`; a
user-pinned correction remains authoritative.

Semantic ownership is deterministic:

| Census zone | Published ownership |
|---|---|
| `mineHand` | my hand, or bonus by face |
| `mineMeld` | my meld |
| `tablePond` | pond |
| left/far/right revealed | matching opponent meld |
| `ignoredWall` | excluded |
| boundary/outside | unresolved |

Manual ownership always wins. Automatic ownership changes only after three
observed votes inside a different polygon. Boundary jitter preserves the prior
zone; a unique gap of at most `min(8 mm, tile width / 3)` snaps to the nearest
polygon, while overlap/equal-distance ambiguity remains unresolved.

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
- physical-versus-resolved totals and unknown-face anchors;
- executed and deferred ROIs plus ordered verification progress;
- bare-plane proofs, occupied holds, occlusion holds, missing-depth holds, and
  depth-proven retirement causes;
- anchor reprojection error;
- depth, height, orientation, and geometry rejection reasons;
- census processing time;
- existing recognizer invocation count.
- 30–44% continuation and ≥45% birth-eligible observations;
- primary matches, stale reacquisitions, suppressed replacement births, and
  tentative duplicate merges;
- recognition pass ID/kind, crop pixels, model-space tile size, and Core ML
  duration;
- table-mask skipped cells and rejected outside-table boxes;
- broad suggestions, qualified detail reads, face publications, and conflicts;
- recount waiting/running/progress/completion state;
- tile dimensions and standard/measured/manual source;
- automatic, manually overridden, and unresolved ownership totals.

The world-point overlay renders plane anchors at tile centers for device
validation. Diagnostics never cause another inference.

## 8. Phase commits and file map

| Phase | Commit | Outcome |
|---|---|---|
| 1 | Phase 1 commit | One persistent AR surface, read-only Live mode, full-screen renderer, bottom sheet |
| 2 | Phase 2 commit | Endpoint-defined accessible player regions and exact polygons |
| 3 | Phase 3 commit | Unknown physical tiles plus fair ordered verification scheduling |
| 4 | Phase 4 commit | Depth-proven bare-plane retirement, conservative holds, diagnostics, handoff |

Important files:

| Responsibility | File |
|---|---|
| AR lifecycle, depth semantics, named anchor, relocalization | `App/Sources/Features/CoachLive/Capture/ARTableCapture.swift` |
| Dormant future ARWorldMap archive | `App/Sources/Features/CoachLive/Capture/ARWorldMapStore.swift` |
| Same-frame pose/image/orientation/depth carrier | `App/Sources/Features/CoachLive/Capture/ARTableFrame.swift` |
| Guided calibration UI using the shared session | `App/Sources/Features/CoachLive/Capture/ARCalibrationView.swift` |
| Visibility, occlusion, diagnostics, census controller | `App/Sources/Features/CoachLive/Capture/WorldCensusController.swift` |
| Census-to-UI adapter | `App/Sources/Features/CoachLive/Capture/CensusStateAdapter.swift` |
| Fair ROI and verification scheduler | `App/Sources/Features/CoachLive/Capture/ROIScheduler.swift` |
| Table polygon masking and crop mapping | `App/Sources/Features/CoachLive/Capture/PixelBufferCropper.swift` |
| Table-only adaptive tiled recognition | `App/Sources/Features/Tracker/TiledTileRecognizer.swift` |
| Source transitions, loop, recounts, corrections | `App/Sources/Features/CoachLive/CoachLiveSession.swift` |
| Shared raw/oriented transform | `Packages/Recognition/Sources/Recognition/Tracking/FrameImageTransform.swift` |
| Projection/unprojection | `Packages/Recognition/Sources/Recognition/Tracking/TableProjection.swift` |
| Depth sampling | `Packages/Recognition/Sources/Recognition/Tracking/DepthSampler.swift` |
| Canonical guided calibration | `Packages/Recognition/Sources/Recognition/Census/WorldTableCalibration.swift` |
| Physical identities/lifecycle | `Packages/Recognition/Sources/Recognition/Census/PhysicalCensus.swift` |
| Deterministic global association | `Packages/Recognition/Sources/Recognition/Census/TrackAssociation.swift` |
| Qualified face-read fusion | `Packages/Recognition/Sources/Recognition/Census/FaceFusion.swift` |
| Optional tile measurement policy | `Packages/Recognition/Sources/Recognition/Tracking/TileSizeMeasurement.swift` |
| Physical/unknown presentation | `Packages/Recognition/Sources/Recognition/Census/CensusPhysicalPresentation.swift` |
| Tested deferred/verification policy | `Packages/Recognition/Sources/Recognition/Census/DeferredRegionWorkQueue.swift` |
| Bare/occupied/occluded depth policy | `Packages/Recognition/Sources/Recognition/Census/TileFootprintDepthEvidence.swift` |
| Census-to-event read model | `Packages/Recognition/Sources/Recognition/Census/CensusEventAdapter.swift` |
| Existing settle-diff event engine integration | `Packages/Recognition/Sources/Recognition/Tracking/TableTracker.swift` |
| Persistence metadata | `Packages/Recognition/Sources/Recognition/Census/WorldMapCalibrationMetadata.swift` |

## 9. Verification

Verified locally:

```text
swift test --package-path Packages/Recognition
339 tests, 0 failures

Xcode 26.5 SDK / deployment target iOS 26.0:
- iPhone iOS 26 Simulator Debug: passed
- iPad iOS 26 Simulator Debug: passed
- iPhone iOS 26 Simulator Release: passed
- iPad iOS 26 Simulator Release: passed
```

Coverage includes canonical transform construction, exact polygons, independent
extent/clamping, invalid calibration, all four iPad orientation round trips,
depth rejection, stable plane anchors, 24 mm adjacent-tile separation,
known/unknown physical presentation, ordered three-read verification, deferred
ROI survival and starvation freedom, occupied/occluded depth holds, bare-plane
classification, pan-away survival, exact fifth-miss retirement, deterministic
corrections, source-safe event parity, old persistence rejection, and v3
metadata round trip. The unrelated untracked `Modeling` directory is preserved.

The 339-test suite additionally covers split 45/30 confidence, deterministic
global assignment, stale mutual-best reacquisition and birth suppression,
measured-width adjacency, broad-pass non-publication, unique-pass and 0.5-second
face evidence, three-vote ownership changes, and accepted/rejected/reset tile
measurement.

Still required on an M4 iPad with LiDAR:

1. Confirm with the DEBUG HUD visible: session ID, pipeline generation, reset
   counters, camera image, and region reprojection do not jump or blink.
2. Exact labelled regions remain visible immediately in read-only Live mode;
   handles disappear and Recalibrate restores them on the same surface.
3. The collapsed gameplay sheet leaves the near hand visible, and all five
   regions complete ordered verification with executed/deferred HUD evidence.
4. Unknown physical anchors appear as `?` placeholders and displayed physical
   zone totals equal the DEBUG physical totals.
5. Move through three viewpoints and all four supported iPad orientations;
   regions and confirmed anchors stay within one tile width.
6. Pan a zone away for ten seconds; counts and identities hold. Cover tiles by
   hand; occupied/occlusion holds rise while qualified misses do not.
7. Remove one tile and reveal bare table; `empty` proofs advance retirement
   only on the fifth qualified observation spanning at least 0.8 seconds.
8. Recenter and recalibrate; overlay, ROI geometry, and ownership move together
   without a second renderer/session/coordinate system.
9. End Hand clears tiles but retains in-session calibration; exit/force-quit
   clears both, returns to Home, and the next Coach Live entry starts fresh.
10. Hold tracking limited for five seconds: the last census snapshot remains,
    the same AR surface becomes editable, and session/reset counters do not
    change. Compare `inferencesRun`; census processing adds zero invocations.
11. In low light, verify 30–44% boxes maintain existing identities but cannot
    create dots; ≥45% detections create candidates only after normal census
    confirmation. Pan away and return without replacement IDs.
12. Trigger recount while moving and then settle: observe waiting animation,
    progress, completion summary, and no room-outside-table inference.
13. Measure one isolated tile and manually change width/length. Confirm the HUD
    source/dimensions change and adjacent tiles remain separate.
14. Present the same face in two sharp detail passes at least 0.5 seconds apart:
    it publishes once. Confirm broad, moving, undersized, and same-pass reads do
    not advance face certainty.

These are physical-device gates, not deferred source work. Do not declare the
LiDAR release accepted from Simulator results alone.
