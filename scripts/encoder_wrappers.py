"""Raw paired projections. Imported only by the explicitly invoked macOS export."""

import torch
from torch import nn


class ImageEncoder(nn.Module):
    def __init__(self, sentence_transformer):
        super().__init__()
        clip = sentence_transformer[0].model
        self.vision_model = clip.vision_model
        self.visual_projection = clip.visual_projection

    def forward(self, pixel_values):
        pooled = self.vision_model(pixel_values=pixel_values, return_dict=False)[1]
        return self.visual_projection(pooled)


class TextEncoder(nn.Module):
    def __init__(self, sentence_transformer):
        super().__init__()
        self.transformer = sentence_transformer[0].auto_model
        self.linear = sentence_transformer[2].linear

    def forward(self, input_ids, attention_mask):
        # Public TorchScript/Core ML inputs are int32; embedding lookup uses long.
        ids = input_ids.to(dtype=torch.long)
        mask = attention_mask.to(dtype=torch.long)
        hidden = self.transformer(input_ids=ids, attention_mask=mask, return_dict=False)[0]
        expanded = mask.unsqueeze(-1).expand(hidden.size()).to(dtype=hidden.dtype)
        mean = (hidden * expanded).sum(dim=1) / expanded.sum(dim=1).clamp(min=1e-9)
        return self.linear(mean)