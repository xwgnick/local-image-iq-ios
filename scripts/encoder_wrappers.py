"""Raw SigLIP 2 pooled features; no scoring or output L2 normalization."""

import torch
from torch import nn


class ImageEncoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.vision_model = model.vision_model

    def forward(self, pixel_values):
        # Keep the complete learned attention pooling head from the checkpoint.
        return self.vision_model(pixel_values=pixel_values, return_dict=True).pooler_output


class TextEncoder(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.text_model = model.text_model

    def forward(self, input_ids):
        # Public TorchScript/Core ML inputs are int32; embedding lookup uses long.
        ids = input_ids.to(dtype=torch.long)
        # No mask, EOS search, masked mean, or new projection. HF pools position 63
        # (including PAD there for short queries) then applies its learned head.
        return self.text_model(input_ids=ids, return_dict=True).pooler_output