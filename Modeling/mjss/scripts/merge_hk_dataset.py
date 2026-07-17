"""Extract Roboflow YOLO zips and merge into one HK 43-class dataset."""

from __future__ import annotations

import argparse
import shutil
import zipfile
from collections import Counter
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
OUT = ROOT / "data" / "processed" / "hk_merged"
MAP_PATH = ROOT / "configs" / "hk_tile_map.yaml"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def load_map() -> dict:
    return yaml.safe_load(MAP_PATH.read_text())


def canonical_index(names: list[str]) -> dict[str, int]:
    return {n: i for i, n in enumerate(names)}


def source_id_to_canonical(
    src_names: list[str],
    remap: dict[str, str] | None,
    canon_idx: dict[str, int],
) -> dict[int, int]:
    """Map source class id -> canonical class id."""
    out: dict[int, int] = {}
    remap = remap or {}
    for sid, sname in enumerate(src_names):
        cname = remap.get(sname, sname)
        if cname not in canon_idx:
            raise KeyError(f"Unknown canonical name {cname!r} from source {sname!r}")
        out[sid] = canon_idx[cname]
    return out


def is_screen_path(rel: str, needles: list[str]) -> bool:
    low = rel.lower()
    return any(n in low for n in needles)


def find_image_for_label(img_dir: Path, stem: str) -> Path | None:
    for ext in IMAGE_EXTS:
        p = img_dir / f"{stem}{ext}"
        if p.exists():
            return p
    matches = [p for p in img_dir.iterdir() if p.stem == stem and p.suffix.lower() in IMAGE_EXTS]
    return matches[0] if matches else None


def extract_zip(zip_path: Path, dest: Path) -> None:
    if dest.exists() and any(dest.rglob("*.txt")):
        print(f"  already extracted: {dest}")
        return
    dest.mkdir(parents=True, exist_ok=True)
    print(f"  extracting {zip_path.name} -> {dest}")
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(dest)


def remap_label_file(
    src: Path,
    dst: Path,
    id_map: dict[int, int],
) -> int:
    lines_out: list[str] = []
    n = 0
    text = src.read_text(encoding="utf-8", errors="ignore")
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        sid = int(float(parts[0]))
        if sid not in id_map:
            raise ValueError(f"{src}: unknown class id {sid}")
        parts[0] = str(id_map[sid])
        lines_out.append(" ".join(parts))
        n += 1
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("\n".join(lines_out) + ("\n" if lines_out else ""), encoding="utf-8")
    return n


def merge_source(
    key: str,
    cfg: dict,
    canon_names: list[str],
    exclude: list[str],
    counters: dict[str, Counter],
) -> tuple[int, int, int]:
    """Returns (images_kept, boxes, images_skipped_screen)."""
    zip_path = RAW / cfg["zip"]
    extract_dir = RAW / cfg["extract_dir"]
    if not zip_path.exists():
        raise FileNotFoundError(zip_path)

    extract_zip(zip_path, extract_dir)

    # Roboflow zips may nest under a single top folder
    root = extract_dir
    if not (root / "train").exists():
        subs = [p for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")]
        for sub in subs:
            if (sub / "train").exists() or (sub / "data.yaml").exists():
                root = sub
                break

    id_map = source_id_to_canonical(cfg["names"], cfg.get("remap"), canonical_index(canon_names))
    images_kept = boxes = skipped = 0

    for split in ("train", "valid", "test"):
        # unified layout uses val not valid
        out_split = "val" if split == "valid" else split
        lbl_dir = root / split / "labels"
        img_dir = root / split / "images"
        if not lbl_dir.exists():
            continue

        for lbl in sorted(lbl_dir.glob("*.txt")):
            rel = f"{key}/{split}/{lbl.name}"
            img = find_image_for_label(img_dir, lbl.stem)
            if img is None:
                print(f"  warn: no image for {lbl}")
                continue
            check_path = f"{img.name}|{rel}"
            if is_screen_path(check_path, exclude):
                skipped += 1
                continue

            # Prefix source key to avoid filename collisions across datasets
            stem = f"{key}_{lbl.stem}"
            out_img = OUT / out_split / "images" / f"{stem}{img.suffix.lower()}"
            out_lbl = OUT / out_split / "labels" / f"{stem}.txt"
            out_img.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(img, out_img)
            nboxes = remap_label_file(lbl, out_lbl, id_map)
            images_kept += 1
            boxes += nboxes

            # class histogram from remapped file
            for line in out_lbl.read_text().splitlines():
                if line.strip():
                    cid = int(line.split()[0])
                    counters[out_split][canon_names[cid]] += 1

    return images_kept, boxes, skipped


def write_data_yaml(canon_names: list[str]) -> Path:
    yaml_path = OUT / "data.yaml"
    payload = {
        "path": str(OUT.resolve()),
        "train": "train/images",
        "val": "val/images",
        "test": "test/images",
        "nc": len(canon_names),
        "names": canon_names,
    }
    yaml_path.write_text(yaml.safe_dump(payload, sort_keys=False), encoding="utf-8")
    return yaml_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clean", action="store_true", help="Remove existing merged output first")
    args = parser.parse_args()

    cfg = load_map()
    canon_names: list[str] = cfg["names"]
    exclude: list[str] = cfg.get("screen_exclude_substrings") or []

    if args.clean and OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True, exist_ok=True)

    counters = {"train": Counter(), "val": Counter(), "test": Counter()}
    total_img = total_box = total_skip = 0

    for key, src in cfg["sources"].items():
        print(f"\n=== {key} ===")
        img, box, skip = merge_source(key, src, canon_names, exclude, counters)
        print(f"  kept images={img} boxes={box} skipped_screen={skip}")
        total_img += img
        total_box += box
        total_skip += skip

    # Ensure rare `back` examples are not train-empty (v5 only puts them in valid).
    rebalance_back(canon_names)

    yaml_path = write_data_yaml(canon_names)
    print(f"\nWrote {yaml_path}")
    print(f"TOTAL images={total_img} boxes={total_box} skipped_screen={total_skip}")
    for split, ctr in counters.items():
        print(f"\n{split} class counts ({sum(ctr.values())} boxes):")
        for name in canon_names:
            print(f"  {name:4s}: {ctr[name]}")


def rebalance_back(canon_names: list[str]) -> None:
    """Move most val images that contain `back` into train if train has none."""
    back_id = canon_names.index("back")
    train_lbl = OUT / "train" / "labels"
    val_lbl = OUT / "val" / "labels"
    if not train_lbl.exists() or not val_lbl.exists():
        return

    def files_with_back(lbl_dir: Path) -> list[Path]:
        hits: list[Path] = []
        for f in lbl_dir.glob("*.txt"):
            for line in f.read_text().splitlines():
                if line.strip() and int(line.split()[0]) == back_id:
                    hits.append(f)
                    break
        return hits

    train_hits = files_with_back(train_lbl)
    val_hits = files_with_back(val_lbl)
    if train_hits or len(val_hits) <= 1:
        return

    move = val_hits[:-1]
    for f in move:
        imgs = list((OUT / "val" / "images").glob(f"{f.stem}.*"))
        if not imgs:
            continue
        img = imgs[0]
        shutil.move(str(img), OUT / "train" / "images" / img.name)
        shutil.move(str(f), train_lbl / f.name)
        print(f"  rebalance: moved {f.stem} (back) val -> train")


if __name__ == "__main__":
    main()
