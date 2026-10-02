"""Offline unittest coverage for build_places; all geometry is tiny and synthetic.

Uses the standard library plus the builder's Shapely dependency (target 2.1.2).
Never reads the real geography cache, photos or indexes, and never downloads.
Each test copies all eight pinned source metadata records, writes eight small
temporary GeoJSON files and substitutes only their fixture SHA-256 values.
Run explicitly by the caller; importing this module does not build a pack.
"""
from __future__ import annotations

import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from shapely.geometry import Point

import build_places as places


PINNED_COMMIT = "9469f09592ced973a3448cf66b6100b741b64c0d"
PINNED_SOURCES = (
    ("CHN", "ADM1", "CHN-ADM1-43563684", "2019", "bc4afc7eacf4351ae5b3ae7a612327987ce1123cb5deb8574fb49107091c6623"),
    ("CHN", "ADM2", "CHN-ADM2-17275852", "2017", "8c7dfa8e40842f9162453d9b0b614276a48bf635559ba371c7982cb288e7b303"),
    ("FRA", "ADM1", "FRA-ADM1-19338628", "2022", "7dc61e5c7e4c81f5fa10d339e6a5bc8428f1346f43f4426d9d165d2e44fc3a7e"),
    ("FRA", "ADM2", "FRA-ADM2-29444166", "2022", "a14ed131c86c802e5d546c7cbeccbd4daebc94a66fea413f563935a53504f251"),
    ("DEU", "ADM1", "DEU-ADM1-10402087", "2021", "511b3625ad4568d12a6bfcb1bdea4e877199e1923e502cb80224b8164128eb05"),
    ("DEU", "ADM2", "DEU-ADM2-9070358", "2021", "b811e77a73d37d9826ed0b17aaa017f7c92340c80707bdda4b95ce363e6364ab"),
    ("NLD", "ADM1", "NLD-ADM1-6811986", "2022", "16fcfe491a4fd6a3f977b743f23ce4116205c06880b2c521b02bc6c58f00b174"),
    ("NLD", "ADM2", "NLD-ADM2-6326949", "2022", "a973d6452362a29a8b8d364df0a377362e0cf68ce8f7da0298008c77c1c678c7"),
)


def rectangle(left=0, bottom=0, right=10, top=10) -> dict:
    return {"type": "Polygon", "coordinates": [[[left, bottom], [right, bottom],
            [right, top], [left, top], [left, bottom]]]}


def feature(source_id: str, name, geometry: dict) -> dict:
    return {"type": "Feature", "properties": {"shapeID": source_id, "shapeName": name},
            "geometry": geometry}


def collection(features: list[dict]) -> dict:
    return {"type": "FeatureCollection", "features": features}


def processing_event() -> dict:
    return {"repairAttempted": False, "polygonExtraction": False,
            "discardedNonPolygonComponents": 0}


def region(name: str, geometry: dict) -> places.Region:
    output, predicate = places.normalize_geometry(geometry, processing_event())
    return places.Region("synthetic-region", 1, name, output, predicate)


class RuntimeMetadataTests(unittest.TestCase):
    def test_fixed_fnv1a_vectors_including_unpadded_hex(self):
        for data, expected in ((b"", "cbf29ce484222325"), (b"a", "af63dc4c8601ec8c"),
                               (b"fo", "8985907b541d342"), (b"hello", "a430d84680aabd0b"),
                               (b"foobar", "85944171f73967e8")):
            with self.subTest(data=data):
                self.assertEqual(places.runtime_version(io.BytesIO(data)), f"raycast-v1-{expected}")

    def test_exact_synthetic_geometry_vector_shared_with_swift_resolver_test(self):
        # Keep these exact bytes in sync with PlacePackMetadataTests, including LF.
        data = (b'{"type":"FeatureCollection","coverageCountries":["Synthetic"],"features":'
                b'[{"type":"Feature","properties":{"label":"Square, Synthetic","level":"ADM1"},'
                b'"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,1],[0,0]]]}}]}\n')
        self.assertEqual(places.runtime_version(io.BytesIO(data)), "raycast-v1-4b2d9ec5135d4ccc")
        self.assertEqual(places.runtime_version(io.BytesIO(data[:-1])), "raycast-v1-da2e3970db8ea20e")

    def test_hashes_binary_bytes_across_bounded_chunks_without_json_decoding(self):
        data = bytes(range(256)) * 3
        # Different independent arithmetic expression: modulo 2**64 instead of a mask.
        expected = 14695981039346656037
        for byte in data:
            expected = ((expected ^ byte) * 1099511628211) % (2 ** 64)
        for chunk_size in (1, 7, 64, places.CHUNK_SIZE):
            with self.subTest(chunk_size=chunk_size), patch.object(places, "CHUNK_SIZE", chunk_size):
                self.assertEqual(places.runtime_version(io.BytesIO(data)), f"raycast-v1-{expected:x}")

    def test_coverage_matches_resolver_wording(self):
        suffix = (" Administrative boundaries may be incomplete or historical; not live GPS or global "
                  "coverage. 1 features; 0 unsupported/invalid features skipped.")
        self.assertEqual(places.runtime_coverage_description(["Synthetic"], 1),
                         "Offline country coverage: Synthetic." + suffix)
        self.assertEqual(places.runtime_coverage_description([], 1),
                         "Offline coverage: this pack only." + suffix)


class PlacesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="test-public-places-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache = self.root / "synthetic-cache"
        self.cache.mkdir()
        self.pins = places.load_sources()
        self.sources = copy.deepcopy(self.pins)
        # A failing guard, not a mocked successful download. CLI download tests
        # replace build_pack itself and exercise only argument forwarding.
        network = patch.object(places, "build_opener", side_effect=AssertionError("No network in tests"))
        self.no_network = network.start()
        self.addCleanup(network.stop)
        for source in self.sources:
            geometry = rectangle() if source["level"] == "ADM1" else rectangle(1, 1, 2, 2)
            self.write_source(source["iso"], source["level"], [feature(
                f"{source['iso']}-{source['level']}-synthetic",
                f"{source['iso']} {source['level']} synthetic", geometry)])

    def write_source(self, iso: str, level: str, features: list[dict]) -> dict:
        source = next(s for s in self.sources if (s["iso"], s["level"]) == (iso, level))
        data = (json.dumps(collection(features), ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        (self.cache / source["file"]).write_bytes(data)
        source["sha256"] = hashlib.sha256(data).hexdigest()
        return source

    def build(self, name="output") -> tuple[dict, dict]:
        output = self.root / name
        manifest = places.build_pack(self.sources, output, self.cache)
        pack = json.loads((output / places.PACK_NAME).read_text(encoding="utf-8"))
        return manifest, pack

    @staticmethod
    def snapshot(directory: Path) -> dict:
        return {path.name: (path.read_bytes(), path.stat().st_mtime_ns)
                for path in directory.iterdir() if path.is_file()}

    def test_pinned_eight_source_configuration(self):
        self.assertEqual(places.COMMIT, PINNED_COMMIT)
        self.assertEqual(len(self.pins), 8)
        expected_countries = {"CHN": "China", "FRA": "France", "DEU": "Germany", "NLD": "Netherlands"}
        self.assertEqual(places.COUNTRIES, expected_countries)
        for source, expected in zip(self.pins, PINNED_SOURCES):
            iso, level, boundary_id, year, digest = expected
            with self.subTest(iso=iso, level=level):
                self.assertEqual((source["iso"], source["level"], source["boundaryID"],
                                  source["year"], source["sha256"]), expected)
                self.assertEqual(source["country"], expected_countries[iso])
                self.assertEqual(source["commit"], PINNED_COMMIT)
                self.assertEqual(source["file"], f"{iso}-{level}.geojson")
                self.assertEqual(source["url"],
                    f"https://media.githubusercontent.com/media/wmgeolab/geoBoundaries/{PINNED_COMMIT}/"
                    f"releaseData/gbOpen/{iso}/{level}/geoBoundaries-{iso}-{level}_simplified.geojson")
        places.validate_sources(self.pins)

    def test_validate_sources_rejects_unpinned_or_incomplete_configuration(self):
        invalid = [self.pins[:-1], list(reversed(self.pins))]
        for key, value in (("commit", "0" * 40), ("url", "https://example.invalid/source"),
                           ("file", "other.geojson"), ("country", "Other"),
                           ("sha256", "A" * 64), ("sha256", "0" * 63)):
            changed = copy.deepcopy(self.pins)
            changed[0][key] = value
            invalid.append(changed)
        for key in ("canonical", "boundaryID", "year", "license", "licenseSource", "source"):
            changed = copy.deepcopy(self.pins)
            del changed[0][key]
            invalid.append(changed)
        for index, sources in enumerate(invalid):
            with self.subTest(case=index), self.assertRaises(places.BuildError):
                places.validate_sources(sources)

    def test_synthetic_sources_preserve_pins_except_content_hash(self):
        self.assertEqual(len(list(self.cache.iterdir())), 8)
        for fixture, pinned in zip(self.sources, self.pins):
            self.assertEqual({k: v for k, v in fixture.items() if k != "sha256"},
                             {k: v for k, v in pinned.items() if k != "sha256"})
            self.assertNotEqual(fixture["sha256"], pinned["sha256"])
        places.validate_sources(self.sources)

    def test_source_hash_is_verified_before_json_parsing(self):
        # Invalid JSON with a wrong hash must fail on integrity, not parsing.
        (self.cache / self.sources[0]["file"]).write_bytes(b"not JSON; deliberately wrong hash")
        before = self.snapshot(self.cache)
        with patch.object(places.json, "load", side_effect=AssertionError("JSON parsed before verification")) as parse:
            with self.assertRaisesRegex(places.BuildError, "SHA-256 mismatch.*no geometry parsed"):
                places.build_pack(self.sources, self.root / "rejected", self.cache)
            parse.assert_not_called()
        self.assertEqual(self.snapshot(self.cache), before)
        self.assertFalse((self.root / "rejected" / places.PACK_NAME).exists())
        self.assertFalse((self.root / "rejected" / places.MANIFEST_NAME).exists())
        self.no_network.assert_not_called()

    def test_verified_source_rewinds_verified_stream(self):
        source = self.sources[0]
        before = self.snapshot(self.cache)
        with places.verified_source(source, self.cache, False) as (stream, verified):
            self.assertEqual(stream.tell(), 0)
            data = stream.read()
            self.assertEqual(verified, {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
            self.assertEqual(verified["sha256"], source["sha256"])
            self.assertEqual(json.loads(data)["type"], "FeatureCollection")
        self.assertTrue(stream.closed)
        self.assertEqual(self.snapshot(self.cache), before)

    def test_build_does_not_modify_source_cache(self):
        before = self.snapshot(self.cache)
        metadata = copy.deepcopy(self.sources)
        manifest, _ = self.build()
        self.assertEqual(self.snapshot(self.cache), before)
        self.assertEqual(self.sources, metadata)
        for report, source in zip(manifest["sources"], self.sources):
            self.assertEqual(report["metadata"], source)
            self.assertEqual(report["verified"], {"sha256": source["sha256"],
                                                 "bytes": len(before[source["file"]][0])})
        self.no_network.assert_not_called()

    def test_parent_bbox_filters_before_polygon_predicate(self):
        child = region("Child", rectangle(1, 1, 2, 2))
        parent = region("Far away", rectangle(20, 20, 30, 30))
        predicate = Mock(wraps=parent.predicate)
        predicate.bounds = parent.predicate.bounds
        parent.predicate = predicate
        self.assertEqual(places.choose_parent(child, [parent]), (None, "parentUnmatched"))
        predicate.covers.assert_not_called()

    def test_parent_bbox_alone_does_not_match_a_hole(self):
        donut = rectangle()
        donut["coordinates"].append(rectangle(2, 2, 8, 8)["coordinates"][0])
        parent = region("Donut", donut)
        child = region("Inside hole", rectangle(3, 3, 4, 4))
        self.assertEqual(places.choose_parent(child, [parent]), (None, "parentUnmatched"))

    def test_parent_uses_representative_point_not_centroid(self):
        concave = {"type": "Polygon", "coordinates": [[[0, 0], [6, 0], [6, 1],
                    [1, 1], [1, 6], [0, 6], [0, 0]]]}
        child = region("Concave child", concave)
        parent = region("Concave parent", concave)
        self.assertFalse(parent.predicate.covers(child.predicate.centroid))
        self.assertTrue(parent.predicate.covers(child.predicate.representative_point()))
        self.assertEqual(places.choose_parent(child, [parent]), ("Concave parent", "parentMatched"))

    def test_parent_covers_boundary_without_requiring_full_child_containment(self):
        parent = region("Parent", rectangle())
        child = region("Straddles edge", rectangle(-1, 1, 1, 2))
        point = child.predicate.representative_point()
        self.assertTrue(parent.predicate.covers(point))
        self.assertFalse(parent.predicate.contains(point))
        self.assertFalse(parent.predicate.covers(child.predicate))
        self.assertEqual(places.choose_parent(child, [parent]), ("Parent", "parentMatched"))

    def test_parent_matches_ambiguities_and_absences_in_output(self):
        self.write_source("CHN", "ADM1", [feature("a", "West", rectangle(0, 0, 6, 6)),
                                          feature("b", "East", rectangle(4, 0, 10, 6))])
        self.write_source("CHN", "ADM2", [feature("unique", "Unique", rectangle(1, 1, 2, 2)),
                                          feature("overlap", "Overlap", rectangle(4.5, 1, 5.5, 2)),
                                          feature("outside", "Outside", rectangle(20, 20, 21, 21))])
        manifest, pack = self.build()
        labels = {f["properties"]["sourceBoundaryID"]: f["properties"]["label"] for f in pack["features"]}
        self.assertEqual(labels["unique"], "Unique, West, China")
        self.assertEqual(labels["overlap"], "Overlap, China")
        self.assertEqual(labels["outside"], "Outside, China")
        report = manifest["sources"][1]
        for key in ("parentMatched", "parentAmbiguous", "parentUnmatched"):
            self.assertEqual(report["counts"][key], 1)
        self.assertEqual({issue["issue"] for issue in report["issues"]},
                         {"parentAmbiguous", "parentUnmatched"})

    def test_parents_are_matched_only_within_the_same_country(self):
        # All countries intentionally occupy identical synthetic coordinates.
        manifest, pack = self.build()
        children = [f["properties"] for f in pack["features"] if f["properties"]["level"] == "ADM2"]
        self.assertEqual(len(children), 4)
        for child in children:
            iso = child["iso"]
            self.assertEqual(child["label"], f"{iso} ADM2 synthetic, {iso} ADM1 synthetic, {child['country']}")
        self.assertEqual(manifest["totals"]["parentMatched"], 4)
        self.assertEqual(manifest["totals"]["parentAmbiguous"], 0)

    def test_unlabeled_features_are_excluded_but_keep_parent_geometry(self):
        features = [feature(str(i), name, rectangle()) for i, name in enumerate((None, "", " \t", 42))]
        missing = feature("missing-name", "removed", rectangle())
        del missing["properties"]["shapeName"]
        features.append(missing)
        source = self.write_source("CHN", "ADM1", features)
        regions, report = places.prepare_source(collection(features), source)
        self.assertEqual(len(regions), 5)
        self.assertEqual(report["counts"]["unlabeled"], 5)
        self.assertEqual(report["counts"]["emitted"], 0)
        self.assertEqual(report["counts"]["excluded"], 5)
        child = region("Child", rectangle(1, 1, 2, 2))
        for parent in regions:
            self.assertEqual(parent.name, "")
            self.assertEqual(places.choose_parent(child, [parent]), (None, "parentUnlabeled"))
        named = region("Named parent", rectangle())
        self.assertEqual(places.choose_parent(child, [named, regions[0]]), (None, "parentAmbiguous"))
        # A single unnamed parent cannot contribute a guessed/Unknown label.
        self.write_source("CHN", "ADM1", [features[0]])
        self.write_source("CHN", "ADM2", [feature("child", "Child", rectangle(1, 1, 2, 2)),
                                          feature("unnamed-child", None, rectangle(3, 3, 4, 4))])
        manifest, pack = self.build()
        emitted = [f["properties"] for f in pack["features"] if f["properties"]["iso"] == "CHN"]
        self.assertEqual(len(emitted), 1)
        self.assertEqual(emitted[0]["label"], "Child, China")
        self.assertEqual(manifest["sources"][1]["counts"]["parentUnlabeled"], 1)
        self.assertEqual(manifest["sources"][1]["counts"]["unlabeled"], 1)

    def test_valid_polygons_multipolygons_and_holes_are_preserved(self):
        polygon = rectangle()
        polygon["coordinates"].append(rectangle(2, 2, 4, 4)["coordinates"][0])
        multipolygon = {"type": "MultiPolygon", "coordinates": [polygon["coordinates"],
                        rectangle(20, 0, 22, 2)["coordinates"]]}
        original = copy.deepcopy([polygon, multipolygon])
        self.write_source("CHN", "ADM1", [feature("p", "Polygon", polygon), feature("m", "Islands", multipolygon)])
        manifest, pack = self.build()
        actual = {f["properties"]["sourceBoundaryID"]: f["geometry"] for f in pack["features"]}
        self.assertEqual(actual["p"], original[0])
        self.assertEqual(actual["m"], original[1])
        self.assertEqual(manifest["totals"]["repairs"], 0)
        self.assertFalse(manifest["additionalSimplification"])
        for raw in original:
            event = processing_event()
            output, predicate = places.normalize_geometry(raw, event)
            self.assertEqual(output, raw)
            self.assertFalse(predicate.covers(Point(3, 3)))
            self.assertTrue(predicate.covers(Point(1, 1)))
            self.assertEqual(event, processing_event())

    def test_dateline_polygons_keep_wrapped_coordinates_and_holes(self):
        dateline = {"type": "Polygon", "coordinates": [
            [[179, -4], [-179, -4], [-179, 4], [179, 4], [179, -4]],
            [[179.25, -1], [-179.25, -1], [-179.25, 1], [179.25, 1], [179.25, -1]],
        ]}
        multi = {"type": "MultiPolygon", "coordinates": [dateline["coordinates"],
                 rectangle(-178, 10, -177, 11)["coordinates"]]}
        for raw in (dateline, multi):
            with self.subTest(kind=raw["type"]):
                before = copy.deepcopy(raw)
                event = processing_event()
                output, predicate = places.normalize_geometry(raw, event)
                self.assertEqual(output, before)
                self.assertEqual(raw, before)
                self.assertTrue(predicate.is_valid)
                self.assertTrue(predicate.covers(Point(179.1, 0)))
                self.assertFalse(predicate.covers(Point(180, 0)))
                self.assertFalse(event["repairAttempted"])
        parent = region("Dateline parent", dateline)
        child = region("Across dateline", rectangle(-179.9, 2, -179.5, 3))
        hole_child = region("In hole", rectangle(-179.9, -0.2, -179.8, 0.2))
        self.assertEqual(places.choose_parent(child, [parent]), ("Dateline parent", "parentMatched"))
        self.assertEqual(places.choose_parent(hole_child, [parent]), (None, "parentUnmatched"))

    def test_bowtie_repair_extractions_and_count_conservation(self):
        bowtie = {"type": "Polygon", "coordinates": [[[0, 0], [2, 2], [0, 2], [2, 0], [0, 0]]]}
        point = {"type": "Point", "coordinates": [30, 30]}
        mixed = {"type": "GeometryCollection", "geometries": [rectangle(20, 0, 22, 2), point]}
        self.write_source("CHN", "ADM1", [feature("valid", "Valid", rectangle(10, 0, 12, 2)),
                                          feature("bowtie", "Repaired", bowtie),
                                          feature("unnamed", None, rectangle(40, 0, 42, 2)),
                                          feature("point", "Not a region", point),
                                          feature("mixed", "Extracted", mixed)])
        event = processing_event()
        output, repaired = places.normalize_geometry(bowtie, event)
        self.assertTrue(event["repairAttempted"])
        self.assertTrue(repaired.is_valid)
        self.assertEqual(output["type"], "MultiPolygon")
        self.assertEqual(len(output["coordinates"]), 2)
        self.assertAlmostEqual(repaired.area, 2.0)
        manifest, pack = self.build()
        report = manifest["sources"][0]
        expected = {"raw": 5, "emitted": 3, "excluded": 2, "repairs": 1, "repairFailures": 0,
                    "unlabeled": 1, "unsupported": 1, "polygonExtractions": 1,
                    "discardedNonPolygonComponents": 2}
        for key, value in expected.items():
            self.assertEqual(report["counts"][key], value, key)
        actual = {f["properties"]["sourceBoundaryID"]: f["geometry"] for f in pack["features"]}
        self.assertEqual(actual["bowtie"], output)
        self.assertNotIn("unnamed", actual)
        self.assertNotIn("point", actual)
        self.assertEqual(manifest["totals"]["raw"], 12)
        self.assertEqual(manifest["totals"]["emitted"], 10)
        self.assertEqual(manifest["totals"]["excluded"], 2)
        for counts in [r["counts"] for r in manifest["sources"]] + [manifest["totals"]]:
            self.assertEqual(counts["raw"], counts["emitted"] + counts["excluded"])
        for key, total in manifest["totals"].items():
            self.assertEqual(total, sum(r["counts"][key] for r in manifest["sources"]), key)
        self.assertEqual(manifest["generated"]["featureCount"], len(pack["features"]))
        self.assertEqual(manifest["totals"]["emitted"], len(pack["features"]))
        processed = [i for i in report["issues"] if i["issue"] == "geometry-processing"]
        self.assertEqual(sum(i["repairAttempted"] for i in processed), 1)

    def test_collapsed_polygon_records_failed_repair_and_exclusion(self):
        flat = {"type": "Polygon", "coordinates": [[[30, 0], [31, 0], [32, 0], [30, 0]]]}
        regions, report = places.prepare_source(collection([feature("flat", "Flat", flat)]), self.sources[0])
        self.assertEqual(regions, [])
        expected = {"raw": 1, "emitted": 0, "excluded": 1, "repairs": 1,
                    "repairFailures": 1, "unsupported": 1}
        for key, value in expected.items():
            self.assertEqual(report["counts"][key], value, key)

    def test_outputs_are_byte_deterministic_in_two_directories(self):
        self.write_source("CHN", "ADM1", [feature("z", "最后", rectangle(20, 0, 22, 2)),
                                          feature("a", "Première", rectangle())])
        first, _ = self.build("first")
        second, pack = self.build("second")
        self.assertEqual(first, second)
        for name in (places.PACK_NAME, places.MANIFEST_NAME):
            self.assertEqual((self.root / "first" / name).read_bytes(), (self.root / "second" / name).read_bytes())
        ids = [f["properties"]["sourceBoundaryID"] for f in pack["features"][:2]]
        self.assertEqual(ids, ["a", "z"])

    def test_owned_generated_pair_can_be_rebuilt_without_touching_other_files(self):
        output = self.root / "owned"
        output.mkdir()
        extra = output / "keep.txt"
        extra.write_text("Unrelated user text", encoding="utf-8")
        extra_before = extra.read_bytes()
        first, _ = self.build("owned")
        original = {name: (output / name).read_bytes() for name in (places.PACK_NAME, places.MANIFEST_NAME)}
        places.check_owned_outputs(output)
        second, _ = self.build("owned")
        self.assertEqual(first, second)
        for name, data in original.items():
            self.assertEqual((output / name).read_bytes(), data)
        # Ownership also permits updating a valid generated pair, not just a no-op.
        self.write_source("CHN", "ADM2", [feature("new-child", "New child", rectangle(1, 1, 2, 2))])
        third, _ = self.build("owned")
        self.assertNotEqual(first["generated"]["sha256"], third["generated"]["sha256"])
        self.assertEqual(extra.read_bytes(), extra_before)
        places.check_owned_outputs(output)

    def test_custom_or_incomplete_outputs_are_refused_and_unchanged(self):
        for case, names in (("pack-only", [places.PACK_NAME]), ("manifest-only", [places.MANIFEST_NAME]),
                            ("custom-pair", [places.PACK_NAME, places.MANIFEST_NAME])):
            with self.subTest(case=case):
                output = self.root / case
                output.mkdir()
                for name in names:
                    (output / name).write_bytes(b'{"custom":true}\n')
                before = self.snapshot(output)
                with self.assertRaises(places.BuildError):
                    places.build_pack(self.sources, output, self.cache)
                self.assertEqual(self.snapshot(output), before)

    def test_modified_generated_pack_is_refused(self):
        self.build("modified")
        output = self.root / "modified"
        path = output / places.PACK_NAME
        path.write_bytes(path.read_bytes() + b"\n")
        before = self.snapshot(output)
        with self.assertRaisesRegex(places.BuildError, "custom or modified"):
            places.build_pack(self.sources, output, self.cache)
        self.assertEqual(self.snapshot(output), before)

    def test_attribution_preserves_source_metadata_and_license_links(self):
        text = (places.DEFAULT_OUTPUT / "ATTRIBUTION.md").read_text(encoding="utf-8")
        self.assertIn("gbOpen", text)
        self.assertIn("CC BY 4.0", text)
        for source in self.pins:
            for key in ("canonical", "boundaryID", "year", "license", "licenseSource", "source", "commit", "url", "sha256"):
                with self.subTest(source=source["boundaryID"], field=key):
                    self.assertIn(source[key], text)
        for url in places.LICENSE_URLS.values():
            self.assertIn(url, text)
        self.assertIn("representative_point", text)
        self.assertIn("not an official hierarchy", text)
        self.assertIn("Historical", text)

    def test_manifest_embeds_complete_attribution_and_fingerprints(self):
        text = (places.DEFAULT_OUTPUT / "ATTRIBUTION.md").read_text(encoding="utf-8")
        manifest, _ = self.build()
        encoded = text.encode("utf-8")
        self.assertEqual(manifest["attribution"], {"text": text, "licenseURLs": places.LICENSE_URLS,
            "sha256": hashlib.sha256(encoded).hexdigest(), "bytes": len(encoded)})
        self.assertEqual(manifest["parentMethod"], places.PARENT_METHOD)
        self.assertEqual(manifest["shapelyVersion"], places.shapely.__version__)
        self.assertEqual(manifest["geosVersion"], places.shapely.geos_version_string)
        self.assertEqual(manifest["sourceMetadataSHA256"],
                         hashlib.sha256(places.compact(self.sources).encode("utf-8")).hexdigest())
        data = (self.root / "output" / places.PACK_NAME).read_bytes()
        self.assertEqual(manifest["generated"]["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(manifest["generated"]["bytes"], len(data))
        on_disk = json.loads((self.root / "output" / places.MANIFEST_NAME).read_text(encoding="utf-8"))
        self.assertEqual(on_disk, manifest)
        # Source provenance has no source geometry or photo-location payload.
        self.assertNotIn('"coordinates":', places.compact(manifest))

    def test_runtime_manifest_is_derived_from_final_utf8_bytes_not_reserialized_json(self):
        self.write_source("CHN", "ADM1", [feature("unicode", "最后 Première", rectangle())])
        manifest, pack = self.build()
        data = (self.root / "output" / places.PACK_NAME).read_bytes()
        expected = 14695981039346656037
        for byte in data:
            expected = ((expected ^ byte) * 1099511628211) % (2 ** 64)
        runtime = manifest["runtime"]
        self.assertEqual(runtime, {"schemaVersion": 1, "version": f"raycast-v1-{expected:x}",
            "coverageDescription": places.runtime_coverage_description(pack["coverageCountries"], len(pack["features"]))})
        self.assertTrue(data.endswith(b"\n"))
        self.assertNotEqual(runtime["version"], places.runtime_version(io.BytesIO(data[:-1])))
        self.assertNotEqual(runtime["version"], places.runtime_version(io.BytesIO(json.dumps(pack).encode("utf-8"))))
        self.assertNotEqual(runtime["version"], "raycast-v1-" + manifest["generated"]["sha256"])
        written = json.loads((self.root / "output" / places.MANIFEST_NAME).read_text(encoding="utf-8"))
        self.assertEqual(written["runtime"], runtime)

    def test_old_owned_manifest_without_runtime_is_upgraded_without_changing_geography(self):
        manifest, _ = self.build("upgrade")
        output = self.root / "upgrade"
        geometry_before = (output / places.PACK_NAME).read_bytes()
        old = copy.deepcopy(manifest)
        del old["runtime"]
        (output / places.MANIFEST_NAME).write_text(places.compact(old) + "\n", encoding="utf-8")
        rebuilt, _ = self.build("upgrade")
        self.assertEqual((output / places.PACK_NAME).read_bytes(), geometry_before)
        self.assertEqual(rebuilt, manifest)

    def test_changed_geometry_updates_runtime_identity_even_when_feature_count_is_unchanged(self):
        first, _ = self.build("updated")
        self.write_source("CHN", "ADM2", [feature("CHN-ADM2-synthetic", "Changed label", rectangle(1, 1, 2, 2))])
        second, _ = self.build("updated")
        self.assertEqual(first["generated"]["featureCount"], second["generated"]["featureCount"])
        self.assertNotEqual(first["runtime"]["version"], second["runtime"]["version"])
        self.assertEqual(first["runtime"]["coverageDescription"], second["runtime"]["coverageDescription"])

    def test_cli_download_requires_flag_and_only_forwards_mode(self):
        output = self.root / "cli-not-built"
        stub = {"sources": [], "generated": {"file": places.PACK_NAME, "featureCount": 0,
                "bytes": 0, "sha256": "0" * 64}}
        cases = (([], places.DEFAULT_SOURCE_DIRECTORY, False),
                 (["--source-directory", str(self.cache)], self.cache, False),
                 (["--download"], None, True))
        for flags, expected_directory, expected_download in cases:
            with self.subTest(flags=flags), patch.object(places, "build_pack", return_value=stub) as build:
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(places.main(["--output", str(output), *flags]), 0)
                build.assert_called_once_with(self.pins, output, expected_directory, expected_download)
        self.assertFalse(output.exists())
        self.no_network.assert_not_called()

    def test_cli_download_and_source_directory_are_mutually_exclusive(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            places.argument_parser().parse_args(["--download", "--source-directory", str(self.cache)])
        self.assertEqual(error.exception.code, 2)
        self.no_network.assert_not_called()


if __name__ == "__main__":
    unittest.main()