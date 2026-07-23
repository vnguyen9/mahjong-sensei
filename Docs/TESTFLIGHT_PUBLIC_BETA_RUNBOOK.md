# Mahjong Sensei public TestFlight beta runbook

Last reviewed: July 21, 2026

Owner: Vu Nguyen
App bundle ID: `com.lumiodatalabs.MahjongSensei`
Current app version in source: `0.1.0`

This is the end-to-end checklist for moving from a working local build to a
controlled external TestFlight beta. TestFlight is public distribution even
when the public link is shared with only a small group, so legal, privacy, and
signing gates apply.

## Stop-ship gates

Do not enable an external group until every item below has an owner and a
recorded decision.

- [ ] Xcode Cloud App Store Connect archive/export succeeds.
- [ ] The build installs and launches on a physical iPhone and iPad.
- [ ] Camera permission, denial, and later re-enabling in Settings work.
- [ ] Tracker, Score/hand scan, What’s This?, Coach Live, persistence, reset,
      and diagnostic sharing have completed a smoke test.
- [ ] No captured tile image is uploaded automatically; diagnostics containing
      photos are shared only after an explicit user action.
- [ ] A public privacy-policy URL exists and accurately describes on-device
      image processing and explicit diagnostic sharing.
- [ ] App Privacy answers include the behavior of every third-party SDK.
- [ ] Export-compliance questions have been answered accurately.
- [ ] The Mahjong model, training data, fonts, icons, and tile artwork are
      cleared for external distribution.
- [ ] **Ultralytics/model licensing is resolved in writing.** Repository
      planning notes identify an AGPL/commercial-license risk for the detector
      pipeline. A public TestFlight beta is not the place to defer this. Record
      the commercial license, counsel-approved compliance path, or replacement
      model before inviting external testers.
- [ ] TestFlight contact information and feedback inbox are monitored.
- [ ] A rollback owner can expire a bad build promptly.

## Phase 1 — Prepare the release candidate

### 1. Freeze scope

1. Choose the exact commit for the beta.
2. Stop merging feature work into that candidate until the smoke test passes.
3. Update `MARKETING_VERSION` when the tester-visible version changes.
4. Ensure every upload has a unique `CURRENT_PROJECT_VERSION`/build string.
   Xcode’s App Store Connect distribution preparation can manage this.
5. Add concise release notes and known issues to the release record.

Recommended beta policy:

- Version: keep `0.1.0` during the first cohort.
- Build: monotonically increase for every successfully uploaded candidate.
- Cohort: 10–20 trusted testers first; expand only after 48 hours without a
  crash/data-loss blocker.

### 2. Run automated checks

At minimum:

```sh
xcodebuild \
  -project MahjongSensei.xcodeproj \
  -scheme MahjongSensei \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  test
```

Also produce the unsigned Release archive described in
`XCODE_CLOUD_SIGNING_RECOVERY.md`. Use the same Xcode version selected by the
Cloud workflow whenever possible.

### 3. Run a physical-device smoke test

Use at least:

- One supported iPhone with a 1× camera.
- One supported iPad.
- If available, a device with both 0.5× and 1× cameras.
- A clean install and an upgrade from the previous TestFlight build.

Test matrix:

| Area | Required check |
| --- | --- |
| First launch | Permission copy is clear; denying camera does not trap or crash the app. |
| Tracker live view | Boxes align with tiles; only tiles inside the guide enter the scan; confidence/IoU developer controls remain Debug-only. |
| Tracker review | Crops and suggestions are editable; Apply is atomic; Cancel/Rescan do not change saved counts. |
| Player hand | Scan and manual edit both work; hand survives intended navigation and count conservation is understandable. |
| Score | Camera guidance, detection overlays, hand review, and scoring flow work in portrait and supported iPad orientations. |
| Coach Live | Starts, tracks, pauses, resumes, and exits without thermal runaway or a stuck camera. |
| Persistence | Force quit/relaunch preserves counts and hand, but transient camera/drawer presentation resets as designed. |
| Accessibility | VoiceOver order, 44-point targets, Dynamic Type, Reduce Motion, and non-color marker states are usable. |
| Diagnostics | Copy JSON contains no photos or paths. Share Diagnostics clearly discloses photos and creates files only after explicit action. |
| Failure recovery | Low light, motion, no detections, model failure, and camera interruption never erase existing counts. |

## Phase 2 — Configure Xcode Cloud for an external-capable build

The current screenshot shows an internal-only workflow. Follow
`XCODE_CLOUD_SIGNING_RECOVERY.md`, then configure the candidate workflow:

1. App Store Connect → Mahjong Sensei → Xcode Cloud.
2. Duplicate the internal workflow or create `TestFlight External Candidate`.
3. Repository: `vnguyen9/mahjong-sensei`.
4. Project: `MahjongSensei.xcodeproj`.
5. Branch: `main`, or preferably a dedicated release branch/tag condition.
6. Environment: pin a known-good Xcode release for the beta cycle rather than
   allowing an unexpected “Latest Release” update mid-cycle.
7. Enable **Clean** for the distribution candidate.
8. Archive — iOS:
   - Scheme: `MahjongSensei`
   - Distribution Preparation: **App Store Connect**
9. Do not use **TestFlight (Internal Testing Only)** for public/external beta.
10. Initially omit automatic TestFlight post-actions. Prove upload and manual
    cohort assignment first.
11. Run the workflow manually from the frozen candidate.
12. Download and retain archive/log artifacts with the release record.

After the build is green, wait for App Store Connect processing. Inspect all
warnings before assigning it to testers.

## Phase 3 — Complete App Store Connect metadata

### App information

Verify:

- Name: Mahjong Sensei.
- Bundle ID: `com.lumiodatalabs.MahjongSensei`.
- Primary language and category.
- Support URL.
- Privacy-policy URL.
- Age-rating questionnaire.
- Content-rights answers.

### Privacy

In App Store Connect → App Privacy:

1. Publish a real, publicly accessible privacy policy.
2. Audit code and third-party dependencies before selecting “Data Not
   Collected.” On-device processing is not developer collection, but any crash
   SDK, analytics, network service, feedback backend, or received diagnostic
   package can change the answer.
3. Explain that camera images are processed on-device and are not uploaded
   automatically.
4. Explain that Developer Diagnostics may include captured table photos only
   when the user explicitly uses the system share action.
5. Revisit the answers whenever telemetry or cloud inference is added.

### Export compliance

Answer App Store Connect’s encryption questionnaire based on the shipped
binary. If Apple determines that no documentation is required, add the
corresponding Info.plist declaration in the project so the answer need not be
repeated. Do not set the exemption flag merely to silence the prompt.

### TestFlight test information

Under TestFlight → Test Information, provide:

- Beta app description.
- Feedback email.
- Contact first/last name, phone, and email for Beta App Review.
- Review notes, including that tile recognition is on-device and camera access
  is required.
- Any credentials or exact navigation instructions needed by the reviewer.

Suggested beta description:

> Mahjong Sensei helps Hong Kong mahjong players read a table, track visible
> tiles, enter a hand, and explore scoring and live coaching. Recognition runs
> on the device. This beta focuses on camera accuracy, evidence review, and a
> clear, fast table-side workflow.

Suggested **What to Test** text:

> Point the camera directly above a well-lit mahjong table. Try Tracker on
> scattered discards and exposed melds, review any uncertain tile suggestions,
> and apply the result. Then scan or edit your hand and verify that counts stay
> consistent after relaunching the app. Please also try Score and Coach Live.
> Report missed/incorrect tiles, misaligned boxes, slow or hot devices,
> accessibility issues, crashes, and any moment where the next action is
> unclear. Include your device model and iOS/iPadOS version. Share diagnostic
> photos only when you are comfortable including the pictured table area.

Suggested review note:

> Camera access is essential. All model inference is performed on-device. No
> account or login is required. In Tracker, frame visible face-up table tiles,
> tap Scan Table, review detections, then Apply Counts. Player-hand entry is
> available in the Tracker drawer and Score mode. Developer-only diagnostics
> are not present in the Release build.

## Phase 4 — Internal dogfood before external review

Apple requires an internal group before an external group.

1. Create or retain an internal group named `Internal Testers`.
2. Add the App Store Connect-distributed build.
3. Install it from TestFlight—not from Xcode—on iPhone and iPad.
4. Verify the correct version/build appears in Settings/TestFlight.
5. Run the smoke test again against the distributed binary.
6. Observe crashes, hangs, launch failures, feedback, and battery/thermal
   behavior for at least one meaningful session.

Do not confuse this with an **Internal Only** build. A full App Store Connect
build can be tested internally and later externally; an Internal Only build can
never move to external testing.

## Phase 5 — External group and Beta App Review

1. App Store Connect → TestFlight → External Testing → `+`.
2. Create a group such as `Public Beta — Cohort 1`.
3. Add one release-candidate build.
4. Paste and proofread **What to Test**.
5. Complete any Missing Compliance item.
6. Submit the build to TestFlight App Review.
7. Do not enable automatic notification until you are ready for the cohort to
   receive the build immediately after approval.
8. After approval, invite the first cohort by email.
9. Use a public link only after the invite-only cohort is stable.

Apple supports up to 10,000 external testers, but that is a ceiling, not a
launch target. Use staged limits:

- Cohort 1: 10–20 known players across iPhone/iPad.
- Cohort 2: 50–100 players after blocker triage.
- Public link: cap the tester count initially and add device/OS criteria where
  useful.

## Phase 6 — Operate the beta

### Feedback form

Ask for:

- Build number.
- Device and OS version.
- Feature: Tracker, Hand, Score, What’s This?, or Coach Live.
- Lighting and camera lens (0.5×/1×) for recognition issues.
- Expected tile and detected/suggested tile.
- Whether correction was possible.
- Reproduction steps.
- Screenshot or diagnostics only with explicit consent.

Never ask testers to photograph people, private documents, or unrelated room
content for debugging.

### Severity

| Level | Examples | Action |
| --- | --- | --- |
| P0 | Data loss, privacy exposure, unsafe diagnostic upload, widespread launch crash | Expire build immediately; notify testers; prepare fixed build. |
| P1 | Apply corrupts counts, camera unusable on a supported device, repeatable crash in core flow | Stop cohort expansion; fix next candidate. |
| P2 | Recognition misses/corrections, layout issue, performance degradation | Triage with device/scene diagnostics; prioritize by frequency. |
| P3 | Copy, polish, minor accessibility issue with workaround | Backlog with screenshots and acceptance criteria. |

### Release cadence

- Do not ship daily builds merely because CI is green.
- Batch fixes into a testable candidate with clear What to Test notes.
- Keep one known-good build active until its replacement is proven.
- TestFlight builds expire after 90 days; plan refreshes before expiry.
- Explicitly expire a bad build in App Store Connect.

## Go/no-go checklist for each cohort expansion

- [ ] Correct App Store Connect build selected.
- [ ] No internal-only indicator.
- [ ] Beta App Review approved.
- [ ] Export compliance complete.
- [ ] Known issues are written in tester-facing language.
- [ ] Crash-free launch and core flow on iPhone and iPad.
- [ ] No P0/P1 issue open.
- [ ] Feedback inbox and TestFlight feedback checked daily.
- [ ] Support/privacy links work without authentication.
- [ ] Model/content licensing gate remains satisfied.
- [ ] Rollback owner is available.

## After the beta

1. Export and summarize crashes, sessions, and feedback without retaining more
   personal data than needed.
2. Measure recognition success by correction rate, not just detector
   confidence.
3. Separate issues by model error, camera/lighting, geometry, conservation, and
   UX confusion.
4. Publish a tester update describing what changed.
5. Expire obsolete/bad builds.
6. Before App Store launch, repeat the legal/privacy/accessibility review and
   complete the full App Review product-page metadata.

## Apple references

- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
- [Provide test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/)
