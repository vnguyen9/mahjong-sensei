"""Package hk_merged as a Ultralytics Platform-ready ZIP for cloud upload."""

from __future__ import annotations

import argparse
import zipfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "data" / "processed" / "hk_merged"
OUT_DIR = ROOT / "data" / "exports"
DEFAULT_ZIP = OUT_DIR / "hk-mahjong-yolo26-43cls.zip"


def platform_data_yaml(src_yaml: Path) -> str:
    cfg = yaml.safe_load(src_yaml.read_text(encoding="utf-8"))
    payload = {
        "path": ".",
        "train": "train/images",
        "val": "val/images",
        "test": "test/images",
        "nc": int(cfg["nc"]),
        "names": list(cfg["names"]),
    }
    return yaml.safe_dump(payload, sort_keys=False)


def count_split(split: str) -> tuple[int, int]:
    img = SRC / split / "images"
    lbl = SRC / split / "labels"
    n_img = len(list(img.glob("*"))) if img.exists() else 0
    n_lbl = len(list(lbl.glob("*.txt"))) if lbl.exists() else 0
    return n_img, n_lbl


def package(out_zip: Path) -> None:
    if not (SRC / "data.yaml").exists():
        raise SystemExit(f"Missing dataset at {SRC}. Run: python scripts/merge_hk_dataset.py")

    out_zip.parent.mkdir(parents=True, exist_ok=True)
    if out_zip.exists():
        out_zip.unlink()

    yaml_text = platform_data_yaml(SRC / "data.yaml")
    # Files to include: train/val/test images+labels (skip macOS junk)
    skip_names = {".DS_Store", "__MACOSX"}

    print(f"Packaging {SRC} -> {out_zip}")
    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.writestr("data.yaml", yaml_text)
        for split in ("train", "val", "test"):
            for kind in ("images", "labels"):
                base = SRC / split / kind
                if not base.exists():
                    continue
                for path in sorted(base.rglob("*")):
                    if not path.is_file():
                        continue
                    if path.name in skip_names or any(p in skip_names for p in path.parts):
                        continue
                    arcname = f"{split}/{kind}/{path.name}"
                    zf.write(path, arcname)

    size_gb = out_zip.stat().st_size / (1024**3)
    print(f"\nWrote {out_zip} ({size_gb:.2f} GB)")
    for split in ("train", "val", "test"):
        n_img, n_lbl = count_split(split)
        print(f"  {split}: images={n_img} labels={n_lbl}")

    # Verify archive root
    with zipfile.ZipFile(out_zip) as zf:
        names = zf.namelist()
        assert "data.yaml" in names, "data.yaml missing at zip root"
        assert any(n.startswith("train/images/") for n in names)
        assert any(n.startswith("val/images/") for n in names)
        # ensure no nested hk_merged/ prefix
        bad = [n for n in names if n.startswith("hk_merged/") or n.startswith("data/processed/")]
        assert not bad, f"unexpected nested paths: {bad[:5]}"
        root_yaml = yaml.safe_load(zf.read("data.yaml"))
        assert root_yaml.get("path") in (".", None) or str(root_yaml.get("path")) == "."
        print(f"  zip entries: {len(names)}")
        print(f"  yaml path={root_yaml.get('path')!r} nc={root_yaml.get('nc')}")
    if size_gb >= 10:
        print("WARNING: zip is >= 10 GB (Free plan upload limit). Consider Pro or a smaller split.")
    else:
        print("OK: under Free plan 10 GB upload limit.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", type=Path, default=DEFAULT_ZIP)
    args = parser.parse_args()
    package(args.output.resolve())


if __name__ == "__main__":
    main()
