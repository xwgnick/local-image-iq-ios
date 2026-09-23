# 0.3.1 (7) · Index overlap and offline places

## Current status — SUCCESS first attempt; IPA downloaded and verified

Source HEAD `18ad52d37690ecfbf92b63a21285a6c3e8e753d4`;
[CI 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
/ [job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763).
**SUCCESS on the first attempt; no fix/retry needed**, with `TEST SUCCEEDED` and
`BUILD SUCCEEDED`. Native/parity/UI tests, simulator/device App resource checks,
iPhoneOS arm64 Release build and IPA validation passed. The build 7 IPA was
actually downloaded completely using bounded-memory streaming, local length and
SHA-256 verified, and the post-download report written and checked. This
documentation edit records supplied verified evidence without running commands,
tests, downloads or CI queries. Build 6 remains history, not a substitute for
this run's results below.

## Install/use

Use the verified build 7 IPA to overwrite 0.3.0 with the same Sideloadly
account and effective Bundle ID. Do not
uninstall, clear the index or download all originals. Open **Library → Index / resume**
once to backfill places, keeping the app open and network off; resume there if
interrupted. Still-valid 0.3.0 SigLIP 2 image vectors are reused without pixel fetch
or image encoding; only new/changed photos need normal image encoding. This is
not a whole-image-index rebuild. An older CLIP index still needs the separate
model migration; it cannot be reused as SigLIP 2 vectors.

Existing location weight **0.6** now has real place-label input for covered photos
after backfill, so rankings may change as intended. The default weight and centered
scoring formula are not silently changed to conceal that effect. Normal use is
enough afterwards; no extra user diagnostic queries or screenshot round is required.

## Indexing

One structured child prepares the next asset's cache entry/local preview while
the parent encodes and commits the current asset. Only one model pair is loaded;
model inference itself remains serial. Current plus one-ahead is the explicitly
approved pipeline, not an arbitrary full-library batch limit.

Commits and progress remain in snapshot order; successful saves finish before
their counters publish. Failed/skipped observations follow that same order, and
speculative preparation is not counted as completed. Reused
image rows do not fetch pixels or run the image encoder. Cancellation signals
the prefetch child and waits for Swift child completion. PhotoKit cancellation
has no acknowledgement API: late callbacks are ignored by the existing gate,
not claimed to have already stopped at the OS level. No new deadlines/retries,
network policy changes, original-data requests, precision changes or model copies.

All **15 IndexPipelineTests passed** in build 7, checking overlap and
lifecycle/order. This executed result does not measure iPhone speedup. If neural
inference dominates, overlapping the other stages will have limited benefit.

## Places

Public pinned geoBoundaries gbOpen sources for China, France, Germany and the
Netherlands, ADM1/ADM2, are required app resources in the normal build path,
including model-free CI. This run's simulator/device App resource gates and
IPA validation passed, confirming inclusion. This is not global/address/POI
coverage. Both image and text use the same
`google/siglip2-base-patch16-224` revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`, unchanged FP32/preprocessing and
`photokit-preview-v1`. Semantic modelVersion remains
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.

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
“No GPS” means the accessible asset has no stored location; “no usable pack” and
“outside coverage” both mean usable coordinates were present, but there was no
resolver coverage/containing region. Unavailable is not evidence of absent GPS.
Observations include photos whose image indexing failed; found labels and durable
saved place updates are different counts. These are scan observations (possibly
partial), not persisted GPS or permanent whole-library totals. No private-library
GPS/coverage count or percentage is established by public reference-point tests.

## Public resource provenance

Sources: revision `9469f09592ced973a3448cf66b6100b741b64c0d`, hashes and original
license/source/year metadata in [place_sources.json](../scripts/place_sources.json).
Attribution: [ATTRIBUTION.md](../Resources/Places/ATTRIBUTION.md), also embedded in
the generated manifest shipped with the app. No private coordinates are build inputs.

Build preserves upstream simplified boundaries, no further simplification. Invalid
polygons are repaired if possible; all exclusions/repairs are reported. ADM2 parent
names use unique same-country representative-point containment, not an authoritative
hierarchy. Historical names and incomplete boundaries remain possible.

Represented years (ADM1 / ADM2): China **2019 / 2017**, France **2022 / 2022**,
Germany **2021 / 2021**, Netherlands **2022 / 2022**. These historical administrative
approximations do not certify current names, borders or street addresses. The
collection attribution and per-source license records travel with the generated
manifest; preserving them is not independent redistribution/legal approval.

The [public manifest](../Resources/Places/places-manifest.json) records the generated
pack. **Actual device-package checks** confirm **2,943 features, 15,175,079 GeoJSON
bytes, CHN/FRA/DEU/NLD and 8 sources**; GeoJSON
SHA-256 `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`.
Device-package manifest SHA-256:
`0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`.
These are final device-package results, not just local source metadata. The
generation record reports one unnamed feature excluded and no geometry repairs.
This edit did not read the large geometry, run Node or recompute the hash.

CI regenerates from exact public URLs and verifies upstream hashes. The generated
pack Node gate, separate built-app checks and device-packager/IPA gates all passed,
verifying pack/manifest hashes, counts, countries, attribution and required IPA
entries. Both native BundledPlacesTests passed against the actual host-app pack:
hash/count checks and four public city reference points plus New York outside
coverage. These are not personal-photo or real-GPS coverage tests. See
[resource contracts](../Resources/Places/README.md).

## Validation status

Previously recorded local checks: 25 geography-builder and 30 model-export contract
tests passed; Node source, pack and device-packager self-tests passed. These are
prior local results, not rerun by this edit or substitutes for native/device tests.

Verified results from **35840838147**:

| Gate | Result |
| --- | --- |
| Source/static checks | 30 passed. |
| Public-place build and test_places step | Passed. 25 is the code/prior-local declared test count, not a separately observed CI log total here. |
| Swift core | 79 passed. |
| App | 215 total: 214 passed, 1 physical-device file-protection skip on simulator, 0 failures. The following App suites are included, not extra tests. |
| IndexPipelineTests | 15 passed. |
| PlaceAvailabilityTests | 17 passed. |
| BundledPlacesTests | 2 passed: host-app hash/counts and public-city coverage including New York outside. |
| IndexPlacesPresentationTests | 3 passed. |
| GeneratedModelParityTests | All 7 passed in 67.736 seconds. |
| UI | All 7 passed in 202.143 seconds; TEST SUCCEEDED. |
| Simulator/device App resources, device build and IPA validation | Passed; iPhoneOS arm64 Release BUILD SUCCEEDED. |
| Download | Complete; bounded-memory stream, local byte length/SHA-256 verified, post-download report written and checked. |

[Model-report artifact 10741671604](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741671604)
records **23 cases, 92 comparisons**: minimum cosine `0.9999999999960657`, maximum
raw component difference `0.000011444091796875`, paired-matrix maximum difference
`1.8557397291063538e-7`. ModelVersion is unchanged; export markers preceding
XCTest do not override the later passing native tests.

### Verified build 7 package and visual-review scope

- Device report: **0.3.1, app build 7; iphoneos18.5; arm64 Release; unsigned;
	Xcode 16.4; minimum iOS 17.0**.
- [IPA artifact 10741731376](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741731376):
	outer **1,414,628,123 bytes**, inner IPA **1,414,620,805 bytes**;
	IPA SHA-256 `98fb537004a64adaa84b1ba15d798acaf71a0684555275faddc647d1adafd8d6`.
- Verified local download:
	[build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa).
	Still unsigned; local Sideloadly signing is required before installation.
- **20 native screenshots retrieved; only 3 new index/place frames reviewed** in
	[build/ui-review/35840838147/index-places-contact.jpg](../build/ui-review/35840838147/index-places-contact.jpg),
	a **960×680** contact sheet: Library after backfill, Library with zero GPS,
	Settings with locations not checked. Visible content is readable. Disclosures
	are collapsed, so **not every expanded internal counter was visually checked**.
	Counts are synthetic, not user GPS observations; the other 17 frames were not
	reviewed this round.

### Remaining boundaries

User-side signing, overwrite installation and the one-pass places backfill are not
yet confirmed for build 7. Physical-iPhone behavior, file protection, speed,
memory/heat and private-library GPS/coverage are not established by cloud tests,
device-SDK builds or synthetic screenshots. No speedup or coverage is promised,
and no extra user diagnostic round is requested. Model/geography redistribution
license review and formal release configuration remain open. Canonical delivery
record: [BUILD_STATUS.md](BUILD_STATUS.md).