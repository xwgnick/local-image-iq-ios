"""Build the optional public boundary pack; never read photos, indexes or GPS.

Only Python's standard library and Shapely are required (target: Shapely 2.1.2).
No network by default. Download mode is limited to the eight pinned public URLs.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import sys
import tempfile
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

import shapely
from shapely import make_valid
from shapely.errors import GEOSException
from shapely.geometry import MultiPolygon, Point, mapping, shape
from shapely.geometry.base import BaseGeometry


ROOT = Path(__file__).resolve().parents[1]
SOURCE_CONFIG = Path(__file__).with_name("place_sources.json")
DEFAULT_SOURCE_DIRECTORY = Path.home() / ".local_photo_search" / "geography"
DEFAULT_OUTPUT = ROOT / "Resources" / "Places"
COMMIT = "9469f09592ced973a3448cf66b6100b741b64c0d"
COUNTRIES = {"CHN": "China", "FRA": "France", "DEU": "Germany", "NLD": "Netherlands"}
SOURCE_ORDER = [(iso, level) for iso in COUNTRIES for level in ("ADM1", "ADM2")]
CHUNK_SIZE = 64 * 1024
GENERATOR = "local-image-iq-public-places-v1"
PACK_NAME = "Places.geojson"
MANIFEST_NAME = "places-manifest.json"
PARENT_METHOD = (
    "Same-country ADM1 bounding-box candidates, then covers(ADM2 representative_point); "
    "exactly one candidate required, including unnamed candidates. Ambiguous, absent or "
    "unnamed parents are omitted. Planar longitude-unwrapped administrative approximation; "
    "not full child containment, an official hierarchy, a nearest-place guess or photo GPS."
)
LICENSE_URLS = {
    "geoBoundaries": "https://creativecommons.org/licenses/by/4.0/",
    "Public Domain": "https://commons.wikimedia.org/wiki/File",
    "Open Data Commons Public Domain Dedication and License (PDDL) v1.0":
        "https://opendatacommons.org/licenses/pddl/1-0/",
    "Etalab Open License 2.0": "https://github.com/etalab/licence-ouverte/blob/master/LO.md",
    "Data license Germany - Attribution - Version 2.0": "https://www.govdata.de/dl-de/by-2-0",
    "CC0 1.0 Universal (CC0 1.0) Public Domain Dedication":
        "https://creativecommons.org/publicdomain/zero/1.0/",
}


class BuildError(ValueError):
    """An actionable source, integrity or output-ownership error."""


def compact(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def public_url(iso: str, level: str) -> str:
    return (
        f"https://media.githubusercontent.com/media/wmgeolab/geoBoundaries/{COMMIT}/"
        f"releaseData/gbOpen/{iso}/{level}/geoBoundaries-{iso}-{level}_simplified.geojson"
    )


def validate_sources(sources: list[dict]) -> None:
    if [(s.get("iso"), s.get("level")) for s in sources] != SOURCE_ORDER:
        raise BuildError("Expected the eight CHN/FRA/DEU/NLD ADM1/ADM2 sources in pinned order.")
    for source in sources:
        iso, level = source["iso"], source["level"]
        if (source.get("commit") != COMMIT or source.get("url") != public_url(iso, level)
                or source.get("file") != f"{iso}-{level}.geojson"
                or source.get("country") != COUNTRIES[iso]):
            raise BuildError(f"Unpinned URL, filename, revision or country for {iso}/{level}.")
        digest = source.get("sha256", "")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise BuildError(f"Invalid SHA-256 for {iso}/{level}.")
        for key in ("canonical", "boundaryID", "year", "license", "licenseSource", "source"):
            if not isinstance(source.get(key), str) or not source[key]:
                raise BuildError(f"Missing {key} for {iso}/{level}.")


def load_sources() -> list[dict]:
    config = json.loads(SOURCE_CONFIG.read_text(encoding="utf-8"))
    if config.get("schemaVersion") != 1 or not isinstance(config.get("sources"), list):
        raise BuildError("Unsupported source configuration.")
    validate_sources(config["sources"])
    return config["sources"]


def fingerprint(stream) -> dict:
    digest, length = hashlib.sha256(), 0
    while chunk := stream.read(CHUNK_SIZE):
        digest.update(chunk)
        length += len(chunk)
    return {"sha256": digest.hexdigest(), "bytes": length}


def runtime_version(stream) -> str:
    """Exact OfflinePlaceResolver identity: FNV-1a over final GeoJSON bytes.

    Not SHA-256, reserialized JSON, source fingerprints or padded hexadecimal.
    Keep this algorithm/prefix unchanged to preserve existing geography caches.
    """
    value = 14695981039346656037
    while chunk := stream.read(CHUNK_SIZE):
        for byte in chunk:
            value = ((value ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return f"raycast-v1-{value:x}"


def runtime_coverage_description(countries: list[str], feature_count: int) -> str:
    # Generated polygons are validated before emission; check_places and native
    # bundled tests verify that the resolver accepts every emitted feature.
    coverage = (f"Offline country coverage: {', '.join(countries)}." if countries
                else "Offline coverage: this pack only.")
    return (f"{coverage} Administrative boundaries may be incomplete or historical; "
            f"not live GPS or global coverage. {feature_count} features; "
            "0 unsupported/invalid features skipped.")


def verify_sha(actual: dict, source: dict) -> None:
    if actual["sha256"] != source["sha256"]:
        raise BuildError(
            f"SHA-256 mismatch for {source['file']}: expected {source['sha256']}, "
            f"got {actual['sha256']}; no geometry parsed."
        )


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise BuildError("Pinned public download redirected; no redirect target was contacted.")


@contextmanager
def verified_source(source: dict, directory: Path | None, download: bool):
    """Hash before parsing, then parse the same open file, not a reopened path."""
    if not download:
        if directory is None:
            raise BuildError("A cache directory is required in offline mode.")
        with (directory / source["file"]).open("rb") as stream:
            info = fingerprint(stream)
            verify_sha(info, source)
            stream.seek(0)
            yield stream, info
        return
    if source["url"] != public_url(source["iso"], source["level"]):
        raise BuildError("Only the pinned public geometry URLs may be downloaded.")
    # No proxy/environment credentials, cookies, tokens, API discovery or redirects.
    opener = build_opener(ProxyHandler({}), NoRedirect())
    request = Request(source["url"], headers={"Accept-Encoding": "identity"})
    with tempfile.TemporaryFile(mode="w+b") as stream:
        digest, length = hashlib.sha256(), 0
        with opener.open(request) as response:
            while chunk := response.read(CHUNK_SIZE):
                stream.write(chunk)
                digest.update(chunk)
                length += len(chunk)
        info = {"sha256": digest.hexdigest(), "bytes": length}
        verify_sha(info, source)
        stream.seek(0)
        yield stream, info


def longitude_shift(x: float, reference: float) -> float:
    return 360 * math.floor((reference - x) / 360 + 0.5)


def unwrap_ring(ring, reference: float | None = None) -> list:
    """Predicate-only minimal-edge longitude unwrapping, matching the iOS model."""
    if not isinstance(ring, (list, tuple)) or len(ring) < 4:
        raise BuildError("A polygon ring needs at least four positions.")
    points = []
    for position in ring:
        if (not isinstance(position, (list, tuple)) or len(position) not in (2, 3)
                or any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v)
                       for v in position)
                or not -180 <= position[0] <= 180 or not -90 <= position[1] <= 90):
            raise BuildError("Unsupported/nonfinite position or coordinates outside WGS84 ranges.")
        x = position[0]
        if points:
            while x - points[-1][0] > 180:
                x -= 360
            while x - points[-1][0] < -180:
                x += 360
        points.append([x, *position[1:]])
    if ring[0][:2] != ring[-1][:2] or points[0][:2] != points[-1][:2]:
        raise BuildError("Unclosed ring or globe-winding ring unsupported by planar boundaries.")
    if reference is not None:
        center = (min(p[0] for p in points) + max(p[0] for p in points)) / 2
        shift = longitude_shift(center, reference)
        points = [[p[0] + shift, *p[1:]] for p in points]
    return points


def input_polygons(raw: dict) -> tuple[list, int]:
    kind = raw.get("type")
    if kind == "Polygon":
        return [raw["coordinates"]], 0
    if kind == "MultiPolygon":
        return list(raw["coordinates"]), 0
    if kind == "GeometryCollection":
        polygons, discarded = [], 0
        for child in raw["geometries"]:
            found, count = input_polygons(child)
            polygons.extend(found)
            discarded += count
        return polygons, discarded
    return [], 1


def polygon_components(geometry: BaseGeometry) -> tuple[list, int]:
    """Explicitly extract all polygon components, including nested repair results."""
    if geometry.geom_type == "Polygon":
        return ([] if geometry.is_empty else [geometry]), 0
    if geometry.geom_type in ("MultiPolygon", "GeometryCollection"):
        polygons, discarded = [], 0
        for child in geometry.geoms:
            found, count = polygon_components(child)
            polygons.extend(found)
            discarded += count
        return polygons, discarded
    return [], 0 if geometry.is_empty else 1


def wrapped_mapping(geometry: BaseGeometry) -> dict:
    result = mapping(geometry)
    polygons = [result["coordinates"]] if result["type"] == "Polygon" else result["coordinates"]
    wrapped = []
    for polygon in polygons:
        rings = []
        for ring in polygon:
            positions = []
            for position in ring:
                x = position[0]
                while x > 180:
                    x -= 360
                while x < -180:
                    x += 360
                positions.append([x, *position[1:]])
            rings.append(positions)
        wrapped.append(rings)
    return {"type": result["type"], "coordinates": wrapped[0] if result["type"] == "Polygon" else wrapped}


def normalize_geometry(raw: dict, event: dict) -> tuple[dict, BaseGeometry]:
    """Keep valid Polygon/MultiPolygon coordinates verbatim; repair only if needed."""
    polygons, discarded = input_polygons(raw)
    event["discardedNonPolygonComponents"] = discarded
    event["polygonExtraction"] = raw.get("type") == "GeometryCollection"
    if not polygons:
        raise BuildError("No polygon components.")
    unwrapped, reference = [], None
    for polygon in polygons:
        if not polygon:
            raise BuildError("Empty polygon.")
        shell = unwrap_ring(polygon[0], reference)
        center = (min(p[0] for p in shell) + max(p[0] for p in shell)) / 2
        if reference is None:
            reference = center
        unwrapped.append([shell, *(unwrap_ring(hole, center) for hole in polygon[1:])])
    geometry = shape({"type": "MultiPolygon", "coordinates": unwrapped})
    event["repairAttempted"] = not geometry.is_valid
    if not geometry.is_valid:
        geometry = make_valid(geometry)
    parts, extra = polygon_components(geometry)
    event["discardedNonPolygonComponents"] += extra
    if not parts:
        raise BuildError("Repair produced no nonempty polygon components.")
    geometry = parts[0] if len(parts) == 1 else MultiPolygon(parts)
    if geometry.is_empty or not geometry.is_valid or geometry.area <= 0:
        raise BuildError("Polygon components remain empty/invalid after make_valid.")
    if event["repairAttempted"] or event["polygonExtraction"]:
        output = wrapped_mapping(geometry)
        # Reject unsupported serialization rather than silently losing a repaired hole.
        serialized = [output["coordinates"]] if output["type"] == "Polygon" else output["coordinates"]
        for polygon in serialized:
            for ring in polygon:
                unwrap_ring(ring)
    else:
        output = {"type": raw["type"], "coordinates": raw["coordinates"]}
    return output, geometry


@dataclass
class Region:
    source_id: str
    row: int
    name: str
    geometry: dict
    predicate: BaseGeometry


def prepare_source(collection: dict, source: dict) -> tuple[list[Region], dict]:
    if (not isinstance(collection, dict) or collection.get("type") != "FeatureCollection"
            or not isinstance(collection.get("features"), list)):
        raise BuildError(f"{source['file']}: expected a FeatureCollection with a features array.")
    counts = dict.fromkeys(("raw", "emitted", "excluded", "repairs", "repairFailures", "unlabeled",
                            "unsupported", "polygonExtractions", "discardedNonPolygonComponents",
                            "missingSourceID", "duplicateSourceID", "parentMatched", "parentAmbiguous",
                            "parentUnmatched", "parentUnlabeled"), 0)
    counts["raw"] = len(collection["features"])
    regions, issues, seen = [], [], set()
    for row, feature in enumerate(collection["features"], start=1):
        properties = feature.get("properties") if isinstance(feature, dict) else None
        properties = properties if isinstance(properties, dict) else {}
        source_id = properties.get("shapeID")
        if not isinstance(source_id, str) or not source_id.strip():
            source_id = f"{source['boundaryID']}:row:{row}"
            counts["missingSourceID"] += 1
            issues.append({"row": row, "sourceBoundaryID": source_id, "issue": "missing-shapeID; row fallback"})
        if source_id in seen:
            counts["duplicateSourceID"] += 1
            issues.append({"row": row, "sourceBoundaryID": source_id, "issue": "duplicate-shapeID; row tie-break"})
        seen.add(source_id)
        name = properties.get("shapeName")
        name = name.strip() if isinstance(name, str) else ""
        if not name:
            counts["unlabeled"] += 1
            issues.append({"row": row, "sourceBoundaryID": source_id, "issue": "unlabeled; not emitted"})
        event = {"repairAttempted": False, "polygonExtraction": False, "discardedNonPolygonComponents": 0}
        try:
            if not isinstance(feature, dict) or feature.get("type") != "Feature":
                raise BuildError("Not a GeoJSON Feature.")
            raw = feature.get("geometry")
            if not isinstance(raw, dict):
                raise BuildError("Missing geometry.")
            output, predicate = normalize_geometry(raw, event)
        except (BuildError, GEOSException, ValueError, TypeError, KeyError, IndexError, AttributeError) as error:
            counts["unsupported"] += 1
            counts["excluded"] += 1
            counts["repairFailures"] += int(event["repairAttempted"])
            issues.append({"row": row, "sourceBoundaryID": source_id, "issue": "excluded", "reason": str(error)})
        else:
            regions.append(Region(source_id, row, name, output, predicate))
            counts["emitted" if name else "excluded"] += 1
        counts["repairs"] += int(event["repairAttempted"])
        counts["polygonExtractions"] += int(event["polygonExtraction"])
        counts["discardedNonPolygonComponents"] += event["discardedNonPolygonComponents"]
        if event["repairAttempted"] or event["polygonExtraction"] or event["discardedNonPolygonComponents"]:
            issues.append({"row": row, "sourceBoundaryID": source_id, "issue": "geometry-processing", **event})
    regions.sort(key=lambda region: (region.source_id, region.row))
    return regions, {"counts": counts, "issues": issues}


def choose_parent(child: Region, parents: list[Region]) -> tuple[str | None, str]:
    point = child.predicate.representative_point()
    matches = []
    for parent in parents:
        left, bottom, right, top = parent.predicate.bounds
        x = point.x + longitude_shift(point.x, (left + right) / 2)
        if left <= x <= right and bottom <= point.y <= top and parent.predicate.covers(Point(x, point.y)):
            matches.append(parent)
    if len(matches) > 1:
        return None, "parentAmbiguous"
    if not matches:
        return None, "parentUnmatched"
    if not matches[0].name:
        return None, "parentUnlabeled"
    return matches[0].name, "parentMatched"


def source_note(sources: list[dict]) -> str:
    years = "; ".join(f"{s['country']} {s['level']} {s['year']}" for s in sources)
    return (
        f"geoBoundaries gbOpen, revision {COMMIT}; represented boundary years: {years}. "
        "Uses the upstream simplified datasets without additional simplification; invalid polygons "
        "may be repaired. Historical administrative approximations, not current addresses or global "
        "coverage. ADM2 parent names use unique representative-point containment, not official "
        "hierarchy or a photo's position; uncertain parents omitted. Per-source licenses, "
        "attribution, repairs and exclusions are recorded in places-manifest.json."
    )


def check_owned_outputs(output: Path) -> None:
    """Only replace our previously generated, unmodified pair; leave other files alone."""
    pack, manifest = output / PACK_NAME, output / MANIFEST_NAME
    if not pack.exists() and not manifest.exists() and not pack.is_symlink() and not manifest.is_symlink():
        return
    if pack.is_symlink() or manifest.is_symlink() or not pack.is_file() or not manifest.is_file():
        raise BuildError("Output collision: use an empty output directory for a custom/incomplete pack.")
    try:
        previous = json.loads(manifest.read_text(encoding="utf-8"))
        with pack.open("rb") as stream:
            info = fingerprint(stream)
        generated = previous["generated"]
        owned = (previous["generator"] == GENERATOR and generated["file"] == PACK_NAME
                 and generated["sha256"] == info["sha256"] and generated["bytes"] == info["bytes"])
    except (ValueError, KeyError, TypeError):
        owned = False
    if not owned:
        raise BuildError("Refusing to overwrite a custom or modified output; choose another --output directory.")


def build_pack(sources: list[dict], output: Path, source_directory: Path | None = None,
               download: bool = False, attribution_text: str | None = None) -> dict:
    validate_sources(sources)
    check_owned_outputs(output)
    if attribution_text is None:
        attribution_text = (DEFAULT_OUTPUT / "ATTRIBUTION.md").read_text(encoding="utf-8")
    output.mkdir(parents=True, exist_ok=True)
    countries, note = list(COUNTRIES.values()), source_note(sources)
    reports, feature_count = [], 0
    # Only this temporary directory and the two owned output names are written.
    with tempfile.TemporaryDirectory(prefix=".places-build-", dir=output) as temporary:
        stage = Path(temporary)
        parents: list[Region] = []
        with (stage / PACK_NAME).open("w", encoding="utf-8", newline="\n") as target:
            header = {"type": "FeatureCollection", "coverageCountries": countries, "sourceNote": note}
            target.write(compact(header)[:-1] + ',"features":[')
            for source in sources:
                with verified_source(source, source_directory, download) as (stream, verified):
                    # stdlib json loads ONE entire source, not a streaming JSON parser.
                    collection = json.load(stream)
                regions, report = prepare_source(collection, source)
                del collection
                if source["level"] == "ADM1":
                    parents = regions  # Replace prior country's parents, never match across countries.
                for region in regions:
                    if not region.name:
                        continue
                    label = [region.name]
                    if source["level"] == "ADM2":
                        parent_name, status = choose_parent(region, parents)
                        report["counts"][status] += 1
                        if parent_name is not None:
                            label.append(parent_name)
                        else:
                            report["issues"].append({"row": region.row, "sourceBoundaryID": region.source_id,
                                                     "issue": status})
                    label.append(source["country"])
                    feature = {
                        "type": "Feature", "geometry": region.geometry,
                        "properties": {"label": ", ".join(label), "level": source["level"],
                                       "country": source["country"], "iso": source["iso"],
                                       "sourceBoundaryID": region.source_id},
                    }
                    if feature_count:
                        target.write(",")
                    target.write(compact(feature))
                    feature_count += 1
                reports.append({"metadata": dict(source), "verified": verified, **report})
                del regions
                if source["level"] == "ADM2":
                    parents = []
            target.write("]}\n")
        with (stage / PACK_NAME).open("rb") as stream:
            generated = {"file": PACK_NAME, **fingerprint(stream), "featureCount": feature_count}
            stream.seek(0)
            runtime = {"schemaVersion": 1, "version": runtime_version(stream),
                       "coverageDescription": runtime_coverage_description(countries, feature_count)}
        totals = {key: sum(report["counts"][key] for report in reports) for key in reports[0]["counts"]}
        attribution_bytes = attribution_text.encode("utf-8")
        manifest = {
            "schemaVersion": 1, "generator": GENERATOR,
            "sourceMetadataSHA256": hashlib.sha256(compact(sources).encode("utf-8")).hexdigest(),
            "shapelyVersion": shapely.__version__, "geosVersion": shapely.geos_version_string,
            "coverageCountries": countries, "sourceNote": note, "parentMethod": PARENT_METHOD,
            "additionalSimplification": False, "sources": reports, "totals": totals,
            "attribution": {"text": attribution_text, "licenseURLs": LICENSE_URLS,
                            "sha256": hashlib.sha256(attribution_bytes).hexdigest(), "bytes": len(attribution_bytes)},
            "generated": generated, "runtime": runtime,
        }
        (stage / MANIFEST_NAME).write_text(compact(manifest) + "\n", encoding="utf-8", newline="\n")
        check_owned_outputs(output)
        # Each replacement is atomic, but the pair is NOT a cross-file transaction.
        (stage / PACK_NAME).replace(output / PACK_NAME)
        (stage / MANIFEST_NAME).replace(output / MANIFEST_NAME)
    return manifest


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--source-directory", type=Path, help=f"Offline public cache (default: {DEFAULT_SOURCE_DIRECTORY})")
    mode.add_argument("--download", action="store_true", help="Download only the eight pinned public URLs; no token")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Output directory (default: Resources/Places)")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = argument_parser().parse_args(argv)
    directory = None if args.download else (args.source_directory or DEFAULT_SOURCE_DIRECTORY)
    try:
        manifest = build_pack(load_sources(), args.output, directory, args.download)
    except (OSError, ValueError, GEOSException) as error:
        print(f"Places build failed: {error}", file=sys.stderr)
        return 1
    for source in manifest["sources"]:
        counts = source["counts"]
        print(f"{source['metadata']['iso']}/{source['metadata']['level']}: "
              f"raw={counts['raw']} emitted={counts['emitted']} repairs={counts['repairs']} "
              f"excluded={counts['excluded']} unlabeled={counts['unlabeled']} "
              f"unsupported={counts['unsupported']} parentAmbiguous={counts['parentAmbiguous']}")
    generated = manifest["generated"]
    print(f"{generated['file']}: {generated['featureCount']} features, {generated['bytes']} bytes, "
          f"SHA-256 {generated['sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())