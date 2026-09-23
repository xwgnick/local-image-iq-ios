#!/usr/bin/env python3
"""Explicit macOS-only FP32 export and measured parity; no import-time execution.

Default: one cached pinned public snapshot only. --download explicitly permits
fetching that revision. All reference inputs are generated, never user photos or GPS.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from importlib import metadata
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import tempfile

from model_contract import (
    DIMENSION, FEATURES, IMAGE_MODEL, MAX_ABS_LIMITS, MEAN, PREPROCESS, ROOT,
    SCHEMA_VERSION, SEQUENCE_LENGTH, STD, TEXT_MODEL, TOKENIZER_FILES, VOCAB_SIZE,
    base_manifest, model_version, query_cases, require, sha256_file,
    validate_document, validate_snapshot_configs, validate_tokenization, write_json,
)

# One shared checkpoint and one weight file; never download/hash it twice by role.
# The standard fast-tokenizer JSON avoids the slow SentencePiece conversion path.
SNAPSHOT_FILES = [
    "config.json", "preprocessor_config.json", "model.safetensors", *TOKENIZER_FILES,
    "README.md", "LICENSE*", "NOTICE*",
]
OWNED_OUTPUTS = (
    "ImageEncoder.mlpackage", "TextEncoder.mlpackage", *TOKENIZER_FILES,
    "tokenizer-parity.json", "image-preprocess-parity.json", "parity-report.json",
    "provenance.json", "licenses", "fixtures",
)
# Cleanup only; never publish or require this obsolete exporter-owned artifact.
RETIRED_OUTPUTS = ("vocab.txt",)
TOKENIZER_OPTIONS = {"padding": "max_length", "truncation": True, "max_length": SEQUENCE_LENGTH,
                     "add_special_tokens": True, "return_attention_mask": True,
                     "return_token_type_ids": False}


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true",
                        help="Explicitly fetch only the pinned public shared checkpoint; no token")
    parser.add_argument("--output", type=Path, default=ROOT / "Resources" / "Models")
    parser.add_argument("--min-cosine", type=float, default=0.999,
                        help="Each raw-vector comparison must exceed this cosine (FP32 floor .999)")
    parser.add_argument("--conversion-max-abs", type=float, default=1e-3,
                        help="Maximum per-component error for saved Core ML vs eager Torch")
    parser.add_argument("--torch-max-abs", type=float, default=1e-5,
                        help="Maximum raw error for HF reference vs wrapper and eager vs trace")
    parser.add_argument("--similarity-max-abs", type=float, default=1e-4,
                        help="Maximum text/image cosine matrix difference vs HF reference")
    parser.add_argument("--preprocess-max-abs", type=float, default=1e-6,
                        help="Maximum independent PIL/NumPy vs HF preprocessing error")
    args = parser.parse_args(argv)
    if not math.isfinite(args.min_cosine) or not 0.999 <= args.min_cosine < 1:
        parser.error("--min-cosine must be finite and in [0.999, 1); the comparison is strict >")
    for name, ceiling in MAX_ABS_LIMITS.items():
        if not math.isfinite(getattr(args, name)) or not 0 < getattr(args, name) <= ceiling:
            parser.error(f"--{name.replace('_', '-')} must be finite, positive and <= {ceiling}")
    return args


def check_environment() -> dict:
    require(platform.system() == "Darwin", "Core ML prediction parity requires macOS; no export-only bypass")
    require(platform.machine() == "arm64", "This torch 2.5.1 wheel environment requires native Apple Silicon")
    require(sys.version_info[:2] == (3, 11), "Use the pinned native CPython 3.11 environment")
    require(int(platform.mac_ver()[0].split(".")[0]) >= 14, "macOS 14+ required")
    versions = {}
    for line in (Path(__file__).parent / "requirements-coreml.txt").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, expected = line.strip().split("==")
        actual = metadata.version(name)
        require(actual == expected, f"{name}: expected {expected}, installed {actual}")
        versions[name] = actual
    return {"python": platform.python_version(), "macOS": platform.mac_ver()[0],
            "machine": platform.machine(), "packages": versions}


def snapshots(download: bool) -> Path:
    # Set BEFORE importing Hugging Face; never use a cached private credential.
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
    if not download:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
    from huggingface_hub import snapshot_download

    require(IMAGE_MODEL == TEXT_MODEL, "Both encoders must use the same pinned checkpoint")
    path = Path(snapshot_download(repo_id=IMAGE_MODEL["id"], revision=IMAGE_MODEL["revision"], token=False,
                                  local_files_only=not download, allow_patterns=SNAPSHOT_FILES))
    require(path.name == IMAGE_MODEL["revision"], "Unexpected resolved shared snapshot revision")
    for relative in SNAPSHOT_FILES:
        # Model cards/license files are evidence if present, not invented prerequisites.
        if "*" not in relative and relative != "README.md":
            require((path / relative).is_file(), f"Incomplete pinned shared cache: {relative}")
    return path


def source_provenance(stage: Path, path: Path, configs: dict, environment: dict) -> dict:
    selected = sorted({file for pattern in SNAPSHOT_FILES for file in path.glob(pattern) if file.is_file()})
    # Exactly one streaming source hash per selected file, including the shared weights.
    hashes = {file.relative_to(path).as_posix(): sha256_file(file) for file in selected}
    evidence = []
    declared_license = None
    for file in selected:
        if file.name == "README.md" or file.name.upper().startswith(("LICENSE", "NOTICE")):
            target = stage / "licenses" / "shared" / file.relative_to(path)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(file, target)
            evidence.append(target.relative_to(stage).as_posix())
            if file.name == "README.md":
                card = file.read_text(encoding="utf-8")
                # Report card declarations as declarations, NOT legal conclusions.
                frontmatter = re.match(r"\A---\s*\n(.*?)\n---", card, re.DOTALL)
                if frontmatter:
                    match = re.search(r"^license:\s*([^\r\n]+)$", frontmatter.group(1), re.MULTILINE)
                    if match:
                        declared_license = match.group(1).strip().strip("\"'")
    (stage / "licenses" / "shared").mkdir(parents=True, exist_ok=True)
    sources = {"shared": {**IMAGE_MODEL, "roles": ["image", "text"], "sha256": hashes,
                          "licenseEvidence": evidence, "modelCardDeclaredLicense": declared_license,
                          "redistributionApproved": False,
                          "licenseStatus": "manual review required; missing/unknown terms are not permission"}}
    script_files = sorted(Path(__file__).parent.glob("*.py")) + [Path(__file__).parent / "requirements-coreml.txt"]
    result = {
        "schemaVersion": SCHEMA_VERSION, "modelVersion": model_version(),
        "createdUTC": datetime.now(timezone.utc).isoformat(), "environment": environment,
        "sources": sources, "validatedConfigs": configs,
        "implementationContractSHA256": sha256_file(ROOT / "docs" / "IMPLEMENTATION_CONTRACT.md"),
        "exportSourceSHA256": {p.name: sha256_file(p) for p in script_files},
        "precision": "float32", "computeUnits": "CPU_ONLY", "attentionImplementation": "eager",
        "training": False, "inputs": "procedural RGB patterns and fixed synthetic queries only",
        "redistributionApproved": False,
    }
    write_json(stage / "provenance.json", result)
    write_json(stage / "licenses" / "review-required.json", {
        "schemaVersion": SCHEMA_VERSION, "modelVersion": model_version(),
        "redistributionApproved": False,
        "note": "The public SigLIP 2 model card declares Apache-2.0; preserve actual evidence and review "
                "checkpoint/tokenizer, upstream model/data obligations and dependency licenses. "
                "Do not publish packages or unknown-license material based on this numerical export.",
        "sources": {role: {k: v for k, v in entry.items() if k != "sha256"}
                    for role, entry in sources.items()},
    })
    return result


def load_pair(snapshot: Path, configs: dict):
    import numpy as np
    import torch
    from transformers import AutoTokenizer, GemmaTokenizerFast, SiglipConfig, SiglipImageProcessor, SiglipModel

    local = {"local_files_only": True, "trust_remote_code": False, "token": False}
    config = SiglipConfig.from_pretrained(str(snapshot), **local)
    # Check resolved library defaults BEFORE allocating/loading the shared weights.
    for role, expected in (("vision", configs["effectiveVisionArchitecture"]),
                           ("text", configs["effectiveTextArchitecture"])):
        effective = getattr(config, f"{role}_config")
        for key, value in expected.items():
            # vision_use_head is optional in 4.48.3; absent means True in its forward.
            actual = getattr(effective, key, True if key == "vision_use_head" else None)
            require(actual == value, f"Effective Siglip {role} {key} changed")
    model, loading = SiglipModel.from_pretrained(
        str(snapshot), config=config, attn_implementation="eager", torch_dtype=torch.float32,
        use_safetensors=True, output_loading_info=True, **local)
    for key in ("missing_keys", "unexpected_keys", "mismatched_keys", "error_msgs"):
        require(not loading.get(key), f"Checkpoint loading mismatch: {key}: {loading.get(key)}")
    model.eval().float().cpu().requires_grad_(False)
    require(isinstance(model, SiglipModel), "Expected built-in transformers.SiglipModel")
    for tower in (model.vision_model, model.text_model):
        require(tower.config._attn_implementation == "eager", "Siglip tower is not eager")
    require(not any("sdpa" in type(m).__name__.lower() or "flash" in type(m).__name__.lower()
                    for m in model.modules()), "Fused attention cannot be traced in this exporter")
    require(model.vision_model.use_head, "Missing learned vision pooling head")
    require(model.text_model.head.in_features == DIMENSION and
            model.text_model.head.out_features == DIMENSION, "Text pooling head width changed")
    processor = SiglipImageProcessor.from_pretrained(str(snapshot), **local)
    require(processor.size == {"height": 224, "width": 224}, "Effective Siglip warp size changed")
    require(processor.do_resize and processor.do_normalize and processor.do_rescale and
            int(processor.resample) == 2 and not getattr(processor, "do_center_crop", False),
            "Effective Siglip preprocessing changed")
    require(np.array_equal(processor.image_mean, MEAN) and np.array_equal(processor.image_std, STD) and
            processor.rescale_factor == 1 / 255, "Effective Siglip normalization changed")
    fast = AutoTokenizer.from_pretrained(str(snapshot), use_fast=True, **local)
    require(isinstance(fast, GemmaTokenizerFast) and fast.is_fast, "Expected built-in GemmaTokenizerFast")
    require(fast.add_bos_token is False and fast.add_eos_token is True and
            fast.num_special_tokens_to_add(pair=False) == 1, "Expected EOS only, no automatic BOS")
    require((fast.pad_token_id, fast.eos_token_id, fast.bos_token_id, fast.unk_token_id) == (0, 1, 2, 3),
            "Effective Gemma special token IDs changed")
    require(fast.padding_side == fast.truncation_side == "right", "Tokenization side changed")
    require(fast.model_input_names == ["input_ids"] and len(fast) == VOCAB_SIZE,
            "Effective Gemma vocabulary/model inputs changed")
    backend = json.loads(fast.backend_tokenizer.to_str())
    require(backend["model"]["type"] == "BPE" and backend["model"].get("byte_fallback") is True,
            "Expected Gemma BPE with byte fallback")
    return model, processor, fast


def tokenize_query(fast, text: str) -> dict:
    # GemmaTokenizerFast 4.48.3 does not implement do_lower_case itself.
    # Do not strip, casefold, normalize Unicode or remove literal special tokens.
    encoded = fast(text.lower(), **TOKENIZER_OPTIONS)
    validate_tokenization(encoded)
    return encoded


def tokenizer_cases(stage: Path, snapshot: Path, fast) -> list[dict]:
    import numpy as np
    from transformers import AutoTokenizer

    for name in TOKENIZER_FILES:
        shutil.copyfile(snapshot / name, stage / name)
    # Prove that the two bundled runtime JSONs suffice, without tokenizer.model
    # or special_tokens_map.json. No second model/weight load is performed.
    bundled = AutoTokenizer.from_pretrained(str(stage), use_fast=True, local_files_only=True,
                                            trust_remote_code=False, token=False)
    result = []
    for case in query_cases():
        encoded = tokenize_query(fast, case["text"])
        copied = tokenize_query(bundled, case["text"])
        require(all(encoded[name] == copied[name] for name in ("input_ids", "attention_mask")),
                f"Bundled tokenizer differs from pinned reference: {case['id']}")
        if case["id"] == "empty":
            require(encoded["input_ids"] == [1] + [0] * 63, "Empty query must be EOS then PAD")
        if case["id"] == "long-truncation":
            require(sum(encoded["attention_mask"]) == SEQUENCE_LENGTH, "Fixture did not exercise truncation")
        result.append({
            "metadata": {**case, "lowercasedText": case["text"].lower(),
                         "inputIDs": encoded["input_ids"], "attentionMask": encoded["attention_mask"]},
            "input_ids": np.asarray([encoded["input_ids"]], dtype=np.int32),
        })
    return result


def raw_vector(array, label: str):
    import numpy as np

    result = np.asarray(array)
    require(result.shape == (1, DIMENSION) and result.dtype == np.float32,
            f"{label}: expected float32 [1,{DIMENSION}]")
    require(bool(np.isfinite(result).all()), f"{label}: non-finite output")
    require(float(np.linalg.norm(result.astype(np.float64))) > 0, f"{label}: zero vector")
    return result


def compare(reference, candidate, label: str, max_abs: float, min_cosine: float) -> dict:
    import numpy as np

    left = raw_vector(reference, label).astype(np.float64).ravel()
    right = raw_vector(candidate, label).astype(np.float64).ravel()
    left_norm, right_norm = float(np.linalg.norm(left)), float(np.linalg.norm(right))
    cosine = float(np.dot(left, right) / (left_norm * right_norm))
    error = float(np.max(np.abs(left - right)))
    measured = {"maxAbs": error, "cosine": cosine,
                "referenceNorm": left_norm, "candidateNorm": right_norm}
    print(f"{label}: maxAbs={error:.8g}, cosine={cosine:.10f}", flush=True)
    require(error <= max_abs and cosine > min_cosine,
            f"{label}: parity failed {measured}; required maxAbs <= {max_abs}, cosine > {min_cosine}")
    return measured


def validate_coreml_spec(model, role: str) -> None:
    from coremltools.proto import FeatureTypes_pb2

    spec = model.get_spec()
    require(spec.WhichOneof("Type") == "mlProgram", "Expected an ML Program")
    dtypes = {"float32": FeatureTypes_pb2.ArrayFeatureType.FLOAT32,
              "int32": FeatureTypes_pb2.ArrayFeatureType.INT32}
    for descriptions, expected in ((spec.description.input, FEATURES[role]),
                                    (spec.description.output, FEATURES["output"])):
        require([item.name for item in descriptions] == list(expected), f"{role}: feature names/order changed")
        for item in descriptions:
            wanted = expected[item.name]
            require(item.type.WhichOneof("Type") == "multiArrayType", "Expected MLMultiArray")
            array = item.type.multiArrayType
            require(list(array.shape) == wanted["shape"] and array.dataType == dtypes[wanted["dtype"]],
                    f"{role}: shape/dtype mismatch for {item.name}")
            require(not array.HasField("shapeRange") and not array.HasField("enumeratedShapes"),
                    "Only fixed-batch fixed-shape tensors are allowed")


def convert_and_reload(traced, role: str, stage: Path):
    import coremltools as ct
    import numpy as np

    inputs = [ct.TensorType(name=name, shape=spec["shape"],
                            dtype=np.float32 if spec["dtype"] == "float32" else np.int32)
              for name, spec in FEATURES[role].items()]
    model = ct.convert(traced, source="pytorch", convert_to="mlprogram", inputs=inputs,
                       outputs=[ct.TensorType(name="output_embedding", dtype=np.float32)],
                       compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY,
                       minimum_deployment_target=ct.target.iOS17)
    model.short_description = f"Pinned SigLIP 2 {role} encoder; raw 768D, no L2 normalization or logits"
    model.user_defined_metadata["modelVersion"] = model_version()
    model.user_defined_metadata["sourceModelID"] = (IMAGE_MODEL if role == "image" else TEXT_MODEL)["id"]
    model.user_defined_metadata["sourceRevision"] = (IMAGE_MODEL if role == "image" else TEXT_MODEL)["revision"]
    model.user_defined_metadata["precision"] = "float32"
    model.user_defined_metadata["licenseStatus"] = "manual review required; see provenance.json"
    validate_coreml_spec(model, role)
    path = stage / ("ImageEncoder.mlpackage" if role == "image" else "TextEncoder.mlpackage")
    model.save(str(path))
    del model
    reloaded = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
    validate_coreml_spec(reloaded, role)
    return reloaded


def trace_wrapper(wrapper, inputs: tuple, additional_inputs: tuple):
    import torch

    wrapper.eval().float().cpu()
    with torch.inference_mode():
        traced = torch.jit.trace(wrapper, inputs, strict=True, check_trace=True,
                                 check_inputs=[additional_inputs])
    graph = str(traced.inlined_graph).lower()
    require(not any(name in graph for name in ("scaled_dot_product", "flash_attention", "efficient_attention")),
            "Trace contains fused attention; eager attention was not actually used")
    return traced.eval()


def cosine_matrix(text_vectors, image_vectors):
    import numpy as np

    texts = np.concatenate(text_vectors, axis=0).astype(np.float64)
    images = np.concatenate(image_vectors, axis=0).astype(np.float64)
    # Normalization ONLY for comparison, never in exported models/raw fixtures.
    return (texts / np.linalg.norm(texts, axis=1, keepdims=True)) @ (
        images / np.linalg.norm(images, axis=1, keepdims=True)).T


def export_pair(stage: Path, args: argparse.Namespace, environment: dict) -> None:
    snapshot = snapshots(args.download)
    configs = validate_snapshot_configs(snapshot)
    provenance = source_provenance(stage, snapshot, configs, environment)

    import numpy as np
    import torch
    from encoder_wrappers import ImageEncoder, TextEncoder
    from synthetic_fixtures import image_cases

    model, processor, fast = load_pair(snapshot, configs)
    images = image_cases(stage, processor, args.preprocess_max_abs)
    queries = tokenizer_cases(stage, snapshot, fast)
    image_wrapper, text_wrapper = ImageEncoder(model), TextEncoder(model)
    image_inputs = [(torch.from_numpy(case["pixels"]),) for case in images]
    text_inputs = [(torch.from_numpy(case["input_ids"]),) for case in queries]
    image_trace = trace_wrapper(image_wrapper, image_inputs[0], image_inputs[1])
    truncation_index = next(i for i, case in enumerate(queries) if case["metadata"]["id"] == "long-truncation")
    text_trace = trace_wrapper(text_wrapper, text_inputs[0], text_inputs[truncation_index])
    converted_image = convert_and_reload(image_trace, "image", stage)
    converted_text = convert_and_reload(text_trace, "text", stage)
    report = {"schemaVersion": SCHEMA_VERSION, "modelVersion": model_version(), "precision": "float32",
              "computeUnits": "CPU_ONLY", "thresholds": {
                  "minCosineExclusive": args.min_cosine, "conversionMaxAbsInclusive": args.conversion_max_abs,
                  "torchMaxAbsInclusive": args.torch_max_abs, "similarityMaxAbsInclusive": args.similarity_max_abs,
                  "preprocessMaxAbsInclusive": args.preprocess_max_abs},
              "cases": [], "nativeTokenizerParity": "not-run", "nativeImagePreprocessParity": "not-run",
              "nativeModelRuntimeParity": "not-run", "semanticRetrievalQuality": "not-evaluated"}
    originals, predictions = {"image": [], "text": []}, {"image": [], "text": []}
    with torch.inference_mode():
        for role, cases, inputs, wrapper, traced, coreml in (
            ("image", images, image_inputs, image_wrapper, image_trace, converted_image),
            ("text", queries, text_inputs, text_wrapper, text_trace, converted_text),
        ):
            for case, tensors in zip(cases, inputs):
                name = case["metadata"]["id"]
                # Transformers 4.48.3 get_*_features returns a raw Tensor, NOT
                # a ModelOutput or normalized paired-forward embedding.
                reference_tensor = (model.get_image_features(pixel_values=tensors[0]) if role == "image"
                                    else model.get_text_features(input_ids=tensors[0].to(dtype=torch.long)))
                reference_raw = raw_vector(reference_tensor.detach().cpu().numpy(), f"{role}/{name}/reference")
                wrapped_raw = raw_vector(wrapper(*tensors).detach().cpu().numpy(), "wrapper")
                traced_raw = raw_vector(traced(*tensors).detach().cpu().numpy(), "trace")
                feed = ({"pixel_values": case["pixels"]} if role == "image" else
                        {"input_ids": case["input_ids"]})
                cm_raw = raw_vector(coreml.predict(feed)["output_embedding"], "saved Core ML")
                stages = {}
                for label, left, right, tolerance in (
                    ("referenceVsWrapper", reference_raw, wrapped_raw, args.torch_max_abs),
                    ("wrapperVsTrace", wrapped_raw, traced_raw, args.torch_max_abs),
                    ("traceVsCoreML", traced_raw, cm_raw, args.conversion_max_abs),
                    ("referenceVsCoreML", reference_raw, cm_raw, args.conversion_max_abs),
                ):
                    stages[label] = compare(left, right, f"{role}/{name}/{label}", tolerance, args.min_cosine)
                report["cases"].append({"role": role, "id": name, "comparisons": stages})
                case["metadata"]["referenceRaw"] = reference_raw[0].tolist()
                case["metadata"]["coreMLRaw"] = cm_raw[0].tolist()
                originals[role].append(reference_raw)
                predictions[role].append(cm_raw)
    reference = cosine_matrix(originals["text"], originals["image"])
    converted = cosine_matrix(predictions["text"], predictions["image"])
    delta = float(np.max(np.abs(reference - converted)))
    require(delta <= args.similarity_max_abs, f"Paired text/image cosine matrix differs by {delta}")
    report["pairedCosines"] = {
        "queryIDs": [c["metadata"]["id"] for c in queries],
        "imageIDs": [c["metadata"]["id"] for c in images],
        "reference": reference.tolist(), "coreML": converted.tolist(), "maxAbs": delta,
    }
    report["passed"] = True
    write_json(stage / "parity-report.json", report)
    shared = {"schemaVersion": SCHEMA_VERSION, "modelVersion": model_version(),
              "embeddingDimension": DIMENSION, "embeddingsAreRaw": True}
    source_hashes = provenance["sources"]["shared"]["sha256"]
    write_json(stage / "tokenizer-parity.json", {
        **shared, "sequenceLength": SEQUENCE_LENGTH, "textModel": TEXT_MODEL,
        "tokenizerFile": TOKENIZER_FILES[0], "tokenizerConfigFile": TOKENIZER_FILES[1],
        "tokenizerSHA256": source_hashes[TOKENIZER_FILES[0]],
        "configSHA256": source_hashes[TOKENIZER_FILES[1]],
        "reference": "explicit str.lower then pinned HF GemmaTokenizerFast; bundled JSON reload checked",
        "tokenizerClass": type(fast).__name__, "tokenizerOptions": TOKENIZER_OPTIONS,
        "preprocessing": PREPROCESS["text"],
        "backendNormalizer": json.loads(fast.backend_tokenizer.to_str())["normalizer"],
        "nativeParity": "not-run", "cases": [c["metadata"] for c in queries],
    })
    write_json(stage / "image-preprocess-parity.json", {
        **shared, "imageModel": IMAGE_MODEL, "preprocessing": PREPROCESS["image"],
        "reference": "HF processor checked against independent Pillow/NumPy implementation",
        "nativeParity": "not-run", "cases": [c["metadata"] for c in images],
    })
    artifact_hashes = {p.relative_to(stage).as_posix(): sha256_file(p)
                       for p in sorted(stage.rglob("*")) if p.is_file()}
    for name in TOKENIZER_FILES:
        require(artifact_hashes[name] == source_hashes[name],
                f"Bundled tokenizer bytes differ from the pinned source: {name}")
    manifest = base_manifest()
    manifest.update({
        "parity": {"status": "passed", "report": "parity-report.json", "precision": "float32",
                   "computeUnits": "CPU_ONLY", "nativeTokenizer": "not-run",
                   "nativePreprocessing": "not-run", "nativeRuntime": "not-run"},
        "provenance": "provenance.json", "redistributionApproved": False,
        "artifactsSHA256": artifact_hashes,
    })
    # Not yet public: this file remains inside the staging directory until commit.
    write_json(stage / "model-manifest.json", manifest)


def publish(stage: Path, output: Path) -> None:
    """Commit marker last; only replace exporter-owned resources, not README/Places."""
    (output / "model-manifest.json").unlink(missing_ok=True)
    for name in RETIRED_OUTPUTS:
        (output / name).unlink(missing_ok=True)
    for name in OWNED_OUTPUTS:
        target = output / name
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
        os.replace(stage / name, target)
    os.replace(stage / "model-manifest.json", output / "model-manifest.json")


def main(argv: list[str] | None = None) -> None:
    args = arguments(argv)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Invalidate BEFORE validation/download/conversion. A failed rerun must not
    # leave an earlier manifest looking like this export passed.
    (output / "model-manifest.json").unlink(missing_ok=True)
    try:
        validate_document()
        environment = check_environment()
        with tempfile.TemporaryDirectory(prefix=".coreml-stage-", dir=output.parent) as temporary:
            stage = Path(temporary)
            export_pair(stage, args, environment)
            publish(stage, output)
    except BaseException:
        (output / "model-manifest.json").unlink(missing_ok=True)
        print("Export did not complete. No valid manifest was published; any old packages are stale.",
              file=sys.stderr)
        raise
    print(f"Published {model_version()} to {output}; native Swift gates and license review remain pending.")


if __name__ == "__main__":
    main()