"""Stdlib-only corpus selection tests; never downloads photos."""

import copy
from pathlib import Path
import shlex
import unittest

from prepare_real_photo_benchmark import CATEGORIES, IMAGE_COUNT, LICENSE_URL, PER_CATEGORY, arguments, select_images


def fixture():
    return {
        "licenses": [{"id": 4, "url": LICENSE_URL}, {"id": 2, "url": "https://creativecommons.org/licenses/by-nc/2.0/"}],
        "categories": [{"id": i, "name": name} for i, (name, _) in enumerate(CATEGORIES)],
        "images": [{"id": i, "license": 4 if i < 300 else 2} for i in range(320)],
        "annotations": [{"image_id": i, "category_id": i % len(CATEGORIES)} for i in range(320)],
    }


class RealPhotoSelectionTests(unittest.TestCase):
    def test_workflows_use_arguments_supported_by_the_actual_corpus_parser(self):
        root = Path(__file__).resolve().parents[1]
        for name in ("testflight.yml", "fp16-native-ranking.yml"):
            text = (root / ".github" / "workflows" / name).read_text(encoding="utf-8")
            commands = [line.split("python ", 1)[1] for line in text.splitlines()
                        if "python scripts/prepare_real_photo_benchmark.py" in line]
            self.assertEqual(len(commands), 1, name)
            parsed = arguments(shlex.split(commands[0])[1:])
            self.assertEqual(parsed.output, Path("build") / "RealPhotoBenchmark")
            self.assertEqual(parsed.cache, Path("build") / "coco-cache")

    def test_fixed_licensed_selection_and_positive_coverage(self):
        data = fixture()
        images, labels = select_images(data)
        self.assertEqual(len(images), IMAGE_COUNT)
        self.assertEqual(len({item["id"] for item in images}), IMAGE_COUNT)
        self.assertTrue(all(item["license"] == 4 for item in images))
        for name, _ in CATEGORIES:
            self.assertGreaterEqual(sum(name in labels[item["id"]] for item in images), PER_CATEGORY)
        shuffled = copy.deepcopy(data)
        for key in ("images", "annotations", "categories", "licenses"):
            shuffled[key].reverse()
        self.assertEqual(images, select_images(shuffled)[0])

    def test_missing_license_or_category_coverage_fails(self):
        for key in ("licenses", "annotations"):
            data = fixture()
            data[key] = []
            with self.assertRaises(ValueError):
                select_images(data)

    def test_duplicates_and_unknown_references_fail(self):
        data = fixture()
        data["images"].append(data["images"][0])
        with self.assertRaises(ValueError):
            select_images(data)
        data = fixture()
        data["annotations"].append({"image_id": 9999, "category_id": 0})
        with self.assertRaises(ValueError):
            select_images(data)


if __name__ == "__main__":
    unittest.main()
