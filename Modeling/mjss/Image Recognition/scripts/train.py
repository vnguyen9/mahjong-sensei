"""Train YOLO26n on the merged HK physical-tile dataset (Apple Silicon MPS)."""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA = ROOT / "data" / "processed" / "hk_merged_v3_fsbal" / "data.yaml"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data",
        type=Path,
        default=DEFAULT_DATA,
        help="Dataset data.yaml (default: hk_merged_v3_fsbal)",
    )
    parser.add_argument("--weights", default="yolo26n.pt")
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--name", default="yolo26n-hk-fsbal")
    parser.add_argument(
        "--copy-paste",
        type=float,
        default=0.4,
        help="Online copy-paste probability (Ultralytics)",
    )
    parser.add_argument(
        "--cls",
        type=float,
        default=0.75,
        help="Classification loss gain (raise for rare classes)",
    )
    args = parser.parse_args()

    data = args.data if args.data.is_absolute() else ROOT / args.data
    if not data.exists():
        raise SystemExit(
            f"Missing {data}. Build with:\n"
            "  python scripts/build_fs_crop_bank.py --clean\n"
            "  python scripts/synth_fs_copy_paste.py --clean"
        )

    model = YOLO(args.weights)
    model.train(
        data=str(data.resolve()),
        epochs=args.epochs,
        imgsz=640,
        batch=args.batch,
        device=args.device,
        project=str(ROOT / "runs"),
        name=args.name,
        exist_ok=True,
        workers=4,
        patience=30,
        copy_paste=args.copy_paste,
        cls=args.cls,
    )


if __name__ == "__main__":
    main()
