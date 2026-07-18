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

## Video for the live tracker

Coach Live (Stage C) consumes video through a Mac tool, not the app:

```
swift run --package-path Tools/detect-dump video-dump \
  --model App/Sources/Resources/Models/MahjongTileDetectorPro.mlpackage \
  --fps 10 <video.mov>
```

writes a `<video>.frames.jsonl` beside the clip. This used to be an optional add-on; it isn't
anymore. The one clip on hand, `Videos/IMG_6249.mov` (20 s, 4K portrait), turned out to be
wall-building/setup rather than gameplay — still a useful negative-control fixture (no game
events should fire while tiles are being shuffled), but it doesn't cover actual play. Real
gameplay footage is now the highest-value thing to shoot.

### Setup

- Phone on a **stand** at **your seat** — the same position Coach Live will actually use.
  No handheld: the tracker assumes a static camera.
- **Portrait**, and fill the frame with the table — your tiles along the bottom edge, the
  pond in the center, opponents' meld rows visible. Avoid wide shots with floor or
  background margin.
- Framing tightness is the lever, not resolution. A measured run of the Pro detector on
  `IMG_6249.mov` found ~98% of tile boxes under 4% of frame height, purely because the
  framing was wide/loose — capture resolution doesn't help (the detector letterboxes every
  frame to 640px regardless of source), so 4K vs 1080p vs 720p is irrelevant. Get closer
  instead of shooting wider.

### What to film, in priority order

1. **One full hand, start to finish** — deal, draws and discards around the table, at
   least one pung/chow claim, a win or exhaustive draw, tiles cleared. Even 3–5 minutes of
   real play is gold.
2. **A short clip rich in discard events** at normal pace — doesn't need to span a whole
   hand, just a steady run of draws/discards.
3. **A messy/fast variant** — tiles nudged out of place, hands reaching through the pond,
   people playing quickly.

Note ground truth for each clip right after shooting: who sat where relative to the camera,
what was claimed, who won.

### Practical

- 30 fps is plenty — the tool samples at 10 fps anyway.
- Normal indoor lighting is fine.
- Keep the phone **completely still for the whole clip** — the tracker assumes a static
  camera.
- Don't move the phone between hands; stop the clip and start a new one instead.

## What happens to the photos

`Tools/detect-dump` runs the bundled detector on each photo and writes `<name>.boxes.json`
beside it; those JSONs become permanent unit-test fixtures for `TableSceneParser`.
Everything stays local — nothing is uploaded anywhere.
