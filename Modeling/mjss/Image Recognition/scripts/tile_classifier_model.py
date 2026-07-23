"""Shared two-head MobileNetV3-Small definition for training and Core ML export."""

from __future__ import annotations

import torch
from torch import nn
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small


class TileFaceClassifier(nn.Module):
    def __init__(self, pretrained: bool = False) -> None:
        super().__init__()
        weights = MobileNet_V3_Small_Weights.DEFAULT if pretrained else None
        backbone = mobilenet_v3_small(weights=weights)
        features = backbone.classifier[0].in_features
        backbone.classifier = nn.Identity()
        self.backbone = backbone
        self.face_head = nn.Sequential(nn.Dropout(0.2), nn.Linear(features, 43))
        self.validity_head = nn.Sequential(nn.Dropout(0.1), nn.Linear(features, 1))

    def forward(self, image: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        embedding = self.backbone(image)
        return self.face_head(embedding), self.validity_head(embedding)
