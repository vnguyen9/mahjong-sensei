#!/usr/bin/env python3
"""Convert the canonical 43-class HK dataset ZIP into a one-class tile locator.

The conversion is deliberately lossless with respect to dataset membership and
geometry: images, split assignments, filenames, and YOLO box coordinates are
preserved. Only the class id at the start of each non-empty label line changes
to ``0``. The source archive is opened read-only and the output is built at a
temporary sibling path before an atomic rename.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import os
import shutil
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import BinaryIO

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = (
    ROOT / "data" / "exports" / "mjss-hk-mahjong-yolo26-v3-fsbal.zip"
)
DEFAULT_OUTPUT = (
    ROOT
    / "data"
    / "exports"
    / "mjss-hk-mahjong-yolo26-v3-fsbal-single-class.zip"
)

SPLITS = ("train", "val", "test")
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}
MAX_PLATFORM_BYTES = 10 * 1024**3

EXPECTED_NAMES = [
    "1m",
    "2m",
    "3m",
    "4m",
    "5m",
    "6m",
    "7m",
    "8m",
    "9m",
    "1p",
    "2p",
    "3p",
    "4p",
    "5p",
    "6p",
    "7p",
    "8p",
    "9p",
    "1s",
    "2s",
    "3s",
    "4s",
    "5s",
    "6s",
    "7s",
    "8s",
    "9s",
    "1z",
    "2z",
    "3z",
    "4z",
    "5z",
    "6z",
    "7z",
    "1F",
    "2F",
    "3F",
    "4F",
    "1S",
    "2S",
    "3S",
    "4S",
    "back",
]

EXPECTED_SPLIT_COUNTS = {
    "train": 24_275,
    "val": 3_467,
    "test": 627,
}


class DatasetValidationError(ValueError):
    """The input or generated archive does not satisfy the dataset contract."""


@dataclass(frozen=True)
class SplitStats:
    images: int
    labels: int
    boxes: int
    empty_labels: int


@dataclass(frozen=True)
class PreparedSource:
    entries: tuple[zipfile.ZipInfo, ...]
    rewritten_labels: dict[str, bytes]
    stats: dict[str, SplitStats]


def sha256_file(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def _yaml_mapping(payload: bytes, archive_name: str) -> dict:
    try:
        value = yaml.safe_load(payload.decode("utf-8"))
    except (UnicodeDecodeError, yaml.YAMLError) as error:
        raise DatasetValidationError(
            f"{archive_name}: data.yaml is not valid UTF-8 YAML: {error}"
        ) from error
    if not isinstance(value, dict):
        raise DatasetValidationError(f"{archive_name}: data.yaml must be a mapping")
    return value


def _validate_source_yaml(payload: bytes, archive_name: str) -> None:
    config = _yaml_mapping(payload, archive_name)
    if config.get("path") not in (None, "."):
        raise DatasetValidationError(
            f"{archive_name}: data.yaml path must be '.', got {config.get('path')!r}"
        )
    for split in SPLITS:
        expected = f"{split}/images"
        if config.get(split) != expected:
            raise DatasetValidationError(
                f"{archive_name}: data.yaml {split!r} must be {expected!r}"
            )
    if config.get("nc") != len(EXPECTED_NAMES):
        raise DatasetValidationError(
            f"{archive_name}: expected nc={len(EXPECTED_NAMES)}, "
            f"got {config.get('nc')!r}"
        )
    if config.get("names") != EXPECTED_NAMES:
        raise DatasetValidationError(
            f"{archive_name}: class names/order do not match the canonical "
            "43-class HK schema"
        )


def _entry_key(path: PurePosixPath, kind: str) -> str:
    relative = PurePosixPath(*path.parts[2:])
    if not relative.name:
        raise DatasetValidationError(f"invalid empty {kind} path: {path}")
    return str(relative.with_suffix(""))


def _rewrite_label(payload: bytes, member_name: str) -> tuple[bytes, int]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise DatasetValidationError(
            f"{member_name}: label is not valid UTF-8"
        ) from error

    output: list[str] = []
    boxes = 0
    for line_number, line_with_ending in enumerate(
        text.splitlines(keepends=True), start=1
    ):
        line = line_with_ending.rstrip("\r\n")
        ending = line_with_ending[len(line) :]
        if not line.strip():
            output.append(line_with_ending)
            continue

        parts = line.split()
        is_box = len(parts) == 5
        is_polygon = len(parts) >= 7 and (len(parts) - 1) % 2 == 0
        if not (is_box or is_polygon):
            raise DatasetValidationError(
                f"{member_name}:{line_number}: expected a 5-field YOLO box "
                "or class id followed by at least 3 normalized polygon points; "
                f"got {len(parts)} fields"
            )
        try:
            class_id = int(parts[0])
        except ValueError as error:
            raise DatasetValidationError(
                f"{member_name}:{line_number}: class id must be an integer"
            ) from error
        if not 0 <= class_id < len(EXPECTED_NAMES):
            raise DatasetValidationError(
                f"{member_name}:{line_number}: class id {class_id} is outside 0...42"
            )

        try:
            coordinates = tuple(map(float, parts[1:]))
        except ValueError as error:
            raise DatasetValidationError(
                f"{member_name}:{line_number}: coordinates must be numeric"
            ) from error
        if not all(math.isfinite(value) for value in coordinates):
            raise DatasetValidationError(
                f"{member_name}:{line_number}: coordinates must be finite"
            )
        if is_box:
            x_center, y_center, width, height = coordinates
            if not (0 <= x_center <= 1 and 0 <= y_center <= 1):
                raise DatasetValidationError(
                    f"{member_name}:{line_number}: box center must be normalized"
                )
            if not (0 < width <= 1 and 0 < height <= 1):
                raise DatasetValidationError(
                    f"{member_name}:{line_number}: box size must be in (0, 1]"
                )
        elif not all(0 <= value <= 1 for value in coordinates):
            raise DatasetValidationError(
                f"{member_name}:{line_number}: polygon coordinates must be normalized"
            )

        first_non_space = len(line) - len(line.lstrip())
        class_end = first_non_space
        while class_end < len(line) and not line[class_end].isspace():
            class_end += 1
        output.append(line[:first_non_space] + "0" + line[class_end:] + ending)
        boxes += 1

    # ``splitlines`` returns no elements for a truly empty file. Preserve it.
    return "".join(output).encode("utf-8"), boxes


def inspect_source(
    archive: zipfile.ZipFile,
    expected_counts: dict[str, int] | None,
) -> PreparedSource:
    archive_name = Path(archive.filename or "<archive>").name
    entries = tuple(info for info in archive.infolist() if not info.is_dir())
    names = [info.filename for info in entries]
    if len(names) != len(set(names)):
        raise DatasetValidationError(f"{archive_name}: duplicate ZIP member names")
    if names.count("data.yaml") != 1:
        raise DatasetValidationError(
            f"{archive_name}: expected exactly one root data.yaml"
        )
    _validate_source_yaml(archive.read("data.yaml"), archive_name)

    images: dict[str, dict[str, str]] = {split: {} for split in SPLITS}
    labels: dict[str, dict[str, str]] = {split: {} for split in SPLITS}
    for info in entries:
        if info.filename == "data.yaml":
            continue
        path = PurePosixPath(info.filename)
        if (
            path.is_absolute()
            or ".." in path.parts
            or len(path.parts) < 3
            or path.parts[0] not in SPLITS
            or path.parts[1] not in {"images", "labels"}
        ):
            raise DatasetValidationError(
                f"{archive_name}: unexpected member path {info.filename!r}"
            )

        split, kind = path.parts[:2]
        key = _entry_key(path, kind)
        if kind == "images":
            if path.suffix.lower() not in IMAGE_EXTENSIONS:
                raise DatasetValidationError(
                    f"{archive_name}: unsupported image extension in {info.filename!r}"
                )
            if key in images[split]:
                raise DatasetValidationError(
                    f"{archive_name}: multiple images map to {split}/{key}"
                )
            images[split][key] = info.filename
        else:
            if path.suffix.lower() != ".txt":
                raise DatasetValidationError(
                    f"{archive_name}: label must end in .txt: {info.filename!r}"
                )
            if key in labels[split]:
                raise DatasetValidationError(
                    f"{archive_name}: duplicate label key {split}/{key}"
                )
            labels[split][key] = info.filename

    rewritten_labels: dict[str, bytes] = {}
    stats: dict[str, SplitStats] = {}
    for split in SPLITS:
        image_keys = set(images[split])
        label_keys = set(labels[split])
        missing_labels = sorted(image_keys - label_keys)
        missing_images = sorted(label_keys - image_keys)
        if missing_labels or missing_images:
            detail = []
            if missing_labels:
                detail.append(f"images without labels={missing_labels[:3]}")
            if missing_images:
                detail.append(f"labels without images={missing_images[:3]}")
            raise DatasetValidationError(
                f"{archive_name}: {split} image/label pairing failed: "
                + "; ".join(detail)
            )
        if expected_counts is not None:
            expected = expected_counts[split]
            if len(image_keys) != expected:
                raise DatasetValidationError(
                    f"{archive_name}: {split} expected {expected} pairs, "
                    f"found {len(image_keys)}"
                )

        box_count = 0
        empty_count = 0
        for member_name in labels[split].values():
            rewritten, boxes = _rewrite_label(archive.read(member_name), member_name)
            rewritten_labels[member_name] = rewritten
            box_count += boxes
            empty_count += int(boxes == 0)
        stats[split] = SplitStats(
            images=len(image_keys),
            labels=len(label_keys),
            boxes=box_count,
            empty_labels=empty_count,
        )

    return PreparedSource(
        entries=entries,
        rewritten_labels=rewritten_labels,
        stats=stats,
    )


def _single_class_yaml() -> bytes:
    config = {
        "path": ".",
        "train": "train/images",
        "val": "val/images",
        "test": "test/images",
        "nc": 1,
        "names": ["tile"],
    }
    return yaml.safe_dump(config, sort_keys=False).encode("utf-8")


def _copy_image(
    source: zipfile.ZipFile,
    destination: zipfile.ZipFile,
    info: zipfile.ZipInfo,
) -> None:
    # JPEG/PNG/WebP bytes gain almost nothing from a second DEFLATE pass. Store
    # them verbatim for a much faster 4+ GB conversion while preserving their
    # decoded bytes and all useful ZIP metadata.
    output_info = zipfile.ZipInfo(info.filename, date_time=info.date_time)
    output_info.compress_type = zipfile.ZIP_STORED
    output_info.comment = info.comment
    output_info.extra = info.extra
    output_info.internal_attr = info.internal_attr
    output_info.external_attr = info.external_attr
    output_info.create_system = info.create_system
    with source.open(info, "r") as input_stream:
        with destination.open(output_info, "w", force_zip64=True) as output_stream:
            shutil.copyfileobj(input_stream, output_stream, length=1024 * 1024)


def _output_label_stats(payload: bytes, member_name: str) -> tuple[int, bool]:
    rewritten, boxes = _rewrite_label(payload, member_name)
    if rewritten != payload:
        raise DatasetValidationError(
            f"{member_name}: generated label still contains a non-zero class id"
        )
    return boxes, boxes == 0


def validate_output(
    output: Path,
    source_stats: dict[str, SplitStats],
) -> None:
    with zipfile.ZipFile(output, "r") as archive:
        bad_member = archive.testzip()
        if bad_member is not None:
            raise DatasetValidationError(
                f"{output.name}: CRC validation failed at {bad_member}"
            )
        config = _yaml_mapping(archive.read("data.yaml"), output.name)
        expected_yaml = _yaml_mapping(_single_class_yaml(), output.name)
        if config != expected_yaml:
            raise DatasetValidationError(
                f"{output.name}: generated data.yaml does not match one-class contract"
            )

        entries = [info for info in archive.infolist() if not info.is_dir()]
        names = [info.filename for info in entries]
        if len(names) != len(set(names)):
            raise DatasetValidationError(f"{output.name}: duplicate ZIP members")
        allowed_prefixes = tuple(f"{split}/" for split in SPLITS)
        unexpected = [
            name
            for name in names
            if name != "data.yaml" and not name.startswith(allowed_prefixes)
        ]
        if unexpected:
            raise DatasetValidationError(
                f"{output.name}: unexpected paths: {unexpected[:3]}"
            )

        for split in SPLITS:
            image_names = [
                name for name in names if name.startswith(f"{split}/images/")
            ]
            label_names = [
                name
                for name in names
                if name.startswith(f"{split}/labels/") and name.endswith(".txt")
            ]
            boxes = 0
            empty_labels = 0
            for member_name in label_names:
                member_boxes, empty = _output_label_stats(
                    archive.read(member_name), member_name
                )
                boxes += member_boxes
                empty_labels += int(empty)
            actual = SplitStats(
                images=len(image_names),
                labels=len(label_names),
                boxes=boxes,
                empty_labels=empty_labels,
            )
            if actual != source_stats[split]:
                raise DatasetValidationError(
                    f"{output.name}: {split} stats changed: "
                    f"source={source_stats[split]}, output={actual}"
                )


def convert_archive(
    source: Path,
    output: Path,
    *,
    expected_counts: dict[str, int] | None = EXPECTED_SPLIT_COUNTS,
    force: bool = False,
) -> dict[str, SplitStats]:
    source = source.resolve()
    output = output.resolve()
    if not source.is_file():
        raise DatasetValidationError(f"source archive does not exist: {source}")
    if source == output:
        raise DatasetValidationError("source and output paths must differ")
    if output.exists() and not force:
        raise DatasetValidationError(
            f"output already exists: {output} (pass --force to replace it)"
        )

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    if temporary.exists():
        temporary.unlink()

    try:
        with zipfile.ZipFile(source, "r") as input_zip:
            prepared = inspect_source(input_zip, expected_counts)
            with zipfile.ZipFile(
                temporary,
                "w",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=6,
                allowZip64=True,
            ) as output_zip:
                output_zip.writestr("data.yaml", _single_class_yaml())
                for info in prepared.entries:
                    if info.filename == "data.yaml":
                        continue
                    if "/images/" in info.filename:
                        _copy_image(input_zip, output_zip, info)
                    else:
                        output_zip.writestr(
                            info.filename,
                            prepared.rewritten_labels[info.filename],
                            compress_type=zipfile.ZIP_DEFLATED,
                            compresslevel=6,
                        )

        validate_output(temporary, prepared.stats)
        if temporary.stat().st_size >= MAX_PLATFORM_BYTES:
            raise DatasetValidationError(
                f"generated archive is {temporary.stat().st_size / 1024**3:.2f} GiB, "
                "which exceeds the 10 GiB platform limit"
            )
        os.replace(temporary, output)
        return prepared.stats
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_SOURCE,
        help=f"source 43-class ZIP (default: {DEFAULT_SOURCE})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"generated one-class ZIP (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--skip-expected-counts",
        action="store_true",
        help="validate structure and pairing but do not require canonical split counts",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="atomically replace an existing output archive",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    expected_counts = None if args.skip_expected_counts else EXPECTED_SPLIT_COUNTS
    try:
        print(f"Source: {args.source.resolve()}")
        source_hash = sha256_file(args.source.resolve())
        print(f"Source SHA-256: {source_hash}")
        stats = convert_archive(
            args.source,
            args.output,
            expected_counts=expected_counts,
            force=args.force,
        )
        output = args.output.resolve()
        output_hash = sha256_file(output)
        print(f"Output: {output}")
        print(f"Output SHA-256: {output_hash}")
        for split in SPLITS:
            stat = stats[split]
            print(
                f"{split}: images={stat.images} labels={stat.labels} "
                f"boxes={stat.boxes} empty_labels={stat.empty_labels}"
            )
        print(f"Archive size: {output.stat().st_size / 1024**3:.2f} GiB")
        print("Validation: PASS — all generated class ids are 0")
        return 0
    except (DatasetValidationError, zipfile.BadZipFile, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
