# iOS inference guide — HK mahjong tile detector

Guide for integrating the trained model on **iPhone 15 or newer** (A16 / A17 / A18 Neural Engine). Training produces a PyTorch checkpoint; for the phone you export **Core ML** (`.mlpackage`).

## What you get

| Item | Value |
|------|--------|
| Task | Object detection (bounding box + class per tile) |
| Architecture | Ultralytics **YOLO26n** (nano) |
| Classes | **43** Hong Kong–style physical tiles |
| Train input size | **640×640** |
| Checkpoint (after train) | `runs/yolo26n-hk/weights/best.pt` |
| Mobile format | Core ML **`.mlpackage`** (recommended) |

This model detects **physical mahjong tiles** in a photo/frame. It is **not** a Mahjong Soul UI model and does not suggest discards by itself.

---

## 1. Wait for training, then export on Mac

After `best.pt` exists:

```bash
cd /Users/vumonks/Desktop/mjss
source .venv/bin/activate

python - <<'PY'
from ultralytics import YOLO

model = YOLO("runs/yolo26n-hk/weights/best.pt")
# Core ML for Apple Neural Engine; INT8 weights shrink size / improve mobile latency
path = model.export(
    format="coreml",
    imgsz=640,
    nms=True,      # bake NMS into the package when possible
    int8=True,     # or: quantize=8 depending on ultralytics version
)
print("Exported:", path)
PY
```

Expected output: something like  
`runs/yolo26n-hk/weights/best.mlpackage`

Ship that folder (or a zip of it) to the iOS app target / CDN. Do **not** ship the `.pt` file to the phone.

**Device targets:** iPhone 15+ is fine (iOS 17+ recommended). Set Xcode deployment target accordingly; Core ML ML Programs work well on these chips.

---

## 2. Class list (index → label)

Class ids are **0 … 42** in this exact order. Keep the same array in Swift.

| Id | Name | Meaning |
|----|------|---------|
| 0–8 | `1m` … `9m` | Characters (萬) |
| 9–17 | `1p` … `9p` | Dots / circles (筒) |
| 18–26 | `1s` … `9s` | Bamboo (索); `1s` is often the bird |
| 27 | `1z` | East |
| 28 | `2z` | South |
| 29 | `3z` | West |
| 30 | `4z` | North |
| 31 | `5z` | White dragon |
| 32 | `6z` | Green dragon |
| 33 | `7z` | Red dragon |
| 34–37 | `1F` … `4F` | Flowers 梅蘭竹菊 |
| 38–41 | `1S` … `4S` | Seasons 春夏秋冬 |
| 42 | `back` | Face-down tile |

Canonical list also lives in [`configs/hk_tile_map.yaml`](../configs/hk_tile_map.yaml) / merged `data.yaml`.

Swift sketch:

```swift
let hkTileNames: [String] = [
  "1m","2m","3m","4m","5m","6m","7m","8m","9m",
  "1p","2p","3p","4p","5p","6p","7p","8p","9p",
  "1s","2s","3s","4s","5s","6s","7s","8s","9s",
  "1z","2z","3z","4z","5z","6z","7z",
  "1F","2F","3F","4F",
  "1S","2S","3S","4S",
  "back"
]
// label = hkTileNames[classIndex]
```

---

## 3. Input / output contract

### Input

- RGB image (camera frame or still).
- Letterbox / resize to **640×640** the same way YOLO does (preserve aspect ratio, pad), unless your Core ML export is configured for flexible size and you match Ultralytics preprocessing.
- Pixel values: follow the exported model’s preprocessor (Ultralytics Core ML export usually embeds scale/normalize). Prefer letting **Vision** (`VNCoreMLRequest`) or the **Ultralytics iOS SDK** handle preprocessing.

### Output (per detection)

Each detection is roughly:

| Field | Meaning |
|-------|---------|
| `classIndex` | `0…42` → map via `hkTileNames` |
| `confidence` | Filter with a threshold (start at **0.25–0.35**; training smoke used `0.25`) |
| `bbox` | Axis-aligned box in image coordinates (xyxy or xywh — check your decoder / SDK) |

If you exported with `nms=True`, boxes are already suppressed. If not, run NMS yourself (`iou ≈ 0.45–0.7`).

Expect **many boxes per frame** (a full table / hand can have dozens of tiles). Budget UI and NMS for **≤300** detections (YOLO default `max_det`).

---

## 4. Integration options on iPhone

### Option A — Ultralytics YOLO iOS SDK (fastest)

- Repo: [ultralytics/yolo-ios-app](https://github.com/ultralytics/yolo-ios-app)
- Loads `.mlpackage`, runs camera / still inference on the Neural Engine, returns decoded boxes + labels.
- Best if you want a known-good pipeline with minimal Core ML plumbing.

### Option B — Apple Vision + Core ML (custom app)

1. Add `best.mlpackage` to the Xcode target (Copy Bundle Resources).
2. Create `VNCoreMLModel` from `MLModel(contentsOf:)`.
3. Run `VNCoreMLRequest` on `CVPixelBuffer` from `AVCaptureSession`.
4. Map class indices with the table above; draw boxes in UIKit/SwiftUI.

Use **`.cpuAndNeuralEngine`** (or the SDK’s ANE path) for best latency on iPhone 15+.

### Option C — Flutter

Ultralytics also ships a [Flutter plugin](https://github.com/ultralytics/yolo-flutter-app) that consumes the same Core ML export.

---

## 5. Practical tips for a table camera

1. **Lighting / framing** — Model was trained on physical-tile photos. Overhead or 45° views of a real set work best; avoid game-client screenshots.
2. **Confidence** — Start `conf = 0.3`. Raise if you see duplicate false labels; lower if small/angled tiles are missed.
3. **`back` class** — Use it for face-down wall tiles; don’t treat `back` as a playable face in game logic.
4. **Flowers / seasons** — Included for HK 144-tile play; rarer in training data, so expect lower recall until the full train finishes / you add more examples.
5. **Red fives** — Not separate classes; a red-ink 5 maps to normal `5m` / `5p` / `5s` (HK rules).
6. **Orientation** — Tiles may be rotated; if recall is weak on sideways tiles, add app-side rotation TTA or more rotated training data later.
7. **Privacy** — On-device Core ML keeps frames on the phone (no upload required).

---

## 6. Suggested handoff checklist

- [ ] Training finished; `runs/yolo26n-hk/weights/best.pt` present  
- [ ] Export Core ML (`.mlpackage`) on this Mac  
- [ ] Bundle or download `.mlpackage` in the iOS app  
- [ ] Hard-code / ship the 43-name list above  
- [ ] Camera → 640 preprocess → infer → filter by confidence → map id → UI  
- [ ] Smoke test on a real HK set under table lighting on iPhone 15+  

---

## 7. Desktop sanity check (optional)

From the Python project (before or after export):

```bash
python scripts/predict.py
# writes overlays under runs/predict-hk/
```

That uses the same `best.pt` and `conf=0.25` as a reference for what “good” detections look like.

---

## References

- Class map: [`configs/hk_tile_map.yaml`](../configs/hk_tile_map.yaml)  
- Train / predict: [`scripts/train.py`](../scripts/train.py), [`scripts/predict.py`](../scripts/predict.py)  
- Ultralytics Core ML export: https://docs.ultralytics.com/integrations/coreml  
- Ultralytics iOS SDK: https://github.com/ultralytics/yolo-ios-app  
