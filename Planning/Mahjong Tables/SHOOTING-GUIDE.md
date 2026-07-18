# Table-Photo Shooting Guide

These photos tune and validate the **table auto-zoner** (Stage A): the code that looks at one
frame and decides *these tiles are mine, those are the table's*. The detector already reads
tile faces — what it needs from these photos is realistic **geometry**: real perspective, real
tile sizes at each depth, real pond mess.

## The two hard requirements

1. **Chinese/HK set** — the same tiles the app scans today. No racks, no jokers (American
   sets aren't in the detector's 43 classes, and racks hide the tiles anyway).
2. **Full resolution** — shoot with the normal Camera app and AirDrop/Files the **original
   HEIC/JPG** here. No screenshots, no WhatsApp/Messenger re-compression, no cropping.
   (The model sees a 640px letterboxed frame; web thumbnails leave each tile ~15px — too small.)

## How to shoot

- Sit in **your seat**. Hold the phone where you'd naturally hold it — chest/eye height,
  tilted down. Your tiles along the bottom edge, far side of the table at the top,
  whole table in frame.
- Mostly **landscape**; add a couple of portrait shots too.
- A **staged game is perfect** — deal out a fake mid-game. Nobody needs to be playing.

## Layouts to stage (5–10 photos total)

| # | Scene | Why |
|---|---|---|
| 1 | Early: 13-tile hand, 4–6 discards in the pond | The common case |
| 2 | Mid: ~15–20 discards, one exposed pung for you, one for an opponent | The meld carve-out |
| 3 | Late: 28+ discards, two melds out | Dense pond |
| 4 | Messy pond — tiles scattered, not neat rows | Robustness |
| 5 | Dim / lamp lighting | Detector stress |
| 6 | 14-tile hand (just drew) | The decision moment |

## Ground truth (one line per photo)

Add a `notes.md` in `fixtures/` — one line each, e.g.:

```
table-02-mid.heic — bottom row = my 13, group right of it = my East pung,
center = pond (~18), top-left = opponent's 7筒 pung
```

Exact pond contents for one or two photos is a bonus, not a requirement.

## Optional (for Stage C, the live tracker)

One or two **30–60 s videos** from your seat of a few turns actually being played — a few
discards, ideally a meld call. Used to tune tracking offline before any live testing.

## What happens to the photos

`Tools/detect-dump` runs the bundled detector on each photo and writes `<name>.boxes.json`
beside it; those JSONs become permanent unit-test fixtures for `TableSceneParser`.
Everything stays local — nothing is uploaded anywhere.
