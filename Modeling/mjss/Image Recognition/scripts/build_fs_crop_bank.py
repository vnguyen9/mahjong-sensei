"""Extract flower/season (1F–4F, 1S–4S) instance crops from hk_merged_v3 train."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import yaml
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SRC = ROOT / "data" / "processed" / "hk_merged_v3"
DEFAULT_OUT = ROOT / "data" / "processed" / "fs_crop_bank"
FS_NAMES = ("1F", "2F", "3F", "4F", "1S", "2S", "3S", "4S")
IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".bmp")


def find_image(img_dir: Path, stem: str) -> Path | None:
    for ext in IMAGE_EXTS:
        p = img_dir / f"{stem}{ext}"
        if p.exists():
            return p
    matches = [p for p in img_dir.iterdir() if p.stem == stem and p.suffix.lower() in IMAGE_EXTS]
    return matches[0] if matches else None


def yolo_to_xyxy(cx: float, cy: float, w: float, h: float, W: int, H: int) -> tuple[int, int, int, int]:
    x1 = int(round((cx - w / 2) * W))
    y1 = int(round((cy - h / 2) * H))
    x2 = int(round((cx + w / 2) * W))
    y2 = int(round((cy + h / 2) * H))
    x1 = max(0, min(W - 1, x1))
    y1 = max(0, min(H - 1, y1))
    x2 = max(x1 + 1, min(W, x2))
    y2 = max(y1 + 1, min(H, y2))
    return x1, y1, x2, y2


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", type=Path, default=DEFAULT_SRC)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--min-side", type=int, default=28, help="Skip crops smaller than this")
    parser.add_argument("--pad", type=float, default=0.04, help="Fractional pad around box")
    parser.add_argument("--clean", action="store_true")
    args = parser.parse_args()

    src = args.src if args.src.is_absolute() else ROOT / args.src
    out = args.out if args.out.is_absolute() else ROOT / args.out
    cfg = yaml.safe_load((src / "data.yaml").read_text(encoding="utf-8"))
    names: list[str] = list(cfg["names"])
    fs_ids = {names.index(n) for n in FS_NAMES if n in names}
    if len(fs_ids) != 8:
        raise SystemExit(f"Expected 8 F/S classes in {src / 'data.yaml'}, found {fs_ids}")

    if args.clean and out.exists():
        import shutil

        shutil.rmtree(out)
    for n in FS_NAMES:
        (out / n).mkdir(parents=True, exist_ok=True)

    lbl_dir = src / "train" / "labels"
    img_dir = src / "train" / "images"
    meta: list[dict] = []
    kept = 0
    skipped_small = 0
    skipped_missing = 0

    for lbl in sorted(lbl_dir.glob("*.txt")):
        img_path = find_image(img_dir, lbl.stem)
        if img_path is None:
            skipped_missing += 1
            continue
        with Image.open(img_path) as im:
            im = im.convert("RGB")
            W, H = im.size
            for i, line in enumerate(lbl.read_text(encoding="utf-8", errors="ignore").splitlines()):
                parts = line.split()
                if len(parts) < 5:
                    continue
                cid = int(float(parts[0]))
                if cid not in fs_ids:
                    continue
                cx, cy, bw, bh = map(float, parts[1:5])
                # pad in normalized space then clamp via xyxy helper
                pw, ph = bw * args.pad, bh * args.pad
                x1, y1, x2, y2 = yolo_to_xyxy(cx, cy, bw + 2 * pw, bh + 2 * ph, W, H)
                side = min(x2 - x1, y2 - y1)
                if side < args.min_side:
                    skipped_small += 1
                    continue
                crop = im.crop((x1, y1, x2, y2))
                cname = names[cid]
                crop_id = f"{lbl.stem}_{i}"
                crop_path = out / cname / f"{crop_id}.png"
                crop.save(crop_path)
                meta.append(
                    {
                        "id": crop_id,
                        "class": cname,
                        "class_id": cid,
                        "path": str(crop_path.relative_to(out)),
                        "src_image": img_path.name,
                        "xyxy": [x1, y1, x2, y2],
                        "w": x2 - x1,
                        "h": y2 - y1,
                    }
                )
                kept += 1

    (out / "manifest.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    by_class: dict[str, int] = {n: 0 for n in FS_NAMES}
    for m in meta:
        by_class[m["class"]] += 1
    print(f"Wrote {kept} crops -> {out}")
    print(f"  skipped_small={skipped_small} skipped_missing_img={skipped_missing}")
    for n in FS_NAMES:
        print(f"  {n}: {by_class[n]}")


if __name__ == "__main__":
    main()
