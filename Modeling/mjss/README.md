# mjss — YOLO26n Hong Kong mahjong (physical tiles)

Train **YOLO26n** with Ultralytics on Apple Silicon (MPS) for **Hong Kong–style** physical tile detection: **43 classes** (suits + honors + flowers/seasons + `back`).

## Setup

```bash
cd /Users/vumonks/Desktop/mjss
source .venv/bin/activate
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

### Dataset v2 (recommended)

Rebuild from all Roboflow zips (incl. romanNguyen + bing), remap to 43 HK classes, and drop exact/near-duplicate images:

```bash
python scripts/merge_hk_dataset.py --clean --out data/processed/hk_merged_v2 --dedupe
python scripts/package_ultralytics_dataset.py \
  --src data/processed/hk_merged_v2 \
  -o data/exports/mjss-hk-mahjong-yolo26-v2.zip
# → data/exports/mjss-hk-mahjong-yolo26-v2.zip
```

### Dataset v1 (previous export)

```bash
python scripts/package_ultralytics_dataset.py
# → data/exports/hk-mahjong-yolo26-43cls.zip
```

1. Open [Ultralytics Platform](https://platform.ultralytics.com/) → **Annotate** → **New Dataset** (or drag onto Datasets).
2. Upload `data/exports/mjss-hk-mahjong-yolo26-v2.zip`. Confirm **43 classes** after ingest.
3. Start cloud train: **YOLO26n**, imgsz **640**, epochs **~100**. Nano on this set should use only a small slice of ~$25 credits.
4. Download `best.pt` (and/or export Core ML) when finished.

You can stop local MPS training if you switch fully to cloud — packaging does not require stopping it.

## iOS

When training finishes, see **[docs/ios-inference.md](docs/ios-inference.md)** for Core ML export and iPhone 15+ integration (class list, preprocessing, SDK options).

## Label notes

- Canonical names: Tenhou `m/p/s/z` + `1F–4F` / `1S–4S` + `back`.
- Source remaps live in `configs/hk_tile_map.yaml` (v83 `B/C/D` → `s/m/p`, roman `bamboo/character/circle`, bing `Nbing`→`Np`, red fives → normal 5s).
- Filenames containing `screenshot` / Soul UI markers are skipped.
- `--dedupe` uses SHA-256 + pHash (Hamming ≤ 2) across sources.
- `ref/mahjong_vision` is for later product ideas (board-state / overlay), not for this detector’s classes.
