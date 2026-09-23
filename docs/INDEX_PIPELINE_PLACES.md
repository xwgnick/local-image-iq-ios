# 0.3.1 (7) · Index overlap and offline places

## Install/use

Overwrite 0.3.0 using the same Sideloadly account and effective Bundle ID. Do not
uninstall, clear the index or download all originals. Open **Library → Index / resume**
once to backfill places. Unchanged SigLIP2 image vectors are reused; only new or
changed photos need image encoding. Existing location weight 0.6 now has real
place-label input for covered photos, so rankings may change as intended.

## Indexing

One structured child prepares the next asset's cache entry/local preview while
the parent encodes and commits the current asset. Only one model pair is loaded;
model inference itself remains serial. Current plus one-ahead is the explicitly
approved pipeline, not an arbitrary full-library batch limit.

Commits and progress remain in snapshot order, after durable storage. Reused
image rows do not fetch pixels or run the image encoder. Cancellation signals
the prefetch child and waits for Swift child completion. PhotoKit cancellation
has no acknowledgement API: late callbacks are ignored by the existing gate,
not claimed to have already stopped at the OS level. No new deadlines/retries,
network policy changes, original-data requests, precision changes or model copies.

Tests prove overlap and lifecycle/order, not a measured iPhone speedup. If neural
inference dominates, overlapping the other stages will have limited benefit.

## Places

Public pinned geoBoundaries gbOpen sources for China, France, Germany and the
Netherlands, ADM1/ADM2, are built into the app. This is not global/address/POI
coverage. The model and `photokit-preview-v1` cache identity stay unchanged.

PhotoKit supplies each authorized photo's stored location; no current-device
location permission or online reverse geocoder is used. Coordinates are used
only in memory to derive an administrative label, never saved or uploaded.
Coordinates with an unknown accuracy estimate retain the old coordinate-only
lookup behavior. Invalid coordinates or inaccessible photos are reported separately.

Every scan checks places even for image-cache hits. Geography changes, changed
labels and removed GPS can update/remove location embeddings without re-encoding
the image. Distinct place texts reuse persisted vectors where compatible. The
existing centered-location formula and default weight remain unchanged.

Library distinguishes last/current-scan observations (with GPS, labels found,
no GPS, no usable pack, outside coverage, unavailable) from saved place labels.
Before locations are checked the UI says unknown/not checked, not zero GPS.

## Public resource provenance

Sources: revision `9469f09592ced973a3448cf66b6100b741b64c0d`, hashes and original
license/source/year metadata in [place_sources.json](../scripts/place_sources.json).
Attribution: [ATTRIBUTION.md](../Resources/Places/ATTRIBUTION.md), also embedded in
the generated manifest shipped with the app. No private coordinates are build inputs.

Build preserves upstream simplified boundaries, no further simplification. Invalid
polygons are repaired if possible; all exclusions/repairs are reported. ADM2 parent
names use unique same-country representative-point containment, not an authoritative
hierarchy. Historical names and incomplete boundaries remain possible.

Local generation: 2,943 features, 15,175,079 GeoJSON bytes,
SHA-256 `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`.
One unnamed feature excluded; no geometry repairs. CI regenerates from exact
public URLs and verifies source hashes. Node checks verify pack/manifest hashes,
counts, countries and attribution in the built app and final IPA. Native tests
resolve four public city coordinates and reject an uncovered New York point.

## Validation status

Local: 25 geography-builder and 30 model-export contract tests passed; Node source,
pack and device-packager self-tests passed. Native pipeline/places/UI tests,
four-country bundle checks and replacement IPA are pending cloud validation.