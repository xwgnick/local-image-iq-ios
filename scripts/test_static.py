"""Stdlib-only smoke tests. No dependencies, subprocesses, downloads or model loads.

Run explicitly later: python3.11 scripts/test_static.py
These tests do NOT establish numerical, Core ML, Swift or iOS correctness.
"""

from __future__ import annotations

import ast
import copy
from contextlib import redirect_stderr
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import export_models
import model_contract as contract


def sparse_snapshot_configs() -> dict:
    """Small metadata fixture, not copied weights or a substitute for HF parity."""
    return {
        "config.json": {"model_type": "siglip", "vision_config": {"model_type": "siglip_vision_model"},
                        "text_config": {"model_type": "siglip_text_model", "vocab_size": 256000}},
        "preprocessor_config.json": {"image_processor_type": "SiglipImageProcessor",
                                    "size": {"height": 224, "width": 224}, "resample": 2,
                                    "do_resize": True, "do_normalize": True, "do_rescale": True,
                                    "rescale_factor": 1 / 255, "image_mean": [0.5] * 3,
                                    "image_std": [0.5] * 3},
        "tokenizer_config.json": {"tokenizer_class": "GemmaTokenizer", "do_lower_case": True,
                                  "add_bos_token": False, "add_eos_token": True, "padding_side": "right",
                                  "model_input_names": ["input_ids"], "pad_token": "<pad>",
                                  "eos_token": "<eos>", "bos_token": "<bos>", "unk_token": "<unk>",
                                  "added_tokens_decoder": {
                                      str(i): {"content": token, "special": True}
                                      for i, token in enumerate(("<pad>", "<eos>", "<bos>", "<unk>"))}},
    }


def check_configs(configs: dict) -> dict:
    with patch.object(contract, "read_json", side_effect=lambda path: configs[path.name]):
        return contract.validate_snapshot_configs(Path("synthetic-shared-snapshot"))


def make_snapshot(root: Path) -> Path:
    snapshot = root / contract.IMAGE_MODEL["revision"]
    snapshot.mkdir()
    for name in export_models.SNAPSHOT_FILES:
        if "*" not in name:
            (snapshot / name).write_text("synthetic test bytes; not a model", encoding="utf-8")
    (snapshot / "README.md").write_text("---\nlicense: apache-2.0\n---\nSynthetic model card\n", encoding="utf-8")
    return snapshot


def source_tree(name: str) -> ast.Module:
    return ast.parse((Path(__file__).parent / name).read_text(encoding="utf-8"))


class StaticTests(unittest.TestCase):
    def test_python_sources_parse(self):
        for path in Path(__file__).parent.glob("*.py"):
            with self.subTest(file=path.name):
                ast.parse(path.read_text(encoding="utf-8"), filename=path.name)

    def test_shared_contract(self):
        contract.validate_document()
        manifest = contract.base_manifest()
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(manifest["dimension"], 768)
        self.assertEqual(manifest["sequenceLength"], 64)
        self.assertEqual(manifest["imageSize"], 224)
        self.assertEqual(manifest["imageInput"], "pixel_values")
        self.assertEqual(manifest["textInputs"], ["input_ids"])
        self.assertEqual(manifest["output"], "output_embedding")
        self.assertEqual(manifest["imageModel"], manifest["textModel"])
        self.assertEqual(manifest["features"], {
            "image": {"pixel_values": {"dtype": "float32", "shape": [1, 3, 224, 224]}},
            "text": {"input_ids": {"dtype": "int32", "shape": [1, 64]}},
            "output": {"output_embedding": {"dtype": "float32", "shape": [1, 768]}},
        })
        self.assertEqual(manifest["tokenizerFile"], "tokenizer.json")
        self.assertEqual(manifest["tokenizerConfigFile"], "tokenizer_config.json")
        self.assertNotIn("parity", manifest)  # A schema template is NOT a passed export.

    def test_version_deterministic_and_sensitive_to_semantics(self):
        original = contract.model_version()
        self.assertRegex(original, r"^siglip2-b16-224-v1-[0-9a-f]{64}$")
        self.assertEqual(original, contract.model_version())
        altered = {**contract.TEXT_MODEL, "revision": "0" * 40}
        with patch.object(contract, "TEXT_MODEL", altered):
            self.assertNotEqual(original, contract.model_version())
        preprocess = copy.deepcopy(contract.PREPROCESS)
        preprocess["text"]["doLowerCase"] = False
        with patch.object(contract, "PREPROCESS", preprocess):
            self.assertNotEqual(original, contract.model_version())
        features = copy.deepcopy(contract.FEATURES)
        features["text"]["input_ids"]["shape"] = [1, 128]
        with patch.object(contract, "FEATURES", features):
            self.assertNotEqual(original, contract.model_version())
        preprocess = copy.deepcopy(contract.PREPROCESS)
        preprocess["image"]["resample"] = 3
        with patch.object(contract, "PREPROCESS", preprocess):
            self.assertNotEqual(original, contract.model_version())
        self.assertEqual(contract.canonical_json({"a": 1, "b": 2}),
                         contract.canonical_json({"b": 2, "a": 1}))

    def test_query_fixture_coverage_and_unicode(self):
        cases = {case["id"]: case["text"] for case in contract.query_cases()}
        self.assertEqual(len(cases), len(contract.query_cases()))
        self.assertEqual(len(cases), 17)
        self.assertTrue({"english", "chinese", "case", "diacritics", "combining", "punctuation",
                 "special-tokens", "empty", "whitespace-controls", "unknown-unicode",
                 "long-word", "long-truncation"}.issubset(cases))
        self.assertEqual(cases["empty"], "")
        self.assertIn("\u0301", cases["combining"])
        for token in ("<pad>", "<bos>", "<eos>", "<unk>", "<mask>"):
            self.assertIn(token, cases["special-tokens"])
        self.assertIn("Σ", cases["greek-sigma"])
        self.assertIn("İ", cases["turkish-unicode-chinese"])
        self.assertIn("中文", cases["turkish-unicode-chinese"])
        self.assertIn("<start_of_turn>", cases["gemma-turn-tokens"])
        self.assertIn("\x00", cases["whitespace-controls"])
        self.assertGreater(len(cases["long-truncation"].split()), 64)
        self.assertGreater(len(cases["long-word"]), 100)
        self.assertEqual(json.loads(json.dumps(cases, ensure_ascii=False)), cases)

    def test_no_exported_normalization(self):
        tree = source_tree("encoder_wrappers.py")
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute):
                self.assertNotIn(node.attr, ("normalize", "norm", "linalg_vector_norm", "sigmoid",
                                             "logit_scale", "logit_bias", "visual_projection"))

    def test_sparse_siglip_config_uses_verified_defaults(self):
        validated = check_configs(sparse_snapshot_configs())
        self.assertEqual(validated["effectiveVisionArchitecture"]["patch_size"], 16)
        self.assertEqual(validated["effectiveVisionArchitecture"]["hidden_size"], 768)
        self.assertTrue(validated["effectiveVisionArchitecture"]["vision_use_head"])
        self.assertEqual(validated["effectiveTextArchitecture"]["max_position_embeddings"], 64)
        self.assertEqual(validated["effectiveTextArchitecture"]["vocab_size"], 256000)

    def test_architecture_drift_is_rejected(self):
        for role, key, value in (("vision", "patch_size", 32), ("vision", "vision_use_head", False),
                                 ("vision", "hidden_size", 512), ("text", "vocab_size", 32000),
                                 ("text", "max_position_embeddings", 128)):
            with self.subTest(role=role, key=key):
                configs = sparse_snapshot_configs()
                configs["config.json"][f"{role}_config"][key] = value
                with self.assertRaises(ValueError):
                    check_configs(configs)
        configs = sparse_snapshot_configs()
        configs["config.json"]["model_type"] = "siglip2"
        with self.assertRaisesRegex(ValueError, "built-in SiglipModel"):
            check_configs(configs)

    def test_remote_code_mapping_is_rejected(self):
        for name in ("config.json", "preprocessor_config.json", "tokenizer_config.json", "text", "vision"):
            with self.subTest(config=name):
                configs = sparse_snapshot_configs()
                target = (configs["config.json"][f"{name}_config"] if name in ("text", "vision")
                          else configs[name])
                target["auto_map"] = {"AutoModel": "custom.Model"}
                with self.assertRaisesRegex(ValueError, "Remote code"):
                    check_configs(configs)

    def test_processor_drift_is_rejected(self):
        for key, value in (("resample", 3), ("do_center_crop", True), ("do_rescale", False),
                           ("size", {"shortest_edge": 224}), ("image_std", [1.0] * 3)):
            with self.subTest(key=key):
                configs = sparse_snapshot_configs()
                configs["preprocessor_config.json"][key] = value
                with self.assertRaises(ValueError):
                    check_configs(configs)

    def test_tokenizer_config_drift_is_rejected(self):
        for key, value in (("add_bos_token", True), ("add_eos_token", False), ("do_lower_case", False),
                           ("padding_side", "left"), ("truncation_side", "left"),
                           ("model_input_names", ["input_ids", "attention_mask"]),
                           ("tokenizer_class", "BertTokenizer"), ("eos_token", "<pad>")):
            with self.subTest(key=key):
                configs = sparse_snapshot_configs()
                configs["tokenizer_config.json"][key] = value
                with self.assertRaises(ValueError):
                    check_configs(configs)
        configs = sparse_snapshot_configs()
        configs["tokenizer_config.json"]["added_tokens_decoder"]["1"]["content"] = "<bos>"
        with self.assertRaisesRegex(ValueError, "special token 1"):
            check_configs(configs)

    def test_json_serialization_rejects_nonfinite_results(self):
        with self.assertRaises(ValueError):
            contract.canonical_json({"cosine": float("nan")})
        self.assertEqual(json.loads(contract.canonical_json(contract.base_manifest())),
                         contract.base_manifest())

    def test_failed_rerun_invalidates_manifest_and_preserves_unowned_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "Models"
            output.mkdir()
            (output / "model-manifest.json").write_text('{"old":true}', encoding="utf-8")
            (output / "README.md").write_text("keep", encoding="utf-8")
            (output / "Places.geojson").write_text("keep too", encoding="utf-8")
            with patch.object(export_models, "check_environment", side_effect=ValueError("test failure")):
                with self.assertRaisesRegex(ValueError, "test failure"):
                    export_models.main(["--output", str(output)])
            self.assertFalse((output / "model-manifest.json").exists())
            self.assertEqual((output / "README.md").read_text(encoding="utf-8"), "keep")
            self.assertEqual((output / "Places.geojson").read_text(encoding="utf-8"), "keep too")

    def test_publish_commits_manifest_last(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, output = root / "stage", root / "Models"
            stage.mkdir()
            output.mkdir()
            (output / "model-manifest.json").write_text("stale", encoding="utf-8")
            (output / "vocab.txt").write_text("retired", encoding="utf-8")
            (output / "README.md").write_text("keep", encoding="utf-8")
            (output / "Places.geojson").write_text("keep places", encoding="utf-8")
            for name in export_models.OWNED_OUTPUTS:
                if name.endswith(".mlpackage") or name in ("fixtures", "licenses"):
                    (stage / name).mkdir()
                    (stage / name / "placeholder").write_text("test", encoding="utf-8")
                else:
                    (stage / name).write_text("test", encoding="utf-8")
            (stage / "model-manifest.json").write_text("test commit", encoding="utf-8")
            replace = export_models.os.replace
            calls = []

            def record(source, destination):
                calls.append(Path(destination).name)
                replace(source, destination)

            with patch.object(export_models.os, "replace", side_effect=record):
                export_models.publish(stage, output)
            self.assertEqual(calls[-1], "model-manifest.json")
            self.assertEqual(set(calls[:-1]), set(export_models.OWNED_OUTPUTS))
            self.assertFalse((output / "vocab.txt").exists())
            self.assertEqual((output / "README.md").read_text(encoding="utf-8"), "keep")
            self.assertEqual((output / "Places.geojson").read_text(encoding="utf-8"), "keep places")

    def test_interrupted_publish_does_not_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage, output = Path(temporary) / "stage", Path(temporary) / "output"
            stage.mkdir()
            output.mkdir()
            (output / "model-manifest.json").write_text("stale", encoding="utf-8")
            with patch.object(export_models.os, "replace", side_effect=OSError("simulated write failure")):
                with self.assertRaises(OSError):
                    export_models.publish(stage, output)
            self.assertFalse((output / "model-manifest.json").exists())

    def test_pinned_downloads_are_public_and_revision_bound(self):
        for model in (contract.IMAGE_MODEL, contract.TEXT_MODEL):
            self.assertEqual(model["id"], "google/siglip2-base-patch16-224")
            self.assertEqual(model["revision"], "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2")
        self.assertFalse(export_models.arguments([]).download)
        self.assertEqual(export_models.arguments([]).min_cosine, 0.999)
        for download in (False, True):
            with self.subTest(download=download), tempfile.TemporaryDirectory() as temporary:
                snapshot = make_snapshot(Path(temporary))
                fetch = Mock(return_value=str(snapshot))
                with patch.dict(sys.modules, {"huggingface_hub": SimpleNamespace(snapshot_download=fetch)}), \
                     patch.dict(export_models.os.environ, {}, clear=True):
                    self.assertEqual(export_models.snapshots(download), snapshot)
                    fetch.assert_called_once_with(repo_id=contract.IMAGE_MODEL["id"],
                        revision=contract.IMAGE_MODEL["revision"], token=False,
                        local_files_only=not download, allow_patterns=export_models.SNAPSHOT_FILES)
                    self.assertEqual(export_models.os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"], "1")
                    if not download:
                        self.assertEqual(export_models.os.environ["HF_HUB_OFFLINE"], "1")
                        self.assertEqual(export_models.os.environ["TRANSFORMERS_OFFLINE"], "1")

    def test_snapshot_requires_both_tokenizer_jsons(self):
        for name in contract.TOKENIZER_FILES:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                snapshot = make_snapshot(Path(temporary))
                (snapshot / name).unlink()
                fetch = Mock(return_value=str(snapshot))
                with patch.dict(sys.modules, {"huggingface_hub": SimpleNamespace(snapshot_download=fetch)}), \
                     patch.dict(export_models.os.environ):
                    with self.assertRaisesRegex(ValueError, "Incomplete pinned shared cache"):
                        export_models.snapshots(False)

    def test_wrong_resolved_revision_is_rejected(self):
        fetch = Mock(return_value="wrong-revision")
        with patch.dict(sys.modules, {"huggingface_hub": SimpleNamespace(snapshot_download=fetch)}), \
             patch.dict(export_models.os.environ):
            with self.assertRaisesRegex(ValueError, "snapshot revision"):
                export_models.snapshots(False)

    def test_parity_thresholds_cannot_be_weakened(self):
        for name, ceiling in contract.MAX_ABS_LIMITS.items():
            for value in ("nan", "inf", "0", "-1", str(ceiling * 2)):
                with self.subTest(name=name, value=value), redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        export_models.arguments(["--" + name.replace("_", "-"), value])
        for value in ("nan", "inf", "0.998", "1"):
            with self.subTest(cosine=value), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    export_models.arguments(["--min-cosine", value])

    def test_stricter_parity_thresholds_are_allowed(self):
        defaults = export_models.arguments([])
        for name, ceiling in contract.MAX_ABS_LIMITS.items():
            self.assertEqual(getattr(defaults, name), ceiling)
            args = export_models.arguments(["--" + name.replace("_", "-"), str(ceiling / 2)])
            self.assertEqual(getattr(args, name), ceiling / 2)
        self.assertEqual(export_models.arguments(["--min-cosine", "0.9999"]).min_cosine, 0.9999)

    def test_tokenization_accepts_eos_padding_and_literal_specials(self):
        for content in ([], [0], [2, 1, 3, 0], [42] * 63):
            ids = content + [1]
            encoded = {"input_ids": ids + [0] * (64 - len(ids)),
                       "attention_mask": [1] * len(ids) + [0] * (64 - len(ids))}
            contract.validate_tokenization(encoded)
        # Content PAD must retain mask=1; never infer the mask as (id != 0).

    def test_tokenization_rejects_corrupt_ids_masks_eos_and_padding(self):
        valid = {"input_ids": [42, 1] + [0] * 62, "attention_mask": [1, 1] + [0] * 62}
        corruptions = [("input_ids", 0, -1), ("input_ids", 0, 256000), ("input_ids", 0, 42.0),
                       ("input_ids", 1, 2), ("input_ids", 63, 1), ("attention_mask", 0, 0),
                       ("attention_mask", 4, 1), ("attention_mask", 1, 2)]
        for key, index, value in corruptions:
            with self.subTest(key=key, index=index, value=value):
                encoded = copy.deepcopy(valid)
                encoded[key][index] = value
                with self.assertRaises(ValueError):
                    contract.validate_tokenization(encoded)
        for encoded in ({"input_ids": [0] * 64, "attention_mask": [0] * 64},
                        {"input_ids": [1], "attention_mask": [1]}):
            with self.assertRaises(ValueError):
                contract.validate_tokenization(encoded)

    def test_explicit_lowercase_and_hf_options_are_authoritative(self):
        encoded = {"input_ids": [1] + [0] * 63, "attention_mask": [1] + [0] * 63}
        fast = Mock(return_value=encoded)
        text = " ΟΣ İ Straße 中文 <BOS>\tCafe\u0301\x00 "
        self.assertIs(export_models.tokenize_query(fast, text), encoded)
        fast.assert_called_once_with(" ος i\u0307 straße 中文 <bos>\tcafe\u0301\x00 ",
            padding="max_length", truncation=True, max_length=64, add_special_tokens=True,
            return_attention_mask=True, return_token_type_ids=False)
        # The mock verifies the boundary, not actual Gemma tokenization.

    def test_wrapper_features_are_only_raw_tower_pooler_outputs(self):
        classes = {node.name: node for node in source_tree("encoder_wrappers.py").body
                   if isinstance(node, ast.ClassDef)}
        self.assertEqual(set(classes), {"ImageEncoder", "TextEncoder"})
        for name, argument, tower in (("ImageEncoder", "pixel_values", "vision_model"),
                                       ("TextEncoder", "input_ids", "text_model")):
            forward = next(node for node in classes[name].body
                           if isinstance(node, ast.FunctionDef) and node.name == "forward")
            self.assertEqual([arg.arg for arg in forward.args.args], ["self", argument])
            returns = [node for node in ast.walk(forward) if isinstance(node, ast.Return)]
            self.assertEqual(len(returns), 1)
            output = returns[0].value
            self.assertIsInstance(output, ast.Attribute)
            self.assertEqual(output.attr, "pooler_output")
            self.assertEqual(output.value.func.attr, tower)
            self.assertEqual({kw.arg for kw in output.value.keywords}, {argument, "return_dict"})

    def test_export_reference_and_fixture_schema_are_not_legacy(self):
        tree = source_tree("export_models.py")
        strings = {node.value for node in ast.walk(tree)
                   if isinstance(node, ast.Constant) and isinstance(node.value, str)}
        self.assertTrue({"referenceRaw", "coreMLRaw", "referenceVsWrapper", "wrapperVsTrace",
                         "traceVsCoreML", "referenceVsCoreML", "reference", "tokenizerSHA256",
                         "configSHA256", "attentionMask", "lowercasedText"}.issubset(strings))
        self.assertTrue({"sentenceTransformerRaw", "sentenceTransformerVsWrapper",
                         "sentenceTransformerVsCoreML", "sentenceTransformer", "vocabularySHA256"}.isdisjoint(strings))
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and
                 isinstance(node.func, ast.Attribute) and node.func.attr in
                 ("get_image_features", "get_text_features")]
        self.assertEqual({call.func.attr for call in calls}, {"get_image_features", "get_text_features"})
        for call in calls:
            self.assertNotIn("attention_mask", [kw.arg for kw in call.keywords])

    def test_six_image_cases_include_low_resolution_warp(self):
        tree = source_tree("synthetic_fixtures.py")
        assignment = next(node for node in tree.body if isinstance(node, ast.Assign) and
                          any(isinstance(t, ast.Name) and t.id == "IMAGE_CASE_SPECS" for t in node.targets))
        specs = ast.literal_eval(assignment.value)
        self.assertEqual(len(specs), 6)
        dimensions = {name: (width, height) for name, width, height, _, _ in specs}
        self.assertEqual(dimensions["lowres-68x120"], (68, 120))
        self.assertEqual(dimensions["lowres-112-portrait"], (112, 199))
        self.assertEqual({spec[3] for spec in specs}, {1, 2, 6})
        attributes = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
        self.assertIn("BILINEAR", attributes)
        self.assertNotIn("BICUBIC", attributes)
        self.assertNotIn("crop", attributes)
        self.assertEqual(contract.PREPROCESS["image"]["resample"], 2)
        self.assertEqual(contract.MEAN, [0.5] * 3)
        self.assertEqual(contract.STD, [0.5] * 3)

    def test_runtime_resources_and_pinned_environment(self):
        self.assertEqual(contract.TOKENIZER_FILES, ("tokenizer.json", "tokenizer_config.json"))
        self.assertTrue(set(contract.TOKENIZER_FILES).issubset(export_models.OWNED_OUTPUTS))
        self.assertNotIn("vocab.txt", export_models.OWNED_OUTPUTS)
        self.assertEqual(export_models.RETIRED_OUTPUTS, ("vocab.txt",))
        self.assertEqual(export_models.SNAPSHOT_FILES.count("model.safetensors"), 1)
        self.assertNotIn("tokenizer.model", export_models.SNAPSHOT_FILES)
        self.assertNotIn("special_tokens_map.json", export_models.SNAPSHOT_FILES)
        lines = (Path(__file__).parent / "requirements-coreml.txt").read_text(encoding="utf-8").splitlines()
        pins = dict(line.strip().split("==") for line in lines if line.strip() and not line.lstrip().startswith("#"))
        self.assertEqual(pins["coremltools"], "8.3.0")
        self.assertEqual(pins["torch"], "2.5.1")
        self.assertEqual(pins["transformers"], "4.48.3")
        self.assertEqual(pins["tokenizers"], "0.21.0")
        self.assertEqual(pins["protobuf"], "4.25.6")
        self.assertNotIn("sentence-transformers", pins)
        self.assertNotIn("sentencepiece", pins)

    def test_shared_provenance_hashes_weights_only_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot = make_snapshot(root)
            stage = root / "stage"
            stage.mkdir()
            with patch.object(export_models, "sha256_file", wraps=contract.sha256_file) as hash_file:
                result = export_models.source_provenance(stage, snapshot, {}, {"synthetic": True})
            self.assertEqual(sum(call.args == (snapshot / "model.safetensors",)
                                 for call in hash_file.call_args_list), 1)
            self.assertEqual(result["schemaVersion"], 2)
            self.assertEqual(set(result["sources"]), {"shared"})
            shared = result["sources"]["shared"]
            self.assertEqual(shared["roles"], ["image", "text"])
            self.assertEqual(shared["modelCardDeclaredLicense"], "apache-2.0")
            self.assertIn("licenses/shared/README.md", shared["licenseEvidence"])
            self.assertFalse(shared["redistributionApproved"])
            self.assertTrue((stage / "licenses" / "review-required.json").is_file())

    def test_export_contract_imports_are_stdlib_only(self):
        allowed = sys.stdlib_module_names | {"model_contract"}
        for name in ("export_models.py", "model_contract.py"):
            for node in source_tree(name).body:
                if isinstance(node, ast.Import):
                    self.assertTrue(all(alias.name.split(".")[0] in allowed for alias in node.names))
                elif isinstance(node, ast.ImportFrom):
                    self.assertIn(node.module.split(".")[0], allowed)

    def test_export_gates_survive_python_optimization(self):
        for name in ("model_contract.py", "export_models.py", "synthetic_fixtures.py"):
            self.assertFalse(any(isinstance(node, ast.Assert) for node in ast.walk(source_tree(name))))
        with self.assertRaisesRegex(ValueError, "gate remains active"):
            contract.require(False, "gate remains active")

    def test_document_drift_is_rejected(self):
        document = (contract.ROOT / "docs" / "IMPLEMENTATION_CONTRACT.md").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "contract.md"
            path.write_text(document.replace("`schemaVersion:2`", "`schemaVersion:1`"), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "schemaVersion:2"):
                contract.validate_document(path)


if __name__ == "__main__":
    unittest.main()