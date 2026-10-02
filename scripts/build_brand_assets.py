"""Build/verify local B02 assets with Pillow. No generation API or network access."""

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageOps


ROOT = Path(__file__).resolve().parent.parent
BRANDING = ROOT / "Resources" / "Branding"
SOURCE = BRANDING / "B02-selected.png"
CATALOG = ROOT / "App" / "Assets.xcassets"
SOURCE_SHA = "5c5dd3cfb41febfccdffbd4feacaf5e9033d8d9c49a26d3551a74f3f70b4500f"
ICON_BACKGROUND = (43, 44, 46)


def square(size: int) -> Image.Image:
    with Image.open(SOURCE) as image:
        tile = ImageOps.contain(image.convert("RGBA"), (size, size), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(tile, ((size - tile.width) // 2, (size - tile.height) // 2))
    return canvas


def expected_images() -> dict[Path, Image.Image]:
    icon = Image.new("RGBA", (1024, 1024), (*ICON_BACKGROUND, 255))
    icon.alpha_composite(square(1024))
    return {
        CATALOG / "AppIcon.appiconset" / "AppIcon.png": icon.convert("RGB"),
        CATALOG / "LaunchLogo.imageset" / "LaunchLogo.png": square(192),
        CATALOG / "LaunchLogo.imageset" / "LaunchLogo@2x.png": square(384),
        CATALOG / "LaunchLogo.imageset" / "LaunchLogo@3x.png": square(576),
    }


def verify() -> None:
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == SOURCE_SHA
    with Image.open(SOURCE) as source:
        assert source.size == (676, 702) and source.mode == "RGBA"
        source.verify()
    manifest = json.loads((BRANDING / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["source_sha256"] == SOURCE_SHA
    expected = expected_images()
    assert len(manifest["outputs"]) == len(expected)
    for entry in manifest["outputs"]:
        path = ROOT / entry["path"]
        assert path in expected
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"], path
        with Image.open(path) as actual:
            assert actual.format == "PNG" and actual.size == expected[path].size
            assert actual.mode == expected[path].mode
            difference = ImageChops.difference(actual, expected[path])
            assert all(high == 0 for _, high in difference.getextrema()), path
            if actual.mode == "RGBA":
                assert actual.getchannel("A").getextrema() == (0, 255)
            else:
                assert "transparency" not in actual.info
    print(json.dumps({"verified": True, "selected_source_unchanged": True,
                      "app_icon_opaque": True, "launch_scales": [1, 2, 3],
                      "native_build_verified": False}))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Import the selected transparent PNG once")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        verify()
        return
    BRANDING.mkdir(parents=True, exist_ok=True)
    if args.source is not None:
        payload = args.source.read_bytes()
        if hashlib.sha256(payload).hexdigest() != SOURCE_SHA:
            raise ValueError("Input is not the user-selected B02 transparent tile.")
        if SOURCE.exists():
            assert SOURCE.read_bytes() == payload
        else:
            with SOURCE.open("xb") as stream:
                stream.write(payload)
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == SOURCE_SHA
    outputs = []
    for path, image in expected_images().items():
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as stream:
            image.save(stream, format="PNG")
        outputs.append({"path": path.relative_to(ROOT).as_posix(), "mode": image.mode,
                        "dimensions": list(image.size),
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    manifest = {"selection": "AlbumVsPhotoSearch_2026-10-01/B02; selected 2026-10-02",
                "source": SOURCE.relative_to(ROOT).as_posix(), "source_sha256": SOURCE_SHA,
                "process": "Aspect-fit selected tile; no redraw, recolour, stretch or outside shadow",
                "app_icon_background_rgb": list(ICON_BACKGROUND), "launch_size_points": 192,
                "outputs": outputs}
    with (BRANDING / "manifest.json").open("x", encoding="utf-8") as stream:
        json.dump(manifest, stream, ensure_ascii=False, indent=2)
    verify()


if __name__ == "__main__":
    main()