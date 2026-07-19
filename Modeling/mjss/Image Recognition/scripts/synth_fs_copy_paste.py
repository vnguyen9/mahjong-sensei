"""Compose flower/season copy-paste synthetics and assemble hk_merged_v3_fsbal."""

from __future__ import annotations

import argparse
import json
import math
import random
import shutil
from collections import Counter, defaultdict
from pathlib import Path

import yaml
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SRC = ROOT / "data" / "processed" / "hk_merged_v3"
DEFAULT_BANK = ROOT / "data" / "processed" / "fs_crop_bank"
DEFAULT_OUT = ROOT / "data" / "processed" / "hk_merged_v3_fsbal"
FS_NAMES = ("1F", "2F", "3F", "4F", "1S", "2S", "3S", "4S")
IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".bmp")
# Confusing pairs to mix on the same canvas
HARD_PAIRS = (
    ("1F", "2F"),
    ("2F", "3F"),
    ("3F", "4F"),
    ("1F", "4F"),
    ("1S", "2S"),
    ("2S", "3S"),
    ("3S", "4S"),
    ("1S", "4S"),
    ("1F", "1S"),
    ("4F", "4S"),
)


def find_image(img_dir: Path, stem: str) -> Path | None:
    for ext in IMAGE_EXTS:
        p = img_dir / f"{stem}{ext}"
        if p.exists():
            return p
    matches = [p for p in img_dir.iterdir() if p.stem == stem and p.suffix.lower() in IMAGE_EXTS]
    return matches[0] if matches else None


def load_boxes(lbl: Path) -> list[tuple[int, float, float, float, float]]:
    boxes: list[tuple[int, float, float, float, float]] = []
    for line in lbl.read_text(encoding="utf-8", errors="ignore").splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        boxes.append((int(float(parts[0])), *map(float, parts[1:5])))
    return boxes


def yolo_to_xyxy(
    cx: float, cy: float, w: float, h: float, W: int, H: int
) -> tuple[float, float, float, float]:
    return (
        (cx - w / 2) * W,
        (cy - h / 2) * H,
        (cx + w / 2) * W,
        (cy + h / 2) * H,
    )


def xyxy_to_yolo(
    x1: float, y1: float, x2: float, y2: float, W: int, H: int
) -> tuple[float, float, float, float]:
    cx = ((x1 + x2) / 2) / W
    cy = ((y1 + y2) / 2) / H
    bw = (x2 - x1) / W
    bh = (y2 - y1) / H
    return cx, cy, bw, bh


def iou_xyxy(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> float:
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
    inter = iw * ih
    if inter <= 0:
        return 0.0
    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def median_tile_size(boxes: list[tuple[int, float, float, float, float]], W: int, H: int) -> float:
    if not boxes:
        return min(W, H) * 0.08
    sizes = [((bw * W) + (bh * H)) / 2 for _, _, _, bw, bh in boxes]
    sizes.sort()
    return sizes[len(sizes) // 2]


def augment_crop(crop: Image.Image, rng: random.Random) -> Image.Image:
    im = crop.convert("RGBA")
    # rotation
    angle = rng.uniform(-28, 28)
    im = im.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    # mild perspective via affine-ish resize asymmetry
    if rng.random() < 0.5:
        w, h = im.size
        scale_x = rng.uniform(0.88, 1.12)
        scale_y = rng.uniform(0.88, 1.12)
        im = im.resize(
            (max(8, int(w * scale_x)), max(8, int(h * scale_y))),
            Image.Resampling.BICUBIC,
        )
    # color / brightness
    rgb = im.convert("RGB")
    rgb = ImageEnhance.Brightness(rgb).enhance(rng.uniform(0.75, 1.25))
    rgb = ImageEnhance.Color(rgb).enhance(rng.uniform(0.7, 1.35))
    rgb = ImageEnhance.Contrast(rgb).enhance(rng.uniform(0.8, 1.25))
    if rng.random() < 0.35:
        rgb = rgb.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.2, 1.1)))
    if rng.random() < 0.25:
        rgb = ImageOps.autocontrast(rgb, cutoff=rng.uniform(0, 2))
    # rebuild alpha with feathered edge
    alpha = im.split()[-1] if im.mode == "RGBA" else Image.new("L", rgb.size, 255)
    # feather: erode-ish via blur on alpha
    alpha = alpha.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.6, 1.8)))
    # optional partial cutout
    if rng.random() < 0.2:
        aw, ah = alpha.size
        cx = rng.randint(0, aw - 1)
        cy = rng.randint(0, ah - 1)
        rw = max(2, int(aw * rng.uniform(0.1, 0.35)))
        rh = max(2, int(ah * rng.uniform(0.1, 0.35)))
        mask = Image.new("L", alpha.size, 255)
        draw = ImageDraw.Draw(mask)
        draw.rectangle(
            [cx - rw // 2, cy - rh // 2, cx + rw // 2, cy + rh // 2],
            fill=0,
        )
        alpha = Image.composite(alpha, Image.new("L", alpha.size, 0), mask)
    out = rgb.convert("RGBA")
    out.putalpha(alpha)
    return out


def paste_rgba(
    canvas: Image.Image,
    patch: Image.Image,
    x: int,
    y: int,
) -> tuple[float, float, float, float]:
    """Paste RGBA patch; return xyxy of opaque bbox on canvas."""
    W, H = canvas.size
    pw, ph = patch.size
    # soft shadow
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sh = patch.split()[-1].point(lambda a: int(a * 0.35))
    shadow_patch = Image.new("RGBA", patch.size, (0, 0, 0, 0))
    shadow_patch.putalpha(sh)
    sx, sy = min(W - 1, x + 3), min(H - 1, y + 4)
    shadow.paste(shadow_patch, (sx, sy), shadow_patch)
    canvas.alpha_composite(shadow)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    layer.paste(patch, (x, y), patch)
    canvas.alpha_composite(layer)

    # opaque bbox from alpha
    alpha = patch.split()[-1]
    bbox = alpha.getbbox()
    if bbox is None:
        return float(x), float(y), float(x + pw), float(y + ph)
    bx1, by1, bx2, by2 = bbox
    return float(x + bx1), float(y + by1), float(x + bx2), float(y + by2)


def write_labels(path: Path, boxes: list[tuple[int, float, float, float, float]]) -> None:
    lines = [f"{cid} {cx:.6f} {cy:.6f} {bw:.6f} {bh:.6f}" for cid, cx, cy, bw, bh in boxes]
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def copy_split(src: Path, dst: Path, split: str) -> None:
    for kind in ("images", "labels"):
        s = src / split / kind
        d = dst / split / kind
        d.mkdir(parents=True, exist_ok=True)
        if not s.exists():
            continue
        for p in s.iterdir():
            if p.is_file() and p.name != ".DS_Store":
                shutil.copy2(p, d / p.name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", type=Path, default=DEFAULT_SRC)
    parser.add_argument("--bank", type=Path, default=DEFAULT_BANK)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--target-per-class",
        type=int,
        default=3000,
        help="Target train box count per F/S class after synth (+oversample later)",
    )
    parser.add_argument("--pastes-min", type=int, default=2)
    parser.add_argument("--pastes-max", type=int, default=8)
    parser.add_argument("--max-iou", type=float, default=0.35)
    parser.add_argument("--oversample", type=int, default=2, help="Copies of each real F/S image")
    parser.add_argument("--clean", action="store_true")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    src = args.src if args.src.is_absolute() else ROOT / args.src
    bank = args.bank if args.bank.is_absolute() else ROOT / args.bank
    out = args.out if args.out.is_absolute() else ROOT / args.out

    manifest_path = bank / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit(f"Missing crop bank. Run: python scripts/build_fs_crop_bank.py")

    meta = json.loads(manifest_path.read_text(encoding="utf-8"))
    by_class: dict[str, list[dict]] = defaultdict(list)
    for m in meta:
        by_class[m["class"]].append(m)
    for n in FS_NAMES:
        if not by_class[n]:
            raise SystemExit(f"No crops for class {n}")

    cfg = yaml.safe_load((src / "data.yaml").read_text(encoding="utf-8"))
    names: list[str] = list(cfg["names"])
    name_to_id = {n: i for i, n in enumerate(names)}
    fs_ids = {name_to_id[n] for n in FS_NAMES}

    # baseline train counts
    base_counts: Counter[str] = Counter()
    train_lbl = src / "train" / "labels"
    train_img = src / "train" / "images"
    bg_stems: list[str] = []
    fs_stems: list[str] = []
    for lbl in train_lbl.glob("*.txt"):
        boxes = load_boxes(lbl)
        has_fs = False
        for cid, *_ in boxes:
            if cid in fs_ids:
                base_counts[names[cid]] += 1
                has_fs = True
        if find_image(train_img, lbl.stem):
            bg_stems.append(lbl.stem)
            if has_fs:
                fs_stems.append(lbl.stem)

    need = {n: max(0, args.target_per_class - base_counts[n]) for n in FS_NAMES}
    print("Base train F/S counts:", dict(base_counts))
    print("Synth boxes still needed:", need)

    if args.clean and out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    # copy val/test untouched; seed train with originals
    for split in ("val", "test"):
        copy_split(src, out, split)
    copy_split(src, out, "train")

    reuse_cap = Counter()
    max_reuse = max(8, math.ceil(sum(need.values()) / max(1, len(meta)) * 3))
    synth_added: Counter[str] = Counter()
    synth_images = 0
    crop_cache: dict[str, Image.Image] = {}

    def load_crop(m: dict) -> Image.Image:
        key = m["id"]
        if key not in crop_cache:
            crop_cache[key] = Image.open(bank / m["path"]).convert("RGBA")
            if len(crop_cache) > 256:
                # drop arbitrary old entry
                crop_cache.pop(next(iter(crop_cache)))
        return crop_cache[key].copy()

    def pick_crop(cname: str) -> dict | None:
        candidates = [m for m in by_class[cname] if reuse_cap[m["id"]] < max_reuse]
        if not candidates:
            candidates = by_class[cname]
        # prefer less-used
        candidates.sort(key=lambda m: reuse_cap[m["id"]])
        pool = candidates[: max(1, len(candidates) // 3)] or candidates
        return rng.choice(pool)

    # keep composing until each class hits target or we stall
    stall = 0
    while any(synth_added[n] < need[n] for n in FS_NAMES) and stall < 500:
        stem = rng.choice(bg_stems)
        img_path = find_image(train_img, stem)
        lbl_path = train_lbl / f"{stem}.txt"
        if img_path is None:
            stall += 1
            continue

        base = Image.open(img_path).convert("RGBA")
        W, H = base.size
        orig_boxes = load_boxes(lbl_path)
        tile = median_tile_size(orig_boxes, W, H)
        placed_xyxy: list[tuple[float, float, float, float]] = [
            yolo_to_xyxy(cx, cy, bw, bh, W, H) for _, cx, cy, bw, bh in orig_boxes
        ]
        new_boxes: list[tuple[int, float, float, float, float]] = []

        # class mix: underfilled + optional hard pair
        under = [n for n in FS_NAMES if synth_added[n] < need[n]]
        if not under:
            break
        n_paste = rng.randint(args.pastes_min, args.pastes_max)
        plan: list[str] = []
        if rng.random() < 0.55:
            a, b = rng.choice(HARD_PAIRS)
            if a in under or b in under:
                plan.extend([a, b])
        while len(plan) < n_paste:
            # weighted toward classes still needing boxes
            weights = [max(1, need[n] - synth_added[n]) for n in FS_NAMES]
            plan.append(rng.choices(FS_NAMES, weights=weights, k=1)[0])

        canvas = base.copy()
        for cname in plan:
            if synth_added[cname] >= need[cname] and rng.random() > 0.15:
                continue
            m = pick_crop(cname)
            if m is None:
                continue
            patch = augment_crop(load_crop(m), rng)
            target = tile * rng.uniform(0.7, 1.3)
            pw, ph = patch.size
            scale = target / max(pw, ph)
            nw = max(12, int(pw * scale))
            nh = max(12, int(ph * scale))
            patch = patch.resize((nw, nh), Image.Resampling.BICUBIC)

            placed = False
            for _try in range(40):
                x = rng.randint(0, max(0, W - nw))
                y = rng.randint(0, max(0, H - nh))
                cand = (float(x), float(y), float(x + nw), float(y + nh))
                if any(iou_xyxy(cand, p) > args.max_iou for p in placed_xyxy):
                    continue
                xyxy = paste_rgba(canvas, patch, x, y)
                # clamp
                x1 = max(0.0, min(W - 1.0, xyxy[0]))
                y1 = max(0.0, min(H - 1.0, xyxy[1]))
                x2 = max(x1 + 1.0, min(float(W), xyxy[2]))
                y2 = max(y1 + 1.0, min(float(H), xyxy[3]))
                if (x2 - x1) < 8 or (y2 - y1) < 8:
                    continue
                cx, cy, bw, bh = xyxy_to_yolo(x1, y1, x2, y2, W, H)
                if not (0 < bw < 1 and 0 < bh < 1):
                    continue
                new_boxes.append((name_to_id[cname], cx, cy, bw, bh))
                placed_xyxy.append((x1, y1, x2, y2))
                reuse_cap[m["id"]] += 1
                synth_added[cname] += 1
                placed = True
                break
            if not placed:
                continue

        if not new_boxes:
            stall += 1
            continue

        # keep original boxes that are not heavily occluded by pastes
        kept_orig: list[tuple[int, float, float, float, float]] = []
        paste_xyxys = placed_xyxy[len(orig_boxes) :]
        for box, xy in zip(orig_boxes, placed_xyxy[: len(orig_boxes)]):
            if any(iou_xyxy(xy, p) > 0.45 for p in paste_xyxys):
                continue
            kept_orig.append(box)

        out_boxes = kept_orig + new_boxes
        out_stem = f"synth_fs_{synth_images:06d}_{stem}"
        out_img = out / "train" / "images" / f"{out_stem}.jpg"
        out_lbl = out / "train" / "labels" / f"{out_stem}.txt"
        out_img.parent.mkdir(parents=True, exist_ok=True)
        out_lbl.parent.mkdir(parents=True, exist_ok=True)
        canvas.convert("RGB").save(out_img, quality=92)
        write_labels(out_lbl, out_boxes)
        synth_images += 1
        stall = 0
        if synth_images % 100 == 0:
            print(
                f"  synth_images={synth_images} added={dict(synth_added)} "
                f"need_left={{ {', '.join(f'{n}:{max(0, need[n]-synth_added[n])}' for n in FS_NAMES)} }}"
            )

    print(f"Created {synth_images} synth images; boxes added: {dict(synth_added)}")

    # oversample real F/S images
    over_n = 0
    if args.oversample > 1:
        for stem in fs_stems:
            img_path = find_image(train_img, stem)
            lbl_path = train_lbl / f"{stem}.txt"
            if img_path is None:
                continue
            for k in range(1, args.oversample):
                new_stem = f"oversample_fs_{k}_{stem}"
                shutil.copy2(img_path, out / "train" / "images" / f"{new_stem}{img_path.suffix.lower()}")
                shutil.copy2(lbl_path, out / "train" / "labels" / f"{new_stem}.txt")
                over_n += 1
    print(f"Oversampled {over_n} extra F/S train images (factor={args.oversample})")

    # data.yaml with absolute path for local train
    payload = {
        "path": str(out.resolve()),
        "train": "train/images",
        "val": "val/images",
        "test": "test/images",
        "nc": len(names),
        "names": names,
    }
    (out / "data.yaml").write_text(yaml.safe_dump(payload, sort_keys=False), encoding="utf-8")

    # final train counts for F/S
    final: Counter[str] = Counter()
    for lbl in (out / "train" / "labels").glob("*.txt"):
        for cid, *_ in load_boxes(lbl):
            if cid in fs_ids:
                final[names[cid]] += 1
    n_train_img = len(list((out / "train" / "images").iterdir()))
    print(f"\nWrote {out}  train_images≈{n_train_img}")
    print("Final train F/S box counts:")
    for n in FS_NAMES:
        print(f"  {n}: {final[n]} (base {base_counts[n]} -> +{final[n] - base_counts[n]})")


if __name__ == "__main__":
    main()
