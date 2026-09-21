#!/usr/bin/env python3
"""Explicit macOS-only FP32 export and measured parity; no import-time execution.

Default: cached pinned public snapshots only. --download explicitly permits fetching
those two revisions. All reference inputs are generated, never user photos or GPS.
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
    FEATURES, IMAGE_MODEL, MEAN, PREPROCESS, ROOT, STD, TEXT_MODEL,
    base_manifest, model_version, query_cases, require, sha256_file,
    validate_document, validate_snapshot_configs, write_json,
)

# Only files needed by the two verified snapshot layouts, plus license evidence.
SNAPSHOT_FILES = {
    "image": [
        "modules.json", "config_sentence_transformers.json", "README.md", "LICENSE*", "NOTICE*",
        "0_CLIPModel/config.json", "0_CLIPModel/preprocessor_config.json",
        "0_CLIPModel/tokenizer_config.json", "0_CLIPModel/special_tokens_map.json",
        "0_CLIPModel/vocab.json", "0_CLIPModel/merges.txt", "0_CLIPModel/model.safetensors",
        "0_CLIPModel/LICENSE*", "0_CLIPModel/NOTICE*",
    ],
    "text": [
        "modules.json", "config_sentence_transformers.json", "README.md", "LICENSE*", "NOTICE*",
        "config.json", "sentence_bert_config.json", "model.safetensors",
        "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "vocab.txt",
        "1_Pooling/config.json", "2_Dense/config.json", "2_Dense/model.safetensors",
        "1_Pooling/LICENSE*", "2_Dense/LICENSE*", "1_Pooling/NOTICE*", "2_Dense/NOTICE*",
    ],
}
OWNED_OUTPUTS = (
    "ImageEncoder.mlpackage", "TextEncoder.mlpackage", "vocab.txt",
    "tokenizer-parity.json", "image-preprocess-parity.json", "parity-report.json",
    "provenance.json", "licenses", "fixtures",
)


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true",
                        help="Explicitly fetch only the pinned public model snapshots; no token")
    parser.add_argument("--output", type=Path, default=ROOT / "Resources" / "Models")
    parser.add_argument("--min-cosine", type=float, default=0.999,
                        help="Each raw-vector comparison must exceed this cosine (FP32 floor .999)")
    parser.add_argument("--conversion-max-abs", type=float, default=1e-3,
                        help="Maximum per-component error for saved Core ML vs eager Torch")
    parser.add_argument("--torch-max-abs", type=float, default=1e-5,
                        help="Maximum raw error for ST vs wrapper and eager vs trace")
    parser.add_argument("--similarity-max-abs", type=float, default=1e-4,
                        help="Maximum text/image cosine matrix difference vs original ST")
    parser.add_argument("--preprocess-max-abs", type=float, default=1e-6,
                        help="Maximum independent PIL/NumPy vs HF preprocessing error")
    args = parser.parse_args(argv)
    if not math.isfinite(args.min_cosine) or not 0.999 <= args.min_cosine < 1:
        parser.error("--min-cosine must be finite and in [0.999, 1); the comparison is strict >")
    for name in ("conversion_max_abs", "torch_max_abs", "similarity_max_abs", "preprocess_max_abs"):
        if not math.isfinite(getattr(args, name)) or getattr(args, name) <= 0:
            parser.error(f"--{name.replace('_', '-')} must be finite and positive")
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


def snapshots(download: bool) -> tuple[Path, Path]:
    # Set BEFORE importing Hugging Face; never use a cached private credential.
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    if not download:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
    from huggingface_hub import snapshot_download

    paths = []
    for role, spec in (("image", IMAGE_MODEL), ("text", TEXT_MODEL)):
        path = Path(snapshot_download(repo_id=spec["id"], revision=spec["revision"], token=False,
                                      local_files_only=not download, allow_patterns=SNAPSHOT_FILES[role]))
        require(path.name == spec["revision"], f"Unexpected resolved {role} snapshot revision")
        for relative in SNAPSHOT_FILES[role]:
            # Model cards/license files are evidence if present, not invented prerequisites.
            if "*" not in relative and relative != "README.md":
                require((path / relative).is_file(), f"Incomplete pinned {role} cache: {relative}")
        paths.append(path)
    return paths[0], paths[1]


def source_provenance(stage: Path, paths: tuple[Path, Path], configs: dict, environment: dict) -> dict:
    sources = {}
    for role, path, spec in zip(("image", "text"), paths, (IMAGE_MODEL, TEXT_MODEL)):
        selected = sorted({file for pattern in SNAPSHOT_FILES[role] for file in path.glob(pattern)
                           if file.is_file()})
        # Hash at export time only, streaming bytes; never an editor read of weights.
        hashes = {file.relative_to(path).as_posix(): sha256_file(file) for file in selected}
        evidence = []
        declared_license = None
        for file in selected:
            if file.name == "README.md" or file.name.upper().startswith(("LICENSE", "NOTICE")):
                target = stage / "licenses" / role / file.relative_to(path)
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
        (stage / "licenses" / role).mkdir(parents=True, exist_ok=True)
        sources[role] = {**spec, "sha256": hashes, "licenseEvidence": evidence,
                         "modelCardDeclaredLicense": declared_license,
                         "redistributionApproved": False,
                         "licenseStatus": "manual review required; missing/unknown terms are not permission"}
    script_files = sorted(Path(__file__).parent.glob("*.py")) + [Path(__file__).parent / "requirements-coreml.txt"]
    result = {
        "schemaVersion": 1, "modelVersion": model_version(),
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
        "redistributionApproved": False,
        "note": "Review both pinned model cards, upstream model/data obligations and dependency licenses. "
                "Do not publish packages or unknown-license material based on this numerical export.",
        "sources": {role: {k: v for k, v in entry.items() if k != "sha256"}
                    for role, entry in sources.items()},
    })
    return result


def load_pair(paths: tuple[Path, Path]):
    import numpy as np
    import torch
    from sentence_transformers import SentenceTransformer
    from transformers import CLIPModel, DistilBertModel

    image = SentenceTransformer(str(paths[0]), device="cpu", local_files_only=True,
                                trust_remote_code=False, token=False)
    # ST 3.4.1's legacy CLIP module loader need not forward model_kwargs. Replace
    # ONLY its CLIP model using the same local weights and an explicit eager load.
    # The original SentenceTransformer processor/forward/encode pipeline remains.
    del image[0].model
    image[0].model = CLIPModel.from_pretrained(str(paths[0] / "0_CLIPModel"),
                                              attn_implementation="eager", torch_dtype=torch.float32,
                                              local_files_only=True, trust_remote_code=False, token=False)
    text = SentenceTransformer(str(paths[1]), device="cpu", local_files_only=True, token=False,
                               trust_remote_code=False, model_kwargs={"attn_implementation": "eager"})
    image.eval().float().cpu()
    text.eval().float().cpu()
    for model in (image, text):
        model.requires_grad_(False)
    require(len(image) == 1 and type(image[0]).__name__ == "CLIPModel", "Unexpected image modules")
    require([type(m).__name__ for m in text] == ["Transformer", "Pooling", "Dense"],
            "Unexpected text modules (normalization or other unused module must not be skipped)")
    require(isinstance(image[0].model, CLIPModel), "Image model is not transformers.CLIPModel")
    require(isinstance(text[0].auto_model, DistilBertModel), "Text model is not DistilBERT")
    require(image[0].model.config.vision_config._attn_implementation == "eager", "CLIP is not eager")
    require(text[0].auto_model.config._attn_implementation == "eager", "DistilBERT is not eager")
    for model in (image[0].model, text[0].auto_model):
        require(not any("sdpa" in type(m).__name__.lower() or "flash" in type(m).__name__.lower()
                        for m in model.modules()), "Fused attention cannot be traced in this exporter")
    require(text.max_seq_length == 128 and text[0].do_lower_case is False, "ST tokenization changed")
    pool = text[1]
    require(pool.pooling_mode_mean_tokens is True, "Expected mean pooling")
    for name in ("pooling_mode_cls_token", "pooling_mode_max_tokens", "pooling_mode_mean_sqrt_len_tokens",
                 "pooling_mode_weightedmean_tokens", "pooling_mode_lasttoken"):
        require(getattr(pool, name, False) is False, f"Unexpected pooling: {name}")
    require(text[2].linear.in_features == 768 and text[2].linear.out_features == 512 and
            text[2].linear.bias is None and isinstance(text[2].activation_function, torch.nn.Identity),
            "Dense projection changed")
    require(image[0].model.visual_projection.out_features == 512, "Visual projection changed")
    processor = image[0].processor.image_processor
    require(processor.size == {"shortest_edge": 224} and processor.crop_size == {"height": 224, "width": 224},
            "Effective CLIP resize/crop changed")
    require(processor.do_resize and processor.do_center_crop and processor.do_normalize and
            processor.do_rescale and int(processor.resample) == 3, "Effective CLIP preprocessing changed")
    require(np.array_equal(processor.image_mean, MEAN) and np.array_equal(processor.image_std, STD) and
            processor.rescale_factor == 1 / 255, "Effective CLIP normalization changed")
    return image, text


def tokenizer_cases(stage: Path, snapshot: Path, text_model) -> list[dict]:
    import numpy as np

    fast = text_model[0].tokenizer
    require(fast.is_fast, "Expected the original SentenceTransformer HF fast tokenizer")
    backend = json.loads(fast.backend_tokenizer.to_str())
    normalizer = backend["normalizer"]
    require(normalizer["type"] == "BertNormalizer" and normalizer["lowercase"] is False and
        normalizer["strip_accents"] in (None, False) and normalizer["handle_chinese_chars"] is True,
        "Effective cased/Chinese-preserving WordPiece normalization changed")
    require(backend["model"]["type"] == "WordPiece" and
        backend["model"]["continuing_subword_prefix"] == "##", "Effective WordPiece model changed")
    require(fast.padding_side == "right" and fast.truncation_side == "right", "Tokenization side changed")
    vocabulary = (snapshot / "vocab.txt").read_text(encoding="utf-8").splitlines()
    mapping = {word: index for index, word in enumerate(vocabulary)}
    require(len(vocabulary) == len(mapping) == 119547, "Vocabulary length or uniqueness changed")
    require(fast.get_vocab() == mapping, "Vocabulary ID order/added tokens changed")
    (stage / "vocab.txt").write_text("\n".join(vocabulary) + "\n", encoding="utf-8")
    result = []
    for case in query_cases():
        options = dict(padding="max_length", truncation=True, max_length=128,
                       add_special_tokens=True, return_attention_mask=True, return_token_type_ids=False)
        encoded = fast(case["text"], **options)
        for name in ("input_ids", "attention_mask"):
            require(len(encoded[name]) == 128, "Tokenizer fixture not fixed length")
        st_tokens = text_model.tokenize([case["text"]])
        valid = sum(encoded["attention_mask"])
        require(st_tokens["input_ids"][0].tolist() == encoded["input_ids"][:valid] and
                st_tokens["attention_mask"][0].tolist() == encoded["attention_mask"][:valid],
                f"Original ST preprocessing differs: {case['id']}")
        result.append({
            "metadata": {**case, "inputIDs": encoded["input_ids"], "attentionMask": encoded["attention_mask"]},
            "input_ids": np.asarray([encoded["input_ids"]], dtype=np.int32),
            "attention_mask": np.asarray([encoded["attention_mask"]], dtype=np.int32),
        })
    return result


def raw_vector(array, label: str):
    import numpy as np

    result = np.asarray(array)
    require(result.shape == (1, 512) and result.dtype == np.float32, f"{label}: expected float32 [1,512]")
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
    model.short_description = f"Pinned paired CLIP {role} encoder; raw 512D, no L2 normalization"
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
    paths = snapshots(args.download)
    configs = validate_snapshot_configs(*paths)
    source_provenance(stage, paths, configs, environment)

    import numpy as np
    import torch
    from encoder_wrappers import ImageEncoder, TextEncoder
    from synthetic_fixtures import image_cases

    image, text = load_pair(paths)
    images = image_cases(stage, image[0].processor.image_processor, args.preprocess_max_abs)
    queries = tokenizer_cases(stage, paths[1], text)
    image_wrapper, text_wrapper = ImageEncoder(image), TextEncoder(text)
    image_inputs = [(torch.from_numpy(case["pixels"]),) for case in images]
    text_inputs = [(torch.from_numpy(case["input_ids"]), torch.from_numpy(case["attention_mask"]))
                   for case in queries]
    image_trace = trace_wrapper(image_wrapper, image_inputs[0], image_inputs[1])
    text_trace = trace_wrapper(text_wrapper, text_inputs[0], text_inputs[-1])
    converted_image = convert_and_reload(image_trace, "image", stage)
    converted_text = convert_and_reload(text_trace, "text", stage)
    report = {"schemaVersion": 1, "modelVersion": model_version(), "precision": "float32",
              "computeUnits": "CPU_ONLY", "thresholds": {
                  "minCosineExclusive": args.min_cosine, "conversionMaxAbsInclusive": args.conversion_max_abs,
                  "torchMaxAbsInclusive": args.torch_max_abs, "similarityMaxAbsInclusive": args.similarity_max_abs,
                  "preprocessMaxAbsInclusive": args.preprocess_max_abs},
              "cases": [], "nativeTokenizerParity": "not-run", "nativeImagePreprocessParity": "not-run",
              "nativeModelRuntimeParity": "not-run", "semanticRetrievalQuality": "not-evaluated"}
    originals, predictions = {"image": [], "text": []}, {"image": [], "text": []}
    with torch.inference_mode():
        for role, cases, inputs, original, wrapper, traced, coreml in (
            ("image", images, image_inputs, image, image_wrapper, image_trace, converted_image),
            ("text", queries, text_inputs, text, text_wrapper, text_trace, converted_text),
        ):
            for case, tensors in zip(cases, inputs):
                name = case["metadata"]["id"]
                original_input = case["image"] if role == "image" else case["metadata"]["text"]
                st_raw = raw_vector(original.encode([original_input], batch_size=1, show_progress_bar=False,
                                                    convert_to_numpy=True, normalize_embeddings=False,
                                                    device="cpu"), f"{role}/{name}/ST")
                wrapped_raw = raw_vector(wrapper(*tensors).detach().cpu().numpy(), "wrapper")
                traced_raw = raw_vector(traced(*tensors).detach().cpu().numpy(), "trace")
                feed = ({"pixel_values": case["pixels"]} if role == "image" else
                        {key: case[key] for key in ("input_ids", "attention_mask")})
                cm_raw = raw_vector(coreml.predict(feed)["output_embedding"], "saved Core ML")
                stages = {}
                for label, left, right, tolerance in (
                    ("sentenceTransformerVsWrapper", st_raw, wrapped_raw, args.torch_max_abs),
                    ("wrapperVsTrace", wrapped_raw, traced_raw, args.torch_max_abs),
                    ("traceVsCoreML", traced_raw, cm_raw, args.conversion_max_abs),
                    ("sentenceTransformerVsCoreML", st_raw, cm_raw, args.conversion_max_abs),
                ):
                    stages[label] = compare(left, right, f"{role}/{name}/{label}", tolerance, args.min_cosine)
                report["cases"].append({"role": role, "id": name, "comparisons": stages})
                case["metadata"]["sentenceTransformerRaw"] = st_raw[0].tolist()
                case["metadata"]["coreMLRaw"] = cm_raw[0].tolist()
                originals[role].append(st_raw)
                predictions[role].append(cm_raw)
    reference = cosine_matrix(originals["text"], originals["image"])
    converted = cosine_matrix(predictions["text"], predictions["image"])
    delta = float(np.max(np.abs(reference - converted)))
    require(delta <= args.similarity_max_abs, f"Paired text/image cosine matrix differs by {delta}")
    report["pairedCosines"] = {
        "queryIDs": [c["metadata"]["id"] for c in queries],
        "imageIDs": [c["metadata"]["id"] for c in images],
        "sentenceTransformer": reference.tolist(), "coreML": converted.tolist(), "maxAbs": delta,
    }
    report["passed"] = True
    write_json(stage / "parity-report.json", report)
    shared = {"schemaVersion": 1, "modelVersion": model_version(),
              "embeddingDimension": 512, "embeddingsAreRaw": True}
    write_json(stage / "tokenizer-parity.json", {
        **shared, "sequenceLength": 128, "textModel": TEXT_MODEL,
        "vocabularySHA256": sha256_file(stage / "vocab.txt"),
        "reference": "pinned original SentenceTransformer HF fast tokenizer; checked against ST.tokenize",
        "tokenizerClass": type(text[0].tokenizer).__name__,
        "backendNormalizer": json.loads(text[0].tokenizer.backend_tokenizer.to_str())["normalizer"],
        "nativeParity": "not-run", "cases": [c["metadata"] for c in queries],
    })
    write_json(stage / "image-preprocess-parity.json", {
        **shared, "imageModel": IMAGE_MODEL, "preprocessing": PREPROCESS["image"],
        "reference": "HF processor checked against independent Pillow/NumPy implementation",
        "nativeParity": "not-run", "cases": [c["metadata"] for c in images],
    })
    manifest = base_manifest()
    manifest.update({
        "parity": {"status": "passed", "report": "parity-report.json", "precision": "float32",
                   "computeUnits": "CPU_ONLY", "nativeTokenizer": "not-run",
                   "nativePreprocessing": "not-run", "nativeRuntime": "not-run"},
        "provenance": "provenance.json", "redistributionApproved": False,
        "artifactsSHA256": {p.relative_to(stage).as_posix(): sha256_file(p)
                            for p in sorted(stage.rglob("*")) if p.is_file()},
    })
    # Not yet public: this file remains inside the staging directory until commit.
    write_json(stage / "model-manifest.json", manifest)


def publish(stage: Path, output: Path) -> None:
    """Commit marker last; only replace exporter-owned resources, not README/Places."""
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