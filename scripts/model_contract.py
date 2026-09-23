"""Dependency-free, versioned export contract. No model loading or network I/O."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGE_MODEL = {
    "id": "google/siglip2-base-patch16-224",
    "revision": "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2",
}
TEXT_MODEL = dict(IMAGE_MODEL)
SCHEMA_VERSION = 2
DIMENSION = 768
SEQUENCE_LENGTH = 64
IMAGE_SIZE = 224
VOCAB_SIZE = 256000
TOKENIZER_FILES = ("tokenizer.json", "tokenizer_config.json")
MEAN = [0.5, 0.5, 0.5]
STD = [0.5, 0.5, 0.5]
# CLI overrides may tighten, never weaken these numerical acceptance gates.
MAX_ABS_LIMITS = {"conversion_max_abs": 1e-3, "torch_max_abs": 1e-5,
                  "similarity_max_abs": 1e-4, "preprocess_max_abs": 1e-6}
FEATURES = {
    "image": {"pixel_values": {"dtype": "float32", "shape": [1, 3, 224, 224]}},
    "text": {"input_ids": {"dtype": "int32", "shape": [1, 64]}},
    "output": {"output_embedding": {"dtype": "float32", "shape": [1, 768]}},
}
PREPROCESS = {
    "image": {
        "orientation": "apply EXIF before RGB conversion",
        "color": "RGB",
        "resize": "warp directly to 224x224; do not preserve aspect ratio",
        "interpolationReference": "Pillow 11.1.0 BILINEAR",
        "resample": 2,
        "crop": "none; cropXYWH [0,0,224,224] describes the full resized image",
        "rescale": 1.0 / 255.0,
        "mean": MEAN,
        "std": STD,
        "layout": "NCHW",
        "pooling": "vision_model.pooler_output including learned attention pooling head",
    },
    "text": {
        "algorithm": "GemmaTokenizerFast; pinned Hugging Face tokenizer.json BPE with byte fallback",
        "tokenizerFile": TOKENIZER_FILES[0],
        "tokenizerConfigFile": TOKENIZER_FILES[1],
        "doLowerCase": True,
        "lowercase": "explicit Python str.lower before HF tokenization; not casefold or locale-sensitive",
        "normalization": "after lowercasing use the pinned tokenizer.json normalizer unchanged",
        "specialTokens": {"pad": {"token": "<pad>", "id": 0},
                          "eos": {"token": "<eos>", "id": 1},
                          "bos": {"token": "<bos>", "id": 2},
                          "unk": {"token": "<unk>", "id": 3}},
        "addBOSToken": False,
        "addEOSToken": True,
        "sequenceLength": 64,
        "truncation": "right; at most 63 content tokens plus one appended EOS (id 1)",
        "padding": "right to 64 with PAD (id 0)",
        "attentionMask": "fixture checks only; never a model input",
        "pooling": "text_model.pooler_output: final sequence position then learned head; no mask",
    },
    "outputNormalization": "none; raw pooler_output; Swift L2-normalizes each encoder output once",
    "outputScoring": "no sigmoid, logit scale, logit bias or paired forward in either encoder",
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
    return "siglip2-b16-224-v1-" + hashlib.sha256(canonical_json(identity)).hexdigest()


def base_manifest() -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "modelVersion": model_version(),
        "dimension": DIMENSION,
        "sequenceLength": SEQUENCE_LENGTH,
        "imageSize": IMAGE_SIZE,
        "imageModel": dict(IMAGE_MODEL),
        "textModel": dict(TEXT_MODEL),
        "imageInput": "pixel_values",
        "textInputs": ["input_ids"],
        "output": "output_embedding",
        "tokenizerFile": TOKENIZER_FILES[0],
        "tokenizerConfigFile": TOKENIZER_FILES[1],
        "features": FEATURES,
        "preprocessing": PREPROCESS,
    }


def validate_document(path: Path = ROOT / "docs" / "IMPLEMENTATION_CONTRACT.md") -> None:
    """Drift alarm for the shared prose, not a general Markdown/schema parser."""
    text = path.read_text(encoding="utf-8")
    required = [
        IMAGE_MODEL["id"], IMAGE_MODEL["revision"], TEXT_MODEL["id"], TEXT_MODEL["revision"],
        "`pixel_values`: Float32 `[1,3,224,224]`",
        "`input_ids`: Int32 `[1,64]`",
        "`output_embedding`: Float32 `[1,768]`", "**raw pooler_output**",
        "[0.5,0.5,0.5]", "BILINEAR", "resample=2", "warp directly to 224x224",
        "explicit Python `str.lower()`", "63 content tokens", "no automatic BOS",
        "`schemaVersion:2`", "`dimension:768`", "`sequenceLength:64`", "`imageSize:224`",
        '`textInputs:["input_ids"]`', "`siglip2-b16-224-v1-`", *TOKENIZER_FILES,
        "`tokenizerSHA256`", "`configSHA256`", "`referenceRaw`", "`coreMLRaw`",
        "`referenceVsWrapper`", "`referenceVsCoreML`", "`reference`",
        "maxAbs <= 1e-3", "cosine > 0.999", "maxAbs <= 1e-4",
    ]
    for fragment in required:
        require(fragment in text, f"Shared contract changed or is incomplete: {fragment}")


def validate_snapshot_configs(snapshot: Path) -> dict:
    """Inspect the shared public checkpoint before loading weights or custom code.

    The snapshot stores sparse configs; omitted architectural values below are
    SiglipConfig defaults in pinned Transformers 4.48.3, checked again at load.
    Token IDs are authoritative in the tokenizer, NOT legacy SiglipTextConfig defaults.
    """
    model = read_json(snapshot / "config.json")
    processor = read_json(snapshot / "preprocessor_config.json")
    tokenizer = read_json(snapshot / "tokenizer_config.json")
    for name, config in (("model", model), ("vision", model.get("vision_config", {})),
                         ("text", model.get("text_config", {})),
                         ("processor", processor), ("tokenizer", tokenizer)):
        require(not config.get("auto_map"), f"Remote code mapping is not allowed: {name}")
    require(model.get("model_type") == "siglip", "Expected built-in SiglipModel, not NaFlex/custom code")
    common = {"hidden_size": DIMENSION, "intermediate_size": 3072, "num_hidden_layers": 12,
              "num_attention_heads": 12, "hidden_act": "gelu_pytorch_tanh",
              "layer_norm_eps": 1e-6, "attention_dropout": 0.0}
    vision_expected = {**common, "image_size": IMAGE_SIZE, "patch_size": 16, "num_channels": 3,
                       "vision_use_head": True}
    text_expected = {**common, "max_position_embeddings": SEQUENCE_LENGTH}
    for role, expected in (("vision", vision_expected), ("text", text_expected)):
        config = model.get(f"{role}_config", {})
        require(config.get("model_type") == f"siglip_{role}_model", f"Unexpected {role} model type")
        for key, value in expected.items():
            require(config.get(key, value) == value, f"Siglip {role} {key} changed")
    require(model["text_config"].get("vocab_size") == VOCAB_SIZE, "Text vocabulary size changed")
    for key, expected in {"image_processor_type": "SiglipImageProcessor",
                          "size": {"height": IMAGE_SIZE, "width": IMAGE_SIZE},
                          "do_resize": True, "do_normalize": True, "do_rescale": True,
                          "resample": 2, "rescale_factor": 1 / 255,
                          "image_mean": MEAN, "image_std": STD}.items():
        require(processor.get(key) == expected, f"Pinned image processor {key} changed")
    require(not processor.get("do_center_crop", False), "Siglip image must not be center cropped")
    for key, expected in {"tokenizer_class": "GemmaTokenizer", "add_bos_token": False,
                          "add_eos_token": True, "do_lower_case": True, "padding_side": "right",
                          "model_input_names": ["input_ids"], "pad_token": "<pad>",
                          "eos_token": "<eos>", "bos_token": "<bos>", "unk_token": "<unk>"}.items():
        require(tokenizer.get(key) == expected, f"Pinned tokenizer {key} changed")
    require(tokenizer.get("truncation_side", "right") == "right", "Tokenizer truncation side changed")
    added = tokenizer.get("added_tokens_decoder", {})
    for index, token in enumerate(("<pad>", "<eos>", "<bos>", "<unk>")):
        entry = added.get(str(index), {})
        require(entry.get("content") == token and entry.get("special") is True,
                f"Tokenizer special token {index} changed")
    return {"model": model, "imageProcessor": processor, "tokenizer": tokenizer,
            "effectiveVisionArchitecture": vision_expected,
            "effectiveTextArchitecture": {**text_expected, "vocab_size": VOCAB_SIZE}}


def validate_tokenization(encoded: dict) -> None:
    """Check the HF result without rebuilding tokens or inferring masks from IDs.

    Literal <pad>/<bos>/<eos> in content are allowed; a content PAD has mask=1.
    """
    ids, mask = encoded["input_ids"], encoded["attention_mask"]
    require(len(ids) == len(mask) == SEQUENCE_LENGTH, "Tokenizer fixture not fixed length")
    require(all(type(value) is int and 0 <= value < VOCAB_SIZE for value in ids),
            "Tokenizer IDs outside the pinned vocabulary")
    require(all(type(value) is int and value in (0, 1) for value in mask), "Invalid attention mask")
    valid = sum(mask)
    require(1 <= valid <= SEQUENCE_LENGTH and mask == [1] * valid + [0] * (SEQUENCE_LENGTH - valid),
            "Expected contiguous right padding with at least one EOS")
    require(ids[valid - 1] == 1, "Missing appended EOS id 1")
    require(all(value == 0 for value in ids[valid:]), "Right padding must use PAD id 0")


def query_cases() -> list[dict]:
    return [
        {"id": "english", "text": "A red square beside a blue checkerboard."},
        {"id": "chinese", "text": "上海的蓝色天空，北京街道上的红色汽车。"},
        {"id": "case", "text": "Apple apple APPLE iPhone Straße STRASSE"},
        {"id": "diacritics", "text": "Café naïve résumé Ångström München İstanbul"},
        {"id": "combining", "text": "Cafe\u0301 nai\u0308ve A\u030Angstro\u0308m I\u0307stanbul"},
        {"id": "punctuation", "text": "Hello—world… (a/b), isn't it? ￥１２３！。"},
        {"id": "special-tokens", "text": "<eos> red <bos> <unk> <pad> <mask> blue"},
        {"id": "empty", "text": ""},
        {"id": "whitespace-controls", "text": " \tred\nblue\r\n绿色\u00a0sky\u0000 "},
        {"id": "unknown-unicode", "text": "🧩 🦄 𠀀"},
        # No application word/byte limit: the HF tokenizer owns truncation.
        {"id": "long-word", "text": "a" * 130},
        {"id": "long-truncation", "text": "red square 蓝色天空 café " * 80},
        {"id": "greek-sigma", "text": "ΟΣ ΟΣΑ Σ σ ς ΟΣ\u0301 Ελληνικά"},
        {"id": "turkish-unicode-chinese", "text": "I İ ı i I\u0307 İSTANBUL 中文大小写 Straße ẞ"},
        {"id": "gemma-turn-tokens", "text": "<start_of_turn>USER\n你好<end_of_turn><eos><bos>"},
        {"id": "literal-pad", "text": "<pad>"},
        {"id": "whitespace-only", "text": " \t\r\n\u00a0\u2003 "},
    ]