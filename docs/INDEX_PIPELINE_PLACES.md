# 0.3.2 (8) · Four-worker indexing and unchanged offline places

## Current status — build 8 passed first attempt; IPA downloaded and verified

Source `b40d2faaf11b2f499779881b4863325fa7dae659`;
[CI 35848409845](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845)
/ [job 107140049230](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/job/107140049230):
**SUCCESS on the first attempt**. Core, export, places, model/App resource checks,
native/UI tests and device packaging passed. App version **0.3.2 / build 8** and
the completed local IPA download/length/hash are verified. This edit only records
supplied verified results: no commands, tests, CI queries/retries, downloads or
phone actions. Older build 7 evidence is preserved separately below.

## Install/use

Use the verified build 8 package linked below; overwrite with the same Sideloadly
account and effective Bundle ID, without uninstalling or clearing index/cache.
Normal **Library → Index / resume** reuses still-valid
0.3.0/0.3.1 SigLIP 2 image vectors without preview fetch or image inference, while
checking/backfilling places. Only new/changed photos need normal image encoding.
Keep the app foreground and network off; resume there if interrupted. No index
clear, whole-image rebuild or originals download is needed for this update. An
older CLIP index still needs its separate model migration; CLIP vectors cannot
be reused as SigLIP 2 vectors.

For the user's requested **from-zero speed test**, clearing the index is an
**optional explicit choice after installation**: choose **Settings → Clear index**,
then **Library → Index / resume**, with network off and the app foreground. It
deletes existing App index/cache data, **not system-library photos**, and requires
reindexing. It is not an installation or
normal-resume prerequisite. Compare **0.3.1 vs 0.3.2 with the same geography pack**,
both from empty indexes, using the same phone, authorized photo set/count, network
off and comparable starting temperature/heat and power conditions. Do not compare
old cold indexing with new cache reuse. No actual phone speed/memory test has been
performed; no index rescue, extra diagnostics, test queries or screenshots are required.

Existing location weight **0.6** now has real place-label input for covered photos
after backfill, as introduced in build 7; rankings may change as intended when
labels are added. Build 8 changes neither the weight nor the centered score.

## Indexing — fixed four-slot rolling window, explicitly requested by the user

[PhotoIndexWorker.swift](../App/State/PhotoIndexWorker.swift) implements four
structured child slots. Each child reads the cache, obtains the PhotoKit preview
when needed, preprocesses it and performs image inference on its assigned
independent encoder actor. This replaces build 7's one-ahead preview prefetch plus
serial image inference; merely adding tasks around one image actor would not do so.

The window counts **all submitted-but-not-yet-committed items**, including finished
results waiting for earlier snapshot positions. Running + finished pending items
cannot exceed **4**. A slow head can stall admission; an out-of-order completion
does not free a slot or permit a fifth outstanding item. Each ordered commit frees
one slot for its successor immediately, without waiting for the other three slots:
**not a four-item batch barrier**. No unbounded completion queue or accumulated
preview-pixel backlog is introduced. Finished results retain embeddings/errors and
cache metadata, not preview images; the existing library snapshot/cache still has
its own memory cost, so this is not a claim that total App memory is constant.

### Model ownership and memory trade-off

[CoreMLEncoders.swift](../App/Inference/CoreMLEncoders.swift) returns four production
image actors, each with its own image `MLModel`. Slot 0 reuses the persistent
primary image encoder, avoiding a fifth image instance. The other three image-only
actors belong to the index call and lazily load their models only when used.
After all children drain and the call exits, the three extra actors/models are no
longer retained by the indexing scope. Immediate OS/Core ML memory reclamation has
not been measured or guaranteed.

The central actor still owns **ONE text model and ONE tokenizer**. Location text
reuse/deduplication remains centralized; this is **not four text models or four
paired encoders**. The explicit trade-off is up to **three additional image model
instances**, plus concurrent preprocessing/inference intermediates. Cache hits
bypass PhotoKit image requests and image inference; a cache-only run never loads
the three extra models (the normal persistent primary pair is still prepared).

### Ordered commit, cancellation and unchanged policy

Commits and progress remain in snapshot order; successful saves finish before
their counters publish. Failed/skipped observations follow that same order, and
speculative work is not counted as completed. Only the parent resolves locations,
looks up/deduplicates place-text vectors, writes storage and publishes progress;
children do none of that. The existing revision/authorization validation and
fatal-versus-skippable error handling remain.

Cancellation or fatal scope exit cancels and **awaits all up-to-four children**,
including in-flight PhotoKit work and image predictions, before returning to the
serialized AppState chain. Synchronous Core ML predictions may finish before
cancellation can drain them. PhotoKit has no cancellation acknowledgement API:
late callbacks are ignored by the existing gate, not claimed to have stopped at
the OS level. Already committed rows remain reusable on normal resume.

No new job timeout, automatic retries, arbitrary library/row/byte limits, batch
orchestration or network policy change. Four is the user-requested concurrency
window, not a cap on the photo library. FP32 and original-download policy remain
unchanged. Four independent actors make concurrent work possible; they do not
prove physical GPU/ANE overlap, **4× speed**, lower elapsed time or acceptable
phone memory/heat. Those remain unmeasured, not additional user diagnostic tasks.

## Places

Public pinned geoBoundaries gbOpen sources for China, France, Germany and the
Netherlands, ADM1/ADM2, are required app resources in the normal build path,
including model-free CI. The same **2,943-feature** pack is retained in build 8;
this run's simulator/device App resource gates and IPA validation passed, and its
device report confirms the unchanged pack identity. This is not global/address/POI
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
pack. **Build 8's verified device report** confirms the same **2,943 features, 15,175,079 GeoJSON
bytes, CHN/FRA/DEU/NLD and 8 sources**; GeoJSON
SHA-256 `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`.
Device-package manifest SHA-256:
`0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`.
This independently confirms the build 8 package identity, not merely local source metadata. The
generation record reports one unnamed feature excluded and no geometry repairs.
This edit did not read the large geometry, run Node or recompute the hash.

CI regenerates from exact public URLs and verifies upstream hashes. In build 8,
the places, model/App resource and device-packager/IPA gates all passed,
verifying pack/manifest hashes, counts, countries, attribution and required IPA
entries. Native BundledPlacesTests also passed against the actual host-app pack:
hash/count checks and four public city reference points plus New York outside
coverage. These are not personal-photo or real-GPS coverage tests. See
[resource contracts](../Resources/Places/README.md).

## Current build 8 validation — verified execution results

CI **35848409845 / job 107140049230** passed on its first attempt. The following
App sub-suites are included in the App total, not extra tests to add again:

| Gate | Verified build 8 result / boundary |
| --- | --- |
| Core / export / places / model and App checks | All passed; Swift core 79 passed. Model-report parityPassed:true; raw exact extrema were not returned, so old values are not copied as new measurements. |
| IndexPipelineTests | All 19 passed, including 4 additions; overlap/order/drain tests cover four slots. |
| New pipeline coverage | Passed: cached four-slot geography backfill with one shared place-text encoding; concurrent image results sharing central text/cache and unchanged policies; cancellation draining four PhotoKit requests or four image encodes before serialized refresh/search. |
| Factory boundary | New injected-default-factory test passed for four slots and pre-cancellation; mocks alone do not establish real model independence. |
| Real-model factory parity | Passed with four real image actors: 6 fixtures × 4 production slots = 24 predictions; 48 normalized reference comparisons + 12 tensor measurements = 60. Counts and image cosine ≥ 0.995 gates asserted and passed. |
| Existing production API parity | Passed: unchanged 23 predictions / 58 measurements and acceptance gates. |
| GeneratedModelParityTests | All 8 passed in 101.581 seconds. |
| Full App suite | 221 total, 220 passed, 1 physical-device file-protection skip on simulator, 0 failures. |
| UI tests | All 7 passed in 209.329 seconds. Screenshot review is limited to the 3 frames below. |
| Device/IPA checks and complete download | Passed; actual version 0.3.2 / build 8 verified. Local stream download COMPLETE, actual bytes/hash verified; checksum and device-build JSON exist, no partial file remains. |
| Phone performance / coverage | PENDING-DEVICE — no physical test, speedup, memory/heat or GPS-coverage result. |

The factory parity test uses one central owner and four independent image actors,
not four text models. It retains the same actors across all six fixtures, including
68×120 and 112×199, with no threshold weakening or test-side preview upscaling.
Details: [NATIVE_PARITY.md](NATIVE_PARITY.md).

### Verified build 8 package and limited UI review

- [IPA artifact 10745235946](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35848409845/artifacts/10745235946):
	outer **1,414,636,737 bytes**, inner IPA **1,414,629,419 bytes**;
	IPA SHA-256 `7d37581966a45028213a52a0a9c504e2ed273293a92bbbad4ab9d77a0d73ef8e`.
- Completed and locally byte/hash-verified download:
	[build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35848409845/LocalImageIQ-iphoneos-unsigned.ipa).
	Still unsigned; local Sideloadly signing is required.
- **20 native UI frames retrieved; only 3 index/place frames reviewed** in the
	**960×680** [contact sheet](../build/ui-review/35848409845/four-workers-ui-contact.jpg):
	Library after backfill, Library with zero GPS, and Settings with locations not
	checked. Disclosures remained collapsed, so expanded internal counters were
	not reviewed; neither were the other 17 frames. Synthetic UI scenes are not
	evidence of private-library GPS coverage or four-worker physical-device behavior.

## Historical 0.3.1 (7) validation — older evidence only

Source `18ad52d37690ecfbf92b63a21285a6c3e8e753d4`;
[CI 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
/ [job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763):
**SUCCESS first attempt**, with `TEST SUCCEEDED` and `BUILD SUCCEEDED`. That
version used one structured child for next-preview/cache prefetch, one image/text
model pair, serial inference and ordered parent commits. It cancelled/drained the
prefetch child on exit. It did **not** implement build 8's four inference slots;
its passed tests/download below do not validate the new implementation.

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

### Historical verified build 7 package and visual-review scope

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

## Current remaining boundaries

Build 8 CI/native execution, resource checks, device compilation, IPA identity and
complete local byte/hash-verified download are finished. Signing/install and
physical-device results remain unconfirmed (`PENDING-DEVICE`). The cloud/native
pass does not establish phone file protection, speed,
memory/heat or private-library GPS coverage. No speedup or coverage is promised,
and no additional user diagnostic round is required. Optional from-zero timing is
the user's requested comparison, not a condition for normal upgrade/use.
Model/geography license review (`PENDING-LICENSE-REVIEW`) and formal release
configuration remain open. Canonical evidence ledger: [BUILD_STATUS.md](BUILD_STATUS.md).