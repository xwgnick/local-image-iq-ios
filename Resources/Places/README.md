# Required four-country offline Places pack

Version 0.3.1 (build 7) bundles public geoBoundaries gbOpen ADM1 and ADM2 boundaries for China (CHN), France (FRA), Germany (DEU), and the Netherlands (NLD). Every normal manual CI run generates the pack, including model-free runs. No extra workflow input or separate release path is needed.

## Inputs and generation

- [Pinned source configuration](../../scripts/place_sources.json): exactly eight public URLs at revision `9469f09592ced973a3448cf66b6100b741b64c0d`, with public source SHA-256 pins, boundary years, source identities, attribution and license metadata. These hashes identify public geometry, not private data.
- [Generator](../../scripts/build_places.py): Python 3.11 plus Shapely 2.1.2. It does not import Core ML or read photos, photo coordinates, indexes or model resources. Download mode verifies each pinned hash before parsing; it does not follow redirects or discover new URLs. Package installation is a separate dependency step, not a geometry source.
- The generator also requires its checked-in ATTRIBUTION.md input in this directory, maintained alongside the generator. A missing attribution input is an error, not permission to generate placeholder license text or skip the pack. Its complete text and digest, plus license URLs, are embedded in the generated manifest.

Actual CI commands, run from this standalone repository root:

```sh
python -m pip install shapely==2.1.2
python scripts/build_places.py --download
node scripts/check_places.mjs --pack-dir Resources/Places
```

CI uses the existing `actions/setup-python` Python 3.11 on the isolated macOS runner. Shapely is installed there, outside `.model-env`; Core ML dependencies and model conversion remain in their existing separate environment. Generation and validation run before XcodeGen, regardless of `include_models`.

The actual generator CLI also supports offline `--source-directory DIRECTORY` instead of `--download`, and optional `--output DIRECTORY`. With neither input option it uses the existing public geography cache in the user's home directory. Offline source files must match the same eight pins. CI always uses the explicit public download mode, not a developer's cache.

Default generated files are named Places.geojson and places-manifest.json in this directory. They are not tracked. Only those generated names and the optional local Sources cache directory are ignored; this README, the attribution input and the source configuration are not blanket-ignored. The generator writes no raw source cache here in download mode.

## Contracts and bundle gates

[check_places.mjs](../../scripts/check_places.mjs) exports `validatePlaces(directory, { appBundle })`, reused by [package_device.mjs](../../scripts/package_device.mjs).

```sh
node scripts/check_places.mjs
node scripts/check_places.mjs --self-test
node scripts/package_device.mjs --self-test
node scripts/check_places.mjs --app-dir build/DerivedData/Build/Products/Debug-iphonesimulator/LocalImageIQ.app
node scripts/package_device.mjs build/DeviceProducts/Release-iphoneos/LocalImageIQ.app build/device
```

- The no-argument check validates only pinned source metadata. It works without generated geography or models; it is not a pack-readiness claim. CI then always generates and checks the real pack.
- Explicit `--pack-dir` and `--app-dir` checks never skip absent data. They require both files, exact filename case, manifest schema, generated SHA-256 and byte length, nonempty country/level coverage, all eight matching pinned source records, positive emitted counts, source totals equal to actual feature counts, supported polygon structure, source notes and intact embedded attribution/license metadata. They do not redownload or independently rehash absent raw sources; the generator performs that upstream hash check.
- App search order is the app root, Places, then Resources/Places. The manifest must be beside the selected GeoJSON. There is no recursive search into test bundles, frameworks, Models, or other build products. The simulated app is checked after tests; device packaging independently checks the Release-iphoneos app before creating the IPA, then requires both paths in its ZIP entries.
- [project.yml](../../project.yml) puts this directory's contents in the app resource phase, excluding README and the optional Sources directory. Both generated files are app resources, not test-only resources. The manifest carries licenses/provenance even when the README is excluded.
- The device report's `places` object includes resolved bundle-relative paths, pack/manifest hashes and bytes, feature count, country coverage, source count and per-source summaries, represented years, source note and attribution digest. The CI evidence artifact also retains the generated manifest.
- Self-tests use only invented polygon fixtures and temporary files, removed in `finally`. They check rejection/report/path contracts without fetching public geometry, loading models, using photo/GPS samples or claiming a native build. There are no arbitrary file-size, feature-count or download-time ceilings.

The commands above describe runnable gates; their presence is not evidence that this change has been executed or that a real generated pack has passed. Local generator tests and generation are handled separately from this CI/packaging change.

## Coverage, attribution and performance boundaries

The pack uses the upstream simplified historical boundaries without additional simplification. CHN uses represented years 2019/2017, FRA 2022/2022, DEU 2021/2021, and NLD 2022/2022 (ADM1/ADM2). ADM2 does not mean the same administrative unit in every country. Parent labels are approximate unique representative-point matches to same-country ADM1; ambiguous, absent or unnamed parents are omitted, not guessed. Repairs, exclusions and parent outcomes remain in the manifest.

The generated manifest preserves geoBoundaries attribution plus the individual source licenses: Public Domain and PDDL for the two CHN sources, Etalab Open License 2.0 for FRA, Data license Germany — Attribution 2.0 for DEU, and CC0 for NLD. Refer to the pinned metadata and the bundled full attribution text for the actual sources and license links; this README is not a replacement license grant.

Country coverage is not a guarantee that every photo has a readable location or lies in an emitted region. This is not a global street-address database, online geocoding or current-border certification. These gates do not prove real-iPhone indexing speed or lookup performance. The one-ahead indexing implementation belongs to a separate app change; these files do not alter it, SigLIP2 source identity, 768-dimensional embeddings, image policy, preprocessing or model precision.