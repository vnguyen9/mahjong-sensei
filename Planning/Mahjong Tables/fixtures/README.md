# Zoner fixtures — detector output on real photos

Each photo here is run through `Tools/detect-dump` (the production `VisionRecognizer`:
same 640-letterbox inversion, threshold 0.30, IoU-0.55 suppression) producing
`<name>.boxes.json`. Those JSONs are copied into
`Packages/Recognition/Tests/RecognitionTests/Fixtures/` and asserted against
hand-labeled zones in `TableSceneParserTests`.

Regenerate after adding photos (from the repo root):

```
swift run --package-path Tools/detect-dump detect-dump \
    --model App/Sources/Resources/Models/MahjongTileDetector.mlpackage \
    "Planning/Mahjong Tables/fixtures/"*.webp "Planning/Mahjong Tables/fixtures/"*.heic
```

## Results so far

### `aotomo-mahjong-table.webp` (2107×1580, player's seat, early game)
- **Nano: 13 detections** — the full concealed rank, one clean slightly-tilted
  line (12 of 13 at ≥ 0.92; one 7p at 0.49). Zoner: all 13 → `mine`, confidence 1.0. ✅
  (`.boxes.json` here is the nano output — matches the frozen zoner test fixture.)
- **Large (Pro): 14 detections** — the same rank (and it resolves that ambiguous
  4th tile as 5p@0.86, not 7p@0.49) **plus the rotated 北 discard the nano never
  sees** (N@0.83, center). So rotation recall is a *model-capacity* gap, not an
  architectural blind spot — the bigger model already recovers it. The three tiny
  far tiles still don't fire at this resolution.
- Implication: full-res pond recall is still the #1 question for the user's photos,
  but a rotation-augmented retrain (Stage E) is looking less necessary now that the
  large model reads rotated tiles.

### `../reference/images-5.jpeg` (612×408 thumbnail, corner shot of a real game)
- **29 detections** despite the tiny size — geometry usable, faces noisy
  (several 0.3-ish misreads). Promoted to a *geometry-only* fixture.
- Zoner: 10-tile diagonal rank → `mine`, the E-E-E group beside it → `myMelds`,
  15 pond tiles → `table`, one lone mid-table season → `unresolved`,
  confidence 0.75. ✅ (This photo is what proved rows must be found along the
  principal axis, not by y-banding — the rank is ~25° diagonal in image space.)

### `../reference/mahjong-2.webp` (730×973, standing shot, no discards)
- 10 detections — the near player's face-up rank only. Valid but adds nothing
  over aotomo; not promoted.

### `../reference/images-2.jpeg` (500×305 staged studio scene)
- 16 detections — the front display row only; the scattered center pile
  (rotated, overlapping) produced **zero** detections. Reinforces the rotation
  blindness note. Not promoted.

## What new photos should add (see ../SHOOTING-GUIDE.md)

Full-res player's-seat shots with: a real pond at several densities, exposed
melds (mine + an opponent's), messy ponds, dim light. Priority question:
**how many pond tiles does the detector actually fire on at full resolution?**
