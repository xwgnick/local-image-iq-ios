"""Dependency-free, versioned export contract. No model loading or network I/O."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGE_MODEL = {
    "id": "sentence-transformers/clip-ViT-B-32",
    "revision": "327ab6726d33c0e22f920c83f2ff9e4bd38ca37f",
}
TEXT_MODEL = {
    "id": "sentence-transformers/clip-ViT-B-32-multilingual-v1",
    "revision": "58edf8cada9e398793dca955574a48cbb7f18be2",
}
DIMENSION = 512
SEQUENCE_LENGTH = 128
IMAGE_SIZE = 224
MEAN = [0.48145466, 0.4578275, 0.40821073]
STD = [0.26862954, 0.26130258, 0.27577711]
FEATURES = {
    "image": {"pixel_values": {"dtype": "float32", "shape": [1, 3, 224, 224]}},
    "text": {
        "input_ids": {"dtype": "int32", "shape": [1, 128]},
        "attention_mask": {"dtype": "int32", "shape": [1, 128]},
    },
    "output": {"output_embedding": {"dtype": "float32", "shape": [1, 512]}},
}
PREPROCESS = {
    "image": {
        "orientation": "apply EXIF before RGB conversion",
        "color": "RGB",
        "resize": "shortest side 224; other side floor(224 * long / short)",
        "interpolationReference": "Pillow 11.1.0 BICUBIC",
        "crop": "224x224 center; top/left floor((resized - 224) / 2)",
        "rescale": 1.0 / 255.0,
        "mean": MEAN,
        "std": STD,
        "layout": "NCHW",
    },
    "text": {
        "algorithm": "cased WordPiece",
        "doLowerCase": False,
        "stripAccents": False,
        "tokenizeChineseChars": True,
        "specialTokens": ["[UNK]", "[SEP]", "[PAD]", "[CLS]", "[MASK]"],
        "sequenceLength": 128,
        "truncation": "right; reserve CLS and SEP",
        "padding": "right to 128",
        "pooling": "attention-mask mean including CLS and SEP",
        "projection": "768 to 512; bias false; activation Identity",
    },
    "outputNormalization": "none; Swift L2-normalizes each encoder output once",
    "computePrecision": "float32",
}


def require(condition: bool, message: str) -> None:
    # Never use assert for export gates: python -O must not disable validation.
    if not condition:
        raise ValueError(message)


def canonical_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
                    encoding="utf-8")


def read_json(path: Path) -> dict | list:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def model_version() -> str:
    """Semantic identity only: never a timestamp, file path, or report checksum."""
    identity = {"imageModel": IMAGE_MODEL, "textModel": TEXT_MODEL,
                "features": FEATURES, "preprocessing": PREPROCESS}
    return "clip-pair-v1-" + hashlib.sha256(canonical_json(identity)).hexdigest()


def base_manifest() -> dict:
    return {
        "schemaVersion": 1,
        "modelVersion": model_version(),
        "dimension": DIMENSION,
        "sequenceLength": SEQUENCE_LENGTH,
        "imageSize": IMAGE_SIZE,
        "imageModel": dict(IMAGE_MODEL),
        "textModel": dict(TEXT_MODEL),
        "imageInput": "pixel_values",
        "textInputs": ["input_ids", "attention_mask"],
        "output": "output_embedding",
        "features": FEATURES,
        "preprocessing": PREPROCESS,
    }


def validate_document(path: Path = ROOT / "docs" / "IMPLEMENTATION_CONTRACT.md") -> None:
    """Drift alarm for the shared prose, not a general Markdown/schema parser."""
    text = path.read_text(encoding="utf-8")
    required = [
        IMAGE_MODEL["id"], IMAGE_MODEL["revision"], TEXT_MODEL["id"], TEXT_MODEL["revision"],
        "`pixel_values`: Float32 `[1,3,224,224]`",
        "`input_ids`, `attention_mask`: Int32 `[1,128]`",
        "`output_embedding`: Float32 `[1,512]`", "**raw projection**",
        "[0.48145466,0.4578275,0.40821073]", "[0.26862954,0.26130258,0.27577711]",
        "no lowercasing or accent stripping", "bias-free identity dense 768→512",
        "`schemaVersion:1`", "`sequenceLength:128`", "`imageSize:224`",
    ]
    for fragment in required:
        require(fragment in text, f"Shared contract changed or is incomplete: {fragment}")


def validate_snapshot_configs(image: Path, text: Path) -> dict:
    """Inspect metadata before loading any weights. Reject extra ST modules."""
    image_modules = [{"idx": 0, "name": "0", "path": "0_CLIPModel",
                      "type": "sentence_transformers.models.CLIPModel"}]
    text_modules = [
        {"idx": 0, "name": "0", "path": "", "type": "sentence_transformers.models.Transformer"},
        {"idx": 1, "name": "1", "path": "1_Pooling", "type": "sentence_transformers.models.Pooling"},
        {"idx": 2, "name": "2", "path": "2_Dense", "type": "sentence_transformers.models.Dense"},
    ]
    require(read_json(image / "modules.json") == image_modules, "Image module graph changed")
    require(read_json(text / "modules.json") == text_modules, "Text module graph changed")
    clip = read_json(image / "0_CLIPModel" / "config.json")
    require(clip["model_type"] == "clip" and clip["projection_dim"] == 512,
            "Expected paired CLIP projection")
    vision = clip["vision_config"]
    for key, expected in {"image_size": 224, "patch_size": 32, "hidden_size": 768}.items():
        require(vision.get(key) == expected, f"CLIP vision {key} changed")
    processor = read_json(image / "0_CLIPModel" / "preprocessor_config.json")
    for key, expected in {"crop_size": 224, "size": 224, "do_resize": True,
                          "do_center_crop": True, "do_normalize": True, "resample": 3,
                          "image_mean": MEAN, "image_std": STD}.items():
        require(processor.get(key) == expected, f"Pinned image processor {key} changed")
    require(processor.get("do_rescale", True) is True, "Image rescale disabled")
    require(processor.get("rescale_factor", 1 / 255) == 1 / 255, "Image scale changed")
    transformer = read_json(text / "config.json")
    for key, expected in {"model_type": "distilbert", "dim": 768, "vocab_size": 119547,
                          "max_position_embeddings": 512, "n_layers": 6, "n_heads": 12}.items():
        require(transformer.get(key) == expected, f"Text transformer {key} changed")
    st_config = read_json(text / "sentence_bert_config.json")
    require(st_config.get("max_seq_length") == 128 and st_config.get("do_lower_case") is False,
            "SentenceTransformer text length/casing changed")
    pooling = read_json(text / "1_Pooling" / "config.json")
    require(pooling.get("word_embedding_dimension") == 768, "Pooling width changed")
    require(pooling.get("pooling_mode_mean_tokens") is True, "Expected attention-mask mean")
    for key, value in pooling.items():
        if key.startswith("pooling_mode_") and key != "pooling_mode_mean_tokens":
            require(value is False, f"Unexpected pooling mode: {key}")
    dense = read_json(text / "2_Dense" / "config.json")
    require(dense == {"in_features": 768, "out_features": 512, "bias": False,
                      "activation_function": "torch.nn.modules.linear.Identity"},
            "Expected a bias-free linear projection with Identity activation (not identity weights)")
    tokenizer = read_json(text / "tokenizer_config.json")
    require(tokenizer.get("do_lower_case") is False, "Tokenizer must preserve case")
    require(tokenizer.get("strip_accents") in (None, False), "Tokenizer strips accents")
    require(tokenizer.get("tokenize_chinese_chars") is True, "Chinese splitting disabled")
    require(tokenizer.get("do_basic_tokenize", True) is True, "Basic tokenization disabled")
    special = read_json(text / "special_tokens_map.json")
    require(special == {"unk_token": "[UNK]", "sep_token": "[SEP]", "pad_token": "[PAD]",
                        "cls_token": "[CLS]", "mask_token": "[MASK]"}, "Special tokens changed")
    return {"imageModules": image_modules, "textModules": text_modules,
            "imageProcessor": processor, "pooling": pooling, "dense": dense,
            "tokenizer": tokenizer, "sentenceTransformer": st_config}


def query_cases() -> list[dict]:
    return [
        {"id": "english", "text": "A red square beside a blue checkerboard."},
        {"id": "chinese", "text": "上海的蓝色天空，北京街道上的红色汽车。"},
        {"id": "case", "text": "Apple apple APPLE iPhone Straße STRASSE"},
        {"id": "diacritics", "text": "Café naïve résumé Ångström München İstanbul"},
        {"id": "combining", "text": "Cafe\u0301 nai\u0308ve A\u030Angstro\u0308m I\u0307stanbul"},
        {"id": "punctuation", "text": "Hello—world… (a/b), isn't it? ￥１２３！。"},
        {"id": "special-tokens", "text": "[CLS] red [MASK] [SEP] [UNK] [PAD] blue"},
        {"id": "empty", "text": ""},
        {"id": "whitespace-controls", "text": " \tred\nblue\r\n绿色\u00a0sky\u0000 "},
        {"id": "unknown-unicode", "text": "🧩 🦄 𠀀"},
        # Exercises the WordPiece word limit, not an application query limit.
        {"id": "long-word", "text": "a" * 130},
        {"id": "long-truncation", "text": "red square 蓝色天空 café " * 80},
    ]