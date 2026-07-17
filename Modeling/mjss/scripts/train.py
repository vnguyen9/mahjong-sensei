"""Train YOLO26n on the merged HK physical-tile dataset (Apple Silicon MPS)."""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[1]
DATA_YAML = ROOT / "data" / "processed" / "hk_merged" / "data.yaml"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--name", default="yolo26n-hk")
    args = parser.parse_args()

    if not DATA_YAML.exists():
        raise SystemExit(
            f"Missing {DATA_YAML}. Run: python scripts/merge_hk_dataset.py"
        )

    model = YOLO("yolo26n.pt")  # nano — downloads weights on first run
    model.train(
        data=str(DATA_YAML),
        epochs=args.epochs,
        imgsz=640,
        batch=args.batch,  # lower if you hit memory pressure
        device=args.device,  # Apple Metal; use "cpu" to fall back
        project=str(ROOT / "runs"),
        name=args.name,
        exist_ok=True,
        workers=4,
        patience=30,
    )


if __name__ == "__main__":
    main()
