"""Train and calibrate MahjongTileFaceClassifierV1 on source-grouped crops."""

from __future__ import annotations

import argparse
import csv
import io
import json
import random
from pathlib import Path

from PIL import Image
import torch
from torch import nn
from torch.utils.data import DataLoader, Dataset
from torchvision import transforms

from tile_classifier_model import TileFaceClassifier

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA = ROOT / "data" / "processed" / "tile_classifier_v1"
DEFAULT_RUN = ROOT / "runs" / "tile-classifier-v1"


class JPEGCompression:
    def __call__(self, image: Image.Image) -> Image.Image:
        stream = io.BytesIO()
        image.save(stream, format="JPEG", quality=random.randint(35, 90))
        return Image.open(stream).convert("RGB")


class CropDataset(Dataset):
    def __init__(self, root: Path, split: str) -> None:
        with (root / "manifest.csv").open() as handle:
            self.rows = [row for row in csv.DictReader(handle) if row["split"] == split]
        training = split == "train"
        operations: list = []
        if training:
            operations += [
                transforms.RandomResizedCrop(192, scale=(0.76, 1.0), ratio=(0.72, 1.35)),
                transforms.RandomRotation(13),
                transforms.RandomPerspective(distortion_scale=0.20, p=0.45),
                transforms.ColorJitter(brightness=0.35, contrast=0.30, saturation=0.18),
                transforms.RandomApply([transforms.GaussianBlur(5, sigma=(0.1, 1.6))], p=0.25),
                transforms.RandomApply([JPEGCompression()], p=0.35),
            ]
        else:
            operations += [transforms.Resize((192, 192))]
        operations += [transforms.ToTensor()]
        if training:
            operations += [transforms.RandomErasing(p=0.25, scale=(0.02, 0.16), ratio=(0.3, 3.0))]
        operations += [transforms.Normalize([0.485, 0.456, 0.406],
                                             [0.229, 0.224, 0.225])]
        # Intentionally no horizontal flip: glyph handedness is meaningful.
        self.transform = transforms.Compose(operations)
        self.root = root

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int):
        row = self.rows[index]
        image = Image.open(self.root / row["path"]).convert("RGB")
        return self.transform(image), int(row["face_index"]), float(row["valid"])


def macro_f1(predictions: torch.Tensor, targets: torch.Tensor) -> float:
    scores = []
    for face in range(43):
        true_positive = ((predictions == face) & (targets == face)).sum().item()
        false_positive = ((predictions == face) & (targets != face)).sum().item()
        false_negative = ((predictions != face) & (targets == face)).sum().item()
        denominator = 2 * true_positive + false_positive + false_negative
        if denominator:
            scores.append(2 * true_positive / denominator)
    return sum(scores) / max(1, len(scores))


@torch.no_grad()
def evaluate(model: nn.Module, loader: DataLoader, device: torch.device):
    model.eval()
    faces, validity, labels, valid_labels = [], [], [], []
    for images, face, valid in loader:
        face_logits, valid_logits = model(images.to(device))
        faces.append(face_logits.cpu())
        validity.append(valid_logits.squeeze(1).cpu())
        labels.append(face)
        valid_labels.append(valid)
    return map(torch.cat, (faces, validity, labels, valid_labels))


def calibrate(face_logits: torch.Tensor, valid_logits: torch.Tensor,
              labels: torch.Tensor, valid_labels: torch.Tensor) -> dict[str, float]:
    valid_mask = valid_labels == 1
    log_temperature = torch.zeros(1, requires_grad=True)
    optimizer = torch.optim.LBFGS([log_temperature], lr=0.05, max_iter=75)

    def closure():
        optimizer.zero_grad()
        temperature = log_temperature.exp().clamp(0.05, 10)
        loss = nn.functional.cross_entropy(face_logits[valid_mask] / temperature, labels[valid_mask])
        loss.backward()
        return loss

    optimizer.step(closure)
    temperature = float(log_temperature.exp().clamp(0.05, 10))
    probabilities = (face_logits / temperature).softmax(1)
    top = probabilities.topk(2, dim=1).values
    validity = valid_logits.sigmoid()
    invalid = valid_labels == 0
    best = (0.80, 0.78, 0.18)
    best_acceptance = -1.0
    for validity_threshold in (0.70, 0.75, 0.80, 0.85, 0.90):
        for confidence_threshold in (0.70, 0.74, 0.78, 0.82, 0.86):
            for margin_threshold in (0.10, 0.14, 0.18, 0.22):
                accepted = ((validity >= validity_threshold)
                            & (top[:, 0] >= confidence_threshold)
                            & ((top[:, 0] - top[:, 1]) >= margin_threshold))
                false_accept = float(accepted[invalid].float().mean()) if invalid.any() else 0
                true_accept = float(accepted[valid_mask].float().mean())
                if false_accept <= 0.01 and true_accept > best_acceptance:
                    best_acceptance = true_accept
                    best = (validity_threshold, confidence_threshold, margin_threshold)
    return {"minimumConfidence": best[1], "minimumMargin": best[2],
            "minimumValidity": best[0], "temperature": temperature}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--run", type=Path, default=DEFAULT_RUN)
    parser.add_argument("--epochs", type=int, default=45)
    parser.add_argument("--batch", type=int, default=128)
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()
    args.run.mkdir(parents=True, exist_ok=True)
    device = torch.device(args.device if torch.backends.mps.is_available() else "cpu")
    train = DataLoader(CropDataset(args.data, "train"), batch_size=args.batch,
                       shuffle=True, num_workers=4, persistent_workers=True)
    validation = DataLoader(CropDataset(args.data, "val"), batch_size=args.batch * 2,
                            shuffle=False, num_workers=4)
    model = TileFaceClassifier(pretrained=True).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, args.epochs)
    face_loss = nn.CrossEntropyLoss(label_smoothing=0.05)
    validity_loss = nn.BCEWithLogitsLoss()
    best_score = -1.0
    for epoch in range(args.epochs):
        model.train()
        for images, labels, valid in train:
            images, labels, valid = images.to(device), labels.to(device), valid.to(device)
            face_logits, valid_logits = model(images)
            face_mask = labels >= 0
            classification_loss = (face_loss(face_logits[face_mask], labels[face_mask])
                                   if face_mask.any() else face_logits.sum() * 0)
            loss = classification_loss + 0.6 * validity_loss(valid_logits.squeeze(1), valid)
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            optimizer.step()
        scheduler.step()
        logits, valid_logits, labels, valid = evaluate(model, validation, device)
        mask = valid == 1
        score = macro_f1(logits[mask].argmax(1), labels[mask])
        print(f"epoch={epoch + 1:03d} val_macro_f1={score:.4f}")
        if score > best_score:
            best_score = score
            torch.save({"state_dict": model.state_dict(), "macro_f1": score},
                       args.run / "best.pt")
    checkpoint = torch.load(args.run / "best.pt", map_location=device, weights_only=True)
    model.load_state_dict(checkpoint["state_dict"])
    logits, valid_logits, labels, valid = evaluate(model, validation, device)
    calibration = calibrate(logits, valid_logits, labels, valid)
    (args.run / "TileClassifierCalibration.json").write_text(
        json.dumps(calibration, indent=2) + "\n"
    )
    print(f"best macro-F1={best_score:.4f}; calibration={calibration}")


if __name__ == "__main__":
    main()
