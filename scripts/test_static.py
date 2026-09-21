"""Stdlib-only smoke tests. No dependencies, subprocesses, downloads or model loads.

Run explicitly later: python3.11 scripts/test_static.py
These tests do NOT establish numerical, Core ML, Swift or iOS correctness.
"""

from __future__ import annotations

import ast
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import export_models
import model_contract as contract


class StaticTests(unittest.TestCase):
    def test_python_sources_parse(self):
        for path in Path(__file__).parent.glob("*.py"):
            with self.subTest(file=path.name):
                ast.parse(path.read_text(encoding="utf-8"), filename=path.name)

    def test_shared_contract(self):
        contract.validate_document()
        manifest = contract.base_manifest()
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["dimension"], 512)
        self.assertEqual(manifest["sequenceLength"], 128)
        self.assertEqual(manifest["imageSize"], 224)
        self.assertEqual(manifest["imageInput"], "pixel_values")
        self.assertEqual(manifest["textInputs"], ["input_ids", "attention_mask"])
        self.assertEqual(manifest["output"], "output_embedding")
        self.assertNotIn("parity", manifest)  # A schema template is NOT a passed export.

    def test_version_deterministic_and_sensitive_to_semantics(self):
        original = contract.model_version()
        self.assertEqual(original, contract.model_version())
        altered = {**contract.TEXT_MODEL, "revision": "0" * 40}
        with patch.object(contract, "TEXT_MODEL", altered):
            self.assertNotEqual(original, contract.model_version())
        preprocess = copy.deepcopy(contract.PREPROCESS)
        preprocess["text"]["stripAccents"] = True
        with patch.object(contract, "PREPROCESS", preprocess):
            self.assertNotEqual(original, contract.model_version())
        self.assertEqual(contract.canonical_json({"a": 1, "b": 2}),
                         contract.canonical_json({"b": 2, "a": 1}))

    def test_query_fixture_coverage_and_unicode(self):
        cases = {case["id"]: case["text"] for case in contract.query_cases()}
        self.assertEqual(len(cases), len(contract.query_cases()))
        self.assertEqual(cases["empty"], "")
        self.assertIn("\u0301", cases["combining"])
        self.assertIn("[PAD]", cases["special-tokens"])
        self.assertGreater(len(cases["long-truncation"].split()), 128)
        self.assertGreater(len(cases["long-word"]), 100)
        self.assertEqual(json.loads(json.dumps(cases, ensure_ascii=False)), cases)

    def test_no_exported_normalization(self):
        tree = ast.parse((Path(__file__).parent / "encoder_wrappers.py").read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                self.assertNotIn(node.func.attr, ("normalize", "norm", "linalg_vector_norm"))

    def test_unused_snapshot_module_is_rejected(self):
        unexpected = [{"idx": 0, "name": "0", "path": "0_CLIPModel",
                       "type": "sentence_transformers.models.CLIPModel"},
                      {"idx": 1, "name": "1", "path": "1_Normalize",
                       "type": "sentence_transformers.models.Normalize"}]
        with patch.object(contract, "read_json", return_value=unexpected):
            with self.assertRaisesRegex(ValueError, "Image module graph changed"):
                contract.validate_snapshot_configs(Path("image"), Path("text"))

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

    def test_interrupted_publish_does_not_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage, output = Path(temporary) / "stage", Path(temporary) / "output"
            stage.mkdir()
            output.mkdir()
            with patch.object(export_models.os, "replace", side_effect=OSError("simulated write failure")):
                with self.assertRaises(OSError):
                    export_models.publish(stage, output)
            self.assertFalse((output / "model-manifest.json").exists())

    def test_pinned_downloads_are_public_and_revision_bound(self):
        for model in (contract.IMAGE_MODEL, contract.TEXT_MODEL):
            self.assertTrue(model["id"].startswith("sentence-transformers/"))
            self.assertRegex(model["revision"], r"^[0-9a-f]{40}$")
        self.assertFalse(export_models.arguments([]).download)
        self.assertEqual(export_models.arguments([]).min_cosine, 0.999)


if __name__ == "__main__":
    unittest.main()