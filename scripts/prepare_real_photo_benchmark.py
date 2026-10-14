"""Explicit download of a deterministic, CC-BY-only public COCO diagnostic corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.request
import zipfile

from model_contract import canonical_json, require, sha256_file, write_json

ARCHIVE_URL = "https://s3.amazonaws.com/images.cocodataset.org/annotations/annotations_trainval2017.zip"
ARCHIVE_SHA256 = "113a836d90195ee1f884e704da6304dfaaecff1f023f49b6ca93c4aaae470268"
ANNOTATIONS_SHA256 = "e8c7f7908f1d7278341fae127d0da654f102f11bd7b21d8aeefa635b8c810b6f"
LICENSE_URL = "https://creativecommons.org/licenses/by/2.0/"
SEED = "piankexun-coco-ccby-top5-v1"
IMAGE_COUNT = 240
PER_CATEGORY = 8
CATEGORIES = (
    ("person", "人"), ("car", "汽车"), ("bicycle", "自行车"), ("motorcycle", "摩托车"),
    ("bus", "公交车"), ("train", "火车"), ("airplane", "飞机"), ("boat", "船"),
    ("bird", "鸟"), ("cat", "猫"), ("dog", "狗"), ("horse", "马"),
    ("cow", "牛"), ("elephant", "大象"), ("zebra", "斑马"), ("giraffe", "长颈鹿"),
    ("pizza", "披萨"), ("cake", "蛋糕"), ("chair", "椅子"), ("couch", "沙发"),
    ("bed", "床"), ("dining table", "餐桌"), ("laptop", "笔记本电脑"), ("cell phone", "手机"),
)


def select_images(document: dict) -> tuple[list[dict], dict[int, set[str]]]:
    licenses = {item["id"]: item["url"].replace("http://", "https://") for item in document["licenses"]}
    allowed = {key for key, url in licenses.items() if url == LICENSE_URL}
    require(bool(allowed), "Annotations do not identify the permitted CC BY 2.0 license")
    names = {item["id"]: item["name"] for item in document["categories"]}
    require(len(names) == len(document["categories"]), "Duplicate category IDs")
    images = {item["id"]: item for item in document["images"]}
    require(len(images) == len(document["images"]), "Duplicate image IDs")
    labels: dict[int, set[str]] = {key: set() for key in images}
    for annotation in document["annotations"]:
        require(annotation["image_id"] in images and annotation["category_id"] in names,
                "Annotation references an unknown image or category")
        labels[annotation["image_id"]].add(names[annotation["category_id"]])
    eligible = [key for key, image in images.items() if image["license"] in allowed]
    ordered = sorted(eligible, key=lambda key: hashlib.sha256(f"{SEED}:{key}".encode()).hexdigest())
    selected: set[int] = set()
    for category, _ in CATEGORIES:
        candidates = [key for key in ordered if category in labels[key]]
        require(len(candidates) >= PER_CATEGORY, f"Too few licensed photos for {category}")
        selected.update(candidates[:PER_CATEGORY])
    require(len(selected) <= IMAGE_COUNT and len(eligible) >= IMAGE_COUNT, "Insufficient fixed-size corpus")
    for key in ordered:
        if len(selected) == IMAGE_COUNT:
            break
        selected.add(key)
    result = [images[key] for key in ordered if key in selected]
    require(len(result) == IMAGE_COUNT, "Corpus must contain exactly 240 distinct photos")
    for category, _ in CATEGORIES:
        require(sum(category in labels[item["id"]] for item in result) >= PER_CATEGORY,
                f"Selected corpus lost positive coverage for {category}")
    return result, labels


def download(url: str, destination: Path, max_bytes: int) -> None:
    require(url.startswith("https://s3.amazonaws.com/images.cocodataset.org/"), "Unexpected download origin")
    require(not destination.exists(), f"Refusing to replace {destination}")
    partial = destination.with_suffix(destination.suffix + ".part")
    require(not partial.exists(), f"Partial download already exists: {partial}")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as response, partial.open("xb") as stream:
                length = 0
                while chunk := response.read(1024 * 1024):
                    length += len(chunk)
                    require(length <= max_bytes, f"Download exceeds size limit: {url}")
                    stream.write(chunk)
                require(length > 0, f"Empty download: {url}")
            partial.replace(destination)
            return
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                raise
            print(f"Retrying public corpus GET after HTTP {error.code}: {url}", flush=True)
            time.sleep(2 ** attempt)
        finally:
            partial.unlink(missing_ok=True)


def prepare(output: Path, cache: Path) -> dict:
    require(not output.exists(), "Refusing to replace an existing benchmark corpus")
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "annotations_trainval2017.zip"
    if not archive.exists():
        download(ARCHIVE_URL, archive, 300 * 1024 * 1024)
    require(sha256_file(archive) == ARCHIVE_SHA256, "Official annotation archive SHA-256 mismatch")
    with zipfile.ZipFile(archive) as bundle:
        data = bundle.read("annotations/instances_val2017.json")
    require(hashlib.sha256(data).hexdigest() == ANNOTATIONS_SHA256, "Validation annotations SHA-256 mismatch")
    document = json.loads(data)
    require(len(document["images"]) == 5000, "Unexpected COCO validation split")
    images, labels = select_images(document)
    output.mkdir(parents=True)
    manifest = {
        "schemaVersion": 1, "dataset": "COCO2017-val-CCBY2-top5-v1",
        "annotationsURL": ARCHIVE_URL, "annotationsSHA256": ANNOTATIONS_SHA256,
        "annotationsAttribution": "COCO Consortium; annotations licensed CC BY 4.0",
        "annotationsLicenseURL": "https://creativecommons.org/licenses/by/4.0/",
        "termsURL": "https://cocodataset.org/dataset/termsofuse.htm",
        "selectionSeed": SEED, "selection": "Fixed hash order; eight positives per category, then fill to 240; no model scores used",
        "relevance": "COCO object-presence labels only, not human judgments of caption, prominence, aesthetics or personal relevance",
        "imageAttribution": "Original Flickr source and COCO image URLs retained per image; no authors supplied by COCO annotations",
        "transform": "Original JPEG bytes retained for native app preprocessing; no photos redistributed as CI artifacts",
        "images": [], "queries": [],
    }
    for index, image in enumerate(images):
        name = image["file_name"]
        require(re.fullmatch(r"\d{12}\.jpg", name) is not None and int(name[:12]) == image["id"],
                "Unexpected COCO image filename")
        url = f"https://s3.amazonaws.com/images.cocodataset.org/val2017/{name}"
        destination = output / name
        download(url, destination, 20 * 1024 * 1024)
        manifest["images"].append({
            "id": str(image["id"]), "file": name, "sha256": sha256_file(destination),
            "categories": sorted(labels[image["id"]]), "sourceURL": url,
            "flickrURL": image["flickr_url"], "licenseURL": LICENSE_URL,
            "width": image["width"], "height": image["height"],
        })
        if (index + 1) % 40 == 0:
            print(f"Downloaded {index + 1}/{IMAGE_COUNT} CC-BY photos", flush=True)
    for category, chinese in CATEGORIES:
        for suffix, text in (("noun", chinese), ("phrase", f"有{chinese}的照片")):
            manifest["queries"].append({"id": category + "-" + suffix, "text": text, "category": category})
    manifest["corpusSHA256"] = hashlib.sha256(canonical_json(manifest)).hexdigest()
    write_json(output / "manifest.json", manifest)
    print(f"Prepared {len(images)} public photos, {len(manifest['queries'])} fixed Chinese queries; "
          f"corpus={manifest['corpusSHA256']}", flush=True)
    return manifest


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build") / "RealPhotoBenchmark")
    parser.add_argument("--cache", type=Path, default=Path("build") / "coco-cache")
    return parser.parse_args(argv)


if __name__ == "__main__":
    args = arguments()
    prepare(args.output, args.cache)
