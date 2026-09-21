"""Procedural public test patterns only; never accepts a photo or GPS input."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

from model_contract import IMAGE_SIZE, MEAN, STD, require, sha256_file


def pillow_pixels(image: Image.Image) -> tuple[np.ndarray, dict]:
    """Independent PIL/NumPy reference, checked against the pinned HF processor."""
    rgb = ImageOps.exif_transpose(image).convert("RGB")
    width, height = rgb.size
    if width <= height:
        resized = (IMAGE_SIZE, int(IMAGE_SIZE * height / width))
    else:
        resized = (int(IMAGE_SIZE * width / height), IMAGE_SIZE)
    rgb = rgb.resize(resized, resample=Image.Resampling.BICUBIC)
    left, top = (resized[0] - IMAGE_SIZE) // 2, (resized[1] - IMAGE_SIZE) // 2
    rgb = rgb.crop((left, top, left + IMAGE_SIZE, top + IMAGE_SIZE))
    # HF rescales with NumPy then casts to float32 before normalization.
    scaled = (np.asarray(rgb).astype(np.float64) / 255.0).astype(np.float32)
    pixels = ((scaled - np.asarray(MEAN, dtype=np.float32)) /
              np.asarray(STD, dtype=np.float32)).transpose(2, 0, 1)[None]
    return np.ascontiguousarray(pixels), {
        "orientedSize": [width, height], "resizedSize": list(resized),
        "cropXYWH": [left, top, IMAGE_SIZE, IMAGE_SIZE],
    }


def pattern(width: int, height: int, checker: bool) -> Image.Image:
    y, x = np.indices((height, width))
    if checker:
        tiles = ((x // 13 + y // 17) % 2).astype(bool)
        array = np.where(tiles[..., None], [240, 20, 45], [15, 190, 225])
    else:
        # Asymmetric quadrants and gradients expose rotations AND mirroring.
        array = np.stack(((x * 3 + y) % 256, (y * 5) % 256,
                          np.where((x < width // 3) & (y < height // 2), 250, 30)), axis=-1)
    return Image.fromarray(array.astype(np.uint8), mode="RGB")


def image_cases(stage: Path, processor, max_abs: float) -> list[dict]:
    directory = stage / "fixtures"
    directory.mkdir()
    sources = [
        ("solid-rgb", Image.new("RGB", (224, 224), (31, 127, 223)), 1),
        ("checker-nonsquare", pattern(319, 231, True), 1),
        ("exif-rotate-6", pattern(321, 197, False), 6),
        ("exif-mirror-2", pattern(197, 321, False), 2),
    ]
    result = []
    for name, source, orientation in sources:
        path = directory / f"{name}.png"
        exif = Image.Exif()
        exif[274] = orientation
        source.save(path, format="PNG", exif=exif)
        with Image.open(path) as reopened:
            require(reopened.getexif().get(274) == orientation, "PNG EXIF did not round-trip")
            oriented = ImageOps.exif_transpose(reopened).convert("RGB")
            independent, geometry = pillow_pixels(reopened)
        # The model's real processor is the authoritative Python target.
        pixels = processor(images=[oriented], return_tensors="np")["pixel_values"]
        require(pixels.shape == (1, 3, 224, 224) and pixels.dtype == np.float32,
                "HF image processor shape/dtype differs from contract")
        delta = float(np.max(np.abs(independent.astype(np.float64) - pixels)))
        require(delta <= max_abs, f"Independent PIL/HF preprocessing mismatch: {name}: {delta}")
        tensor_path = directory / f"{name}.f32le"
        # Full fixture tensor: 602,112 bytes, no enormous JSON float lists.
        tensor_path.write_bytes(pixels.astype("<f4").tobytes(order="C"))
        coordinates = [(0, 0), (0, 223), (111, 111), (112, 112), (223, 0), (223, 223)]
        spots = [{"channel": c, "y": y, "x": x, "value": float(pixels[0, c, y, x])}
                 for c in range(3) for y, x in coordinates]
        metadata = {
            "id": name, "image": path.relative_to(stage).as_posix(),
            "imageSHA256": sha256_file(path), "sourceSize": list(source.size),
            "exifOrientation": orientation, **geometry,
            "tensor": tensor_path.relative_to(stage).as_posix(),
            "tensorSHA256": sha256_file(tensor_path), "tensorBytes": tensor_path.stat().st_size,
            "dtype": "float32-little-endian", "shape": [1, 3, 224, 224], "layout": "NCHW",
            "spotChecks": spots, "pillowVsHFMaxAbs": delta,
        }
        result.append({"metadata": metadata, "image": oriented, "pixels": pixels})
    return result