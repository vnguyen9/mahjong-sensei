"""Quick inference / sanity check after training."""

from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[1]
VALID_IMAGES = ROOT / "data" / "processed" / "hk_merged" / "val" / "images"
WEIGHTS = ROOT / "runs" / "yolo26n-hk" / "weights" / "best.pt"


def main() -> None:
    weights = WEIGHTS if WEIGHTS.exists() else Path("yolo26n.pt")
    source = VALID_IMAGES if VALID_IMAGES.exists() else ROOT / "data" / "processed" / "hk_merged"

    model = YOLO(str(weights))
    # Sample a handful of val images for a quick sanity check
    images = sorted(VALID_IMAGES.glob("*"))[:24] if VALID_IMAGES.exists() else []
    pred_source = [str(p) for p in images] if images else str(source)

    results = model.predict(
        source=pred_source,
        device="mps",
        save=True,
        project=str(ROOT / "runs"),
        name="predict-hk",
        exist_ok=True,
        conf=0.25,
    )
    print(f"Wrote {len(results)} prediction(s) under runs/predict-hk/")


if __name__ == "__main__":
    main()
