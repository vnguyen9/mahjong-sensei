"""Validate a checkpoint and print flower/season per-class AP vs overall."""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[1]
FS_NAMES = ("1F", "2F", "3F", "4F", "1S", "2S", "3S", "4S")
DEFAULT_DATA = ROOT / "data" / "processed" / "hk_merged_v3_fsbal" / "data.yaml"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--weights",
        type=Path,
        required=True,
        help="Path to .pt weights",
    )
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--split", default="val")
    args = parser.parse_args()

    weights = args.weights if args.weights.is_absolute() else ROOT / args.weights
    data = args.data if args.data.is_absolute() else ROOT / args.data
    if not weights.exists():
        raise SystemExit(f"Missing weights: {weights}")
    if not data.exists():
        raise SystemExit(f"Missing data yaml: {data}")

    model = YOLO(str(weights))
    metrics = model.val(
        data=str(data.resolve()),
        split=args.split,
        imgsz=args.imgsz,
        device=args.device,
        plots=False,
    )
    names = metrics.names
    # maps class index -> name
    if isinstance(names, dict):
        idx_to_name = {int(k): v for k, v in names.items()}
    else:
        idx_to_name = {i: n for i, n in enumerate(names)}

    ap50 = metrics.box.ap50  # per-class
    ap = metrics.box.ap
    print(f"\nweights={weights}")
    print(f"data={data} split={args.split}")
    print(f"overall mAP50={metrics.box.map50:.4f} mAP50-95={metrics.box.map:.4f}")
    print(f"{'class':4s}  {'AP50':>8s}  {'AP50-95':>8s}")
    fs_ap50 = []
    for i, ap50_i in enumerate(ap50):
        name = idx_to_name.get(i, str(i))
        if name not in FS_NAMES:
            continue
        ap_i = float(ap[i]) if i < len(ap) else float("nan")
        fs_ap50.append(float(ap50_i))
        print(f"{name:4s}  {float(ap50_i):8.4f}  {ap_i:8.4f}")
    if fs_ap50:
        print(f"F/S mean AP50={sum(fs_ap50)/len(fs_ap50):.4f}")


if __name__ == "__main__":
    main()
