# mjss — YOLO26n Hong Kong mahjong (physical tiles)

Train **YOLO26n** with Ultralytics on Apple Silicon (MPS) for **Hong Kong–style** physical tile detection: **43 classes** (suits + honors + flowers/seasons + `back`).

Tracker V2 uses the bundled one-class locator plus a separate two-head
MobileNetV3-Small classifier. The classifier predicts the same 43 faces and a
crop-validity probability; “unknown” is derived from calibrated rejection gates.

## Setup

```bash
cd /Users/vumonks/Desktop/mjss
source .venv/bin/activate
cd "Image Recognition"
# pip install -r requirements.txt   # if recreating the venv
```

In Cursor/VS Code, select kernel **Python (mjss)**.

## Layout

```
configs/hk_tile_map.yaml       # canonical 43 classes + source remaps
configs/data.yaml              # Ultralytics pointer to merged set
data/raw/*.yolo26.zip          # Roboflow exports (gitignored)
data/processed/hk_merged/      # merged YOLO dataset v1 (gitignored)
data/processed/hk_merged_v2/   # v2 merge + dedupe (gitignored)
data/processed/hk_merged_v3/   # v3 merge + dedupe (+ v3i/v4i) (gitignored)
data/exports/*.zip             # Platform upload package (gitignored)
scripts/merge_hk_dataset.py    # extract + remap + merge (+ optional --dedupe)
scripts/package_ultralytics_dataset.py  # ZIP for Ultralytics Platform
scripts/train.py               # YOLO26n train (device=mps)
scripts/predict.py             # sample inference on val
dataprep.ipynb                 # inspect / QA
ref/mahjong_vision/            # reference only (Soul ViT assistant — not train data)
```

## Workflow

1. Place YOLO26 zip exports in `data/raw/` (already done if you followed the plan).
2. Build the merged HK dataset:

```bash
source .venv/bin/activate
python scripts/merge_hk_dataset.py --clean
```

3. Train locally (default **100** epochs on MPS) **or** upload to Ultralytics Platform (below):

```bash
python scripts/train.py
# shorter smoke run: python scripts/train.py --epochs 5
```

Weights land in `runs/yolo26n-hk/weights/best.pt`.

4. Quick predict check:

```bash
python scripts/predict.py
```

A 5-epoch smoke train already reached ~**0.575 mAP50** on val (flowers/`back` still weak — need the full 100-epoch run and more bonus-tile examples).

## Ultralytics Platform (cloud train)

### Dataset v3 + F/S synthetics (recommended for training)

v3 merge, then synthetics-only flower/season rebalance (copy-paste crops onto real table scenes; val/test unchanged):

```bash
cd "Image Recognition"
python scripts/merge_hk_dataset.py --clean --out data/processed/hk_merged_v3 --dedupe
python scripts/build_fs_crop_bank.py --clean
python scripts/synth_fs_copy_paste.py --clean
python scripts/package_ultralytics_dataset.py \
  --src data/processed/hk_merged_v3_fsbal \
  -o data/exports/mjss-hk-mahjong-yolo26-v3-fsbal.zip
python scripts/train.py   # defaults to fsbal, copy_paste=0.4, cls=0.75
# Per-class F/S AP: python scripts/compare_fs_ap.py --weights runs/yolo26n-hk-fsbal/weights/best.pt
```

### Dataset v3 (merge only)

```bash
python scripts/merge_hk_dataset.py --clean --out data/processed/hk_merged_v3 --dedupe
python scripts/package_ultralytics_dataset.py \
  --src data/processed/hk_merged_v3 \
  -o data/exports/mjss-hk-mahjong-yolo26-v3.zip
```

### Dataset v2 (previous)

```bash
python scripts/merge_hk_dataset.py --clean --out data/processed/hk_merged_v2 --dedupe
python scripts/package_ultralytics_dataset.py \
  --src data/processed/hk_merged_v2 \
  -o data/exports/mjss-hk-mahjong-yolo26-v2.zip
```

### Dataset v1 (previous export)

```bash
python scripts/package_ultralytics_dataset.py
# → data/exports/hk-mahjong-yolo26-43cls.zip
```

1. Open [Ultralytics Platform](https://platform.ultralytics.com/) → **Annotate** → **New Dataset** (or drag onto Datasets).
2. Upload `data/exports/mjss-hk-mahjong-yolo26-v3.zip`. Confirm **43 classes** after ingest.
3. Start cloud train: **YOLO26n**, imgsz **640**, epochs **~100**. Nano on this set should use only a small slice of ~$25 credits.
4. Download `best.pt` (and/or export Core ML) when finished.

You can stop local MPS training if you switch fully to cloud — packaging does not require stopping it.

## iOS

When training finishes, see **[docs/ios-inference.md](docs/ios-inference.md)** for Core ML export and iPhone 15+ integration (class list, preprocessing, SDK options).

### Tracker V2 face classifier

Build source-grouped crops (12% context, locator jitter, partial/background
invalids, and optional locator-mined hard negatives), train, calibrate, and
export:

```bash
python scripts/build_tile_classifier_dataset.py --clean \
  --locator runs/tile-locator-v3/weights/best.pt
python scripts/train_tile_classifier.py --epochs 45 --device mps
python scripts/export_tile_classifier_coreml.py \
  --install-resources ../../../App/Sources/Resources/Models
```

The crop builder assigns source images—not individual crops—to splits and does
not horizontally mirror glyphs. Do not enable `trackerPipelineV2` by default
until held-out table-scene gates, invalid-crop false acceptance, calibration,
edit-reduction, and iPhone 15 latency gates all pass. During development, add
`-trackerPipelineV2 YES` to the scheme launch arguments.

## Label notes

- Canonical names: Tenhou `m/p/s/z` + `1F–4F` / `1S–4S` + `back`.
- Source remaps live in `configs/hk_tile_map.yaml` (v83 `B/C/D` → `s/m/p`, bing `Nbing`→`Np`, v3i stick/character/honors, v4i bamboo/character/dot + flowers, red fives → normal 5s). romanNguyen is excluded from the merge.
- Filenames containing `screenshot` / Soul UI markers are skipped.
- `--dedupe` uses SHA-256 + pHash (Hamming ≤ 2) across sources.
- `ref/mahjong_vision` is for later product ideas (board-state / overlay), not for this detector’s classes.
