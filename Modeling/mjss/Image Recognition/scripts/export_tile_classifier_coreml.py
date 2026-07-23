"""Export the calibrated two-head classifier as a float16 Core ML package."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import coremltools as ct
import torch
from torch import nn

from tile_classifier_model import TileFaceClassifier

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RUN = ROOT / "runs" / "tile-classifier-v1"
DEFAULT_OUTPUT = ROOT / "runs" / "tile-classifier-v1" / "MahjongTileFaceClassifierV1.mlpackage"


class ExportModel(nn.Module):
    def __init__(self, model: nn.Module, temperature: float) -> None:
        super().__init__()
        self.model = model
        self.temperature = temperature
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, image: torch.Tensor):
        face_logits, validity_logits = self.model((image - self.mean) / self.std)
        return torch.softmax(face_logits / self.temperature, dim=1), torch.sigmoid(validity_logits)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_RUN / "best.pt")
    parser.add_argument("--calibration", type=Path,
                        default=DEFAULT_RUN / "TileClassifierCalibration.json")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--install-resources", type=Path,
                        help="Copy model and calibration into an app resource directory")
    args = parser.parse_args()
    calibration = json.loads(args.calibration.read_text())
    model = TileFaceClassifier(pretrained=False)
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    model.load_state_dict(checkpoint["state_dict"])
    wrapper = ExportModel(model.eval(), calibration["temperature"]).eval()
    example = torch.rand(1, 3, 192, 192)
    traced = torch.jit.trace(wrapper, example)
    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(name="image", shape=example.shape,
                             scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="faceProbabilities"),
                 ct.TensorType(name="validProbability")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    coreml_model.author = "Mahjong Sensei"
    coreml_model.short_description = "43-face tile classifier with crop-validity head"
    coreml_model.user_defined_metadata.update({
        "input_size": "192x192", "face_classes": "43",
        "unknown": "derived rejection", "temperature": str(calibration["temperature"]),
    })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(args.output)
    if args.install_resources:
        args.install_resources.mkdir(parents=True, exist_ok=True)
        model_target = args.install_resources / args.output.name
        if model_target.exists():
            shutil.rmtree(model_target)
        shutil.copytree(args.output, model_target)
        shutil.copy2(args.calibration,
                     args.install_resources / "TileClassifierCalibration.json")
    print(f"Exported {args.output}")


if __name__ == "__main__":
    main()
