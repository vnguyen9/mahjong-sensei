"""Build source-grouped 192px tile-classifier crops from merged YOLO data.

Positive crops retain 12% context. Each source image is assigned to exactly one
split by content hash, preventing nearly-identical crops from leaking across
train/validation/test. Invalid examples include background, partial tiles, and
optional one-class-locator false positives.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import random
import shutil
from dataclasses import dataclass
from pathlib import Path

from PIL import Image
import yaml

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "data" / "processed" / "hk_merged_v3_fsbal"
DEFAULT_OUTPUT = ROOT / "data" / "processed" / "tile_classifier_v1"


@dataclass(frozen=True)
class Box:
    x1: float
    y1: float
    x2: float
    y2: float

    @property
    def area(self) -> float:
        return max(0.0, self.x2 - self.x1) * max(0.0, self.y2 - self.y1)


def iou(a: Box, b: Box) -> float:
    intersection = max(0.0, min(a.x2, b.x2) - max(a.x1, b.x1)) * max(
        0.0, min(a.y2, b.y2) - max(a.y1, b.y1)
    )
    union = a.area + b.area - intersection
    return intersection / union if union else 0.0


def split_for(digest: str) -> str:
    bucket = int(digest[:8], 16) % 100
    return "train" if bucket < 80 else "val" if bucket < 90 else "test"


def expanded(box: Box, context: float, jitter: tuple[float, float, float] = (0, 0, 1)) -> Box:
    width, height = box.x2 - box.x1, box.y2 - box.y1
    dx, dy, scale = jitter
    cx = (box.x1 + box.x2) / 2 + dx * width
    cy = (box.y1 + box.y2) / 2 + dy * height
    width *= scale * (1 + 2 * context)
    height *= scale * (1 + 2 * context)
    return Box(max(0, cx - width / 2), max(0, cy - height / 2),
               min(1, cx + width / 2), min(1, cy + height / 2))


def crop(image: Image.Image, box: Box) -> Image.Image:
    width, height = image.size
    pixels = (round(box.x1 * width), round(box.y1 * height),
              round(box.x2 * width), round(box.y2 * height))
    return image.crop(pixels).convert("RGB")


def read_labels(path: Path) -> list[tuple[int, Box]]:
    values: list[tuple[int, Box]] = []
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        class_id, cx, cy, width, height = map(float, parts[:5])
        values.append((int(class_id), Box(cx - width / 2, cy - height / 2,
                                          cx + width / 2, cy + height / 2)))
    return values


def save_sample(writer: csv.writer, output: Path, split: str, source_id: str,
                serial: int, image: Image.Image, face: int, valid: int,
                kind: str) -> None:
    relative = Path("crops") / split / f"{source_id[:12]}-{serial:03d}-{kind}.jpg"
    destination = output / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, quality=94, optimize=True)
    writer.writerow([relative.as_posix(), face, valid, split, source_id, kind])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--locator", type=Path,
                        help="Optional Ultralytics one-class locator weights for hard negatives")
    parser.add_argument("--clean", action="store_true")
    args = parser.parse_args()
    source = args.source if args.source.is_absolute() else ROOT / args.source
    output = args.output if args.output.is_absolute() else ROOT / args.output
    if args.clean and output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)

    config = yaml.safe_load((source / "data.yaml").read_text())
    names = list(config["names"])
    if len(names) != 43 or names[-1] != "back":
        raise SystemExit("Expected the canonical 43-class label order ending in 'back'")
    (output / "labels.yaml").write_text(yaml.safe_dump({"names": names}, sort_keys=False))

    detector = None
    if args.locator:
        from ultralytics import YOLO
        detector = YOLO(str(args.locator))

    image_paths = sorted({path for split in ("train", "val", "test")
                          for path in (source / split / "images").glob("*.*")})
    seen_sources: set[str] = set()
    manifest = output / "manifest.csv"
    with manifest.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["path", "face_index", "valid", "split", "source_id", "kind"])
        for image_path in image_paths:
            digest = hashlib.sha256(image_path.read_bytes()).hexdigest()
            if digest in seen_sources:
                continue
            seen_sources.add(digest)
            split = split_for(digest)
            label_path = image_path.parent.parent / "labels" / f"{image_path.stem}.txt"
            annotations = read_labels(label_path)
            if not annotations:
                continue
            image = Image.open(image_path).convert("RGB")
            rng = random.Random(int(digest[:16], 16))
            serial = 0
            for class_id, box in annotations:
                save_sample(writer, output, split, digest, serial,
                            crop(image, expanded(box, 0.12)), class_id, 1, "positive")
                serial += 1
                for _ in range(2):
                    jitter = (rng.uniform(-0.09, 0.09), rng.uniform(-0.09, 0.09),
                              rng.uniform(0.90, 1.12))
                    save_sample(writer, output, split, digest, serial,
                                crop(image, expanded(box, 0.12, jitter)), class_id, 1, "jitter")
                    serial += 1
                # Deliberately lop off a face edge: validity learns to reject it,
                # while face loss ignores invalid crops.
                partial = Box(box.x1, box.y1, box.x1 + (box.x2 - box.x1) * 0.58, box.y2)
                save_sample(writer, output, split, digest, serial,
                            crop(image, expanded(partial, 0.03)), -1, 0, "partial")
                serial += 1

            for _ in range(max(2, len(annotations) // 3)):
                for _attempt in range(40):
                    width, height = rng.uniform(0.05, 0.16), rng.uniform(0.08, 0.24)
                    x, y = rng.uniform(0, 1 - width), rng.uniform(0, 1 - height)
                    candidate = Box(x, y, x + width, y + height)
                    if all(iou(candidate, annotated) < 0.03 for _, annotated in annotations):
                        save_sample(writer, output, split, digest, serial,
                                    crop(image, candidate), -1, 0, "background")
                        serial += 1
                        break

            if detector is not None:
                prediction = detector.predict(image, verbose=False, conf=0.20)[0]
                width, height = image.size
                for coordinates in prediction.boxes.xyxy.cpu().tolist():
                    candidate = Box(coordinates[0] / width, coordinates[1] / height,
                                    coordinates[2] / width, coordinates[3] / height)
                    if all(iou(candidate, annotated) < 0.10 for _, annotated in annotations):
                        save_sample(writer, output, split, digest, serial,
                                    crop(image, expanded(candidate, 0.12)), -1, 0, "hard-negative")
                        serial += 1
    print(f"Wrote source-grouped classifier data to {output}")


if __name__ == "__main__":
    main()
