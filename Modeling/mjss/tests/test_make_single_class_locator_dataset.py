from __future__ import annotations

import hashlib
import importlib.util
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import yaml


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "make_single_class_locator_dataset.py"
)
SPEC = importlib.util.spec_from_file_location("single_class_dataset", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SingleClassDatasetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "source.zip"
        self.output = self.root / "output.zip"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_fixture(
        self,
        *,
        train_label: str = "31 0.42 0.61 0.05 0.12\n7 0.5 0.4 0.2 0.3\n",
        include_test_image: bool = True,
    ) -> None:
        config = {
            "path": ".",
            "train": "train/images",
            "val": "val/images",
            "test": "test/images",
            "nc": 43,
            "names": MODULE.EXPECTED_NAMES,
        }
        with zipfile.ZipFile(self.source, "w") as archive:
            archive.writestr("data.yaml", yaml.safe_dump(config, sort_keys=False))
            archive.writestr("train/images/a.jpg", b"train-image")
            archive.writestr("train/labels/a.txt", train_label)
            archive.writestr("val/images/b.jpg", b"val-image")
            archive.writestr("val/labels/b.txt", b"")
            if include_test_image:
                archive.writestr("test/images/c.jpg", b"test-image")
            archive.writestr("test/labels/c.txt", "42 0.5 0.5 1.0 1.0\n")

    def test_remaps_only_classes_and_preserves_splits_and_empty_labels(self) -> None:
        self.make_fixture(
            train_label=(
                "31 0.42 0.61 0.05 0.12\n"
                "7 0.1 0.1 0.3 0.1 0.3 0.4 0.1 0.4\n"
            )
        )
        before_hash = digest(self.source)

        stats = MODULE.convert_archive(
            self.source,
            self.output,
            expected_counts={"train": 1, "val": 1, "test": 1},
        )

        self.assertEqual(digest(self.source), before_hash)
        self.assertEqual(stats["train"].boxes, 2)
        self.assertEqual(stats["val"].empty_labels, 1)
        with zipfile.ZipFile(self.output) as archive:
            config = yaml.safe_load(archive.read("data.yaml"))
            self.assertEqual(config["nc"], 1)
            self.assertEqual(config["names"], ["tile"])
            self.assertEqual(
                archive.read("train/labels/a.txt").decode(),
                (
                    "0 0.42 0.61 0.05 0.12\n"
                    "0 0.1 0.1 0.3 0.1 0.3 0.4 0.1 0.4\n"
                ),
            )
            self.assertEqual(archive.read("val/labels/b.txt"), b"")
            self.assertEqual(
                archive.read("test/labels/c.txt").decode(),
                "0 0.5 0.5 1.0 1.0\n",
            )
            self.assertEqual(archive.read("train/images/a.jpg"), b"train-image")

    def test_rejects_malformed_label_without_creating_output(self) -> None:
        self.make_fixture(train_label="4 0.5 0.5 0.2\n")
        with self.assertRaises(MODULE.DatasetValidationError):
            MODULE.convert_archive(
                self.source,
                self.output,
                expected_counts={"train": 1, "val": 1, "test": 1},
            )
        self.assertFalse(self.output.exists())

    def test_rejects_unpaired_image_and_label(self) -> None:
        self.make_fixture(include_test_image=False)
        with self.assertRaises(MODULE.DatasetValidationError):
            MODULE.convert_archive(
                self.source,
                self.output,
                expected_counts={"train": 1, "val": 1, "test": 1},
            )
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
