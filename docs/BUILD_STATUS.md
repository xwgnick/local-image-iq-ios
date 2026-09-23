# Cloud build status — 2026-09-23

## Current: 0.3.1 (7) — SUCCESS first attempt; IPA downloaded and verified

Source HEAD: `18ad52d37690ecfbf92b63a21285a6c3e8e753d4`.
[Run 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
/ [job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763).
**SUCCESS on the first attempt; no fix or retry was needed.** Logs contain
`TEST SUCCEEDED` and `BUILD SUCCEEDED`. The evidence below belongs to this run,
not build 6. This documentation-only edit records supplied verified results;
it does not run commands, tests, downloads or CI queries.

| Gate | Verified build 7 result / remaining boundary |
| --- | --- |
| Source/static contracts | 30 passed. |
| Pure Swift core | 79 passed. |
| Generate and validate public offline Places pack | Public-place build and test_places step passed, including generated-pack validation. The 25-test count is declared in code / prior local documentation, not asserted here as a separately observed CI log total. |
| Convert and check pinned model pair | Passed; model-report artifact 10741671604 records 23 cases and 92 comparisons, with this run's measurements below. |
| Native App tests | 215 total: 214 passed, 1 physical-device file-protection test explicitly skipped on simulator, 0 failures. All App suites listed below are included in this total, not additional tests. |
| GeneratedModelParityTests | All 7 passed in 67.736 seconds; no parity skip. |
| IndexPipelineTests / PlaceAvailabilityTests | All 15 / 17 passed, respectively. |
| BundledPlacesTests | Both tests passed: actual host-app pack hash/counts and public-city coverage, including New York outside coverage. Not a private-library GPS test. |
| IndexPlacesPresentationTests | All 3 passed; screenshot review is narrower than test execution, as recorded below. |
| UI tests | All 7 passed in 202.143 seconds; TEST SUCCEEDED. |
| Simulator / device App resources and IPA validation | Passed: compiled simulator and device App bundle checks, device packager and IPA contents validation. Actual device-report Places identity is recorded below. |
| iPhoneOS arm64 Release build and IPA upload | BUILD SUCCEEDED; unsigned 0.3.1 (7) package uploaded as artifact 10741731376. Not a physical-device execution test. |
| New IPA download / length / SHA-256 | Actually completed with bounded-memory streaming; local length/hash verified and the post-download local report written and checked. |
| Native visual review | 20 screenshots retrieved; only the 3 new index/place frames reviewed in a 960×680 contact sheet. Disclosures remained collapsed; their full internal counters were not visually reviewed. |
| Physical iPhone / private-library coverage / speed | PENDING-DEVICE after user installation. No measured phone speedup or real-GPS coverage percentage is promised; file protection remains untested on a physical device. |
| Distribution review | PENDING-LICENSE-REVIEW for model and geography redistribution; preserved source/license evidence is not legal approval. |

### Export evidence from this run

[Model-report artifact 10741671604](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741671604):
**23 cases, 92 comparisons**, with unchanged modelVersion.

| Metric | Build 7 measured value |
| --- | --- |
| Minimum embedding cosine across comparisons | 0.9999999999960657 |
| Maximum raw component difference | 0.000011444091796875 |
| Maximum paired text/image cosine matrix difference | 1.8557397291063538e-7 |

The export's native `not-run` markers precede XCTest; the later seven passing
GeneratedModelParityTests establish native execution, not those exporter markers.
These synthetic numerical checks do not measure real-photo retrieval quality.

### Verified device package, completed download and bounded visual review

- Device report: **0.3.1, app build 7; iphoneos18.5 SDK; arm64 Release;
  unsigned; Xcode 16.4; minimum iOS 17.0**. FP32 and semantic modelVersion are
  unchanged from 0.3.0.
- [Unsigned IPA artifact 10741731376](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741731376):
  outer artifact **1,414,628,123 bytes**; inner IPA **1,414,620,805 bytes**.
- IPA SHA-256:
  `98fb537004a64adaa84b1ba15d798acaf71a0684555275faddc647d1adafd8d6`.
- **Download actually completed**, with bounded-memory streaming and verified
  local length/SHA-256, at
  [build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35840838147/LocalImageIQ-iphoneos-unsigned.ipa).
  The local report was written and checked after download. This is the build 7
  package, not the old build 6 IPA; it still needs local Sideloadly signing.
- Actual **device-package** bundledPlaces checks confirm **2,943 features,
  15,175,079 GeoJSON bytes, CHN/FRA/DEU/NLD, 8 sources**. GeoJSON SHA-256:
  `41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`.
  Manifest SHA-256:
  `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`.
  These are verified device-package results, not just local source metadata.
- **20 native UI screenshots retrieved; only 3 new index/place frames reviewed**:
  Library after backfill, Library with zero GPS, and Settings with locations not
  checked, in the **960×680**
  [build/ui-review/35840838147/index-places-contact.jpg](../build/ui-review/35840838147/index-places-contact.jpg).
  Visible content is readable. Disclosures are collapsed, so this is **not** a
  visual check of every expanded internal counter. Counts are synthetic fixtures,
  not user GPS observations; the other 17 screenshots were not reviewed this round.

### Implemented scope, not a physical-phone performance claim

- One structured child prefetches the next asset's cache row / PhotoKit preview
  while the parent handles the current asset. One model pair, serial encoder
  calls and one ordered commit path remain; this is not multiple inference workers.
  Writes and progress stay in snapshot order, with successful saves completed
  before their counters publish. Cancellation/error scope exit cancels and drains
  the Swift child. PhotoKit has no cancellation acknowledgement; the existing
  gate ignores late callbacks, without claiming the OS request has stopped.
- No new arbitrary library/batch ceilings, deadlines, retries, original-download
  requirement or networking policy. Preview-first, reduced previews accepted,
  iCloud default off / explicit opt-in remain unchanged. Overlap is not measured
  iPhone acceleration and may help little if inference dominates.
- Both encoders still use `google/siglip2-base-patch16-224` at revision
  `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`, FP32, the same preprocessing and
  `photokit-preview-v1`. Semantic modelVersion remains
  `siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
  Compatible 0.3.0 image vectors are reused while locations/place vectors are
  backfilled; compatible persisted distinct-place vectors are reused as well.
- China, France, Germany and Netherlands ADM1/ADM2 public boundaries are now
  required app resources in the normal CI path, including model-free builds.
  The generated [manifest](../Resources/Places/places-manifest.json) and actual
  device-package checks agree on the pack identity recorded above. Simulator,
  device App and IPA resource gates passed; this edit does not rerun those checks.
- Represented years are China ADM1 2019 / ADM2 2017, France 2022, Germany 2021,
  Netherlands 2022. Historical administrative approximations are not current
  addresses, POIs or global coverage. Labels use photo metadata, not current-device
  location or online reverse geocoding; raw coordinates are neither stored nor uploaded.
- Library separates current/last-scan GPS observations from saved labels:
  resolved, no GPS, GPS with no usable pack, GPS outside coverage, and unavailable.
  Not checked means unknown; label count is not GPS count or a permanent census.
  The existing centered-place score and default weight **0.6** are unchanged;
  supplying real place labels activates that branch, so ranking changes are intentional.

Implementation, provenance and test contracts: [INDEX_PIPELINE_PLACES.md](INDEX_PIPELINE_PLACES.md).

### Install the verified build 7 package; backfill places once

Overwrite with the same Sideloadly account/effective Bundle ID; **do not uninstall,
clear the index or re-encode the whole existing 0.3.0 image library**. Open
**Library → Index / resume** for one location-backfill pass, keep the app open and
network off, and resume there if interrupted. Valid image-cache hits need no pixels
or image inference; new/changed photos follow normal encoding. Do not download all
originals or change the location weight to disguise expected ranking changes.
An index still using 0.2.x CLIP requires the separate historical model migration;
build 7 does not make old CLIP vectors compatible. Normal use afterwards is enough,
without a new user diagnostic/query round.

### Remaining boundaries

CI, native parity/UI execution, simulator/device resource checks, IPA packaging
and the verified download are complete. User-side signing, overwrite installation
and the one-pass location backfill have not yet been confirmed for build 7.
Physical-iPhone behavior, file protection, latency/memory/heat and private-library
GPS/coverage remain unverified; cloud tests and synthetic screenshots do not fill
those gaps. No additional diagnostic/query round is requested. Expanded disclosure
contents are outside this visual review's scope. Public release still requires
model/geography license review, an App icon, a production Bundle ID, signing and
TestFlight/distribution configuration; no store submission has occurred.

## Historical: SigLIP 2 · 0.3.0 (6) — SUCCESS; IPA downloaded and verified

Everything in this build 6 section, including its migration instructions, metrics,
package and screenshot review, belongs to the previous release, not build 7.

Source: `f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78`.
[Run 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
/ job `107062896845`: **SUCCESS**, the corrected run. The logs report
`TEST SUCCEEDED` and `BUILD SUCCEEDED`. The prior documentation update recorded
that completed run and verified download, not a physical-device result.

Initial [run 35823153931](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35823153931)
at `aee4cdc00be92e1699f68baa9ef7ccc72cbcfbda` **failed**. It passed all 30 static tests, 79 core tests, model conversion
and same-tensor native prediction, but failed native compatibility checks: Quartz
resizing did not match bilinear interpolation for the 68×120/112×199 inputs, and
Swift lowercasing omitted Unicode Final_Sigma context. All seven UI tests passed.
The fix replaces resizing with explicit Pillow-compatible 22-bit separable
bilinear filters and implements Unicode Final_Sigma. It does not change fixtures,
thresholds, PhotoKit policy or queries. Ten resampler and three Unicode regression
tests were added. The corrected run above now passes both low-resolution native
cases and the exact Gemma token checks, including Final_Sigma. Full same-tensor
controls and numerical gates were retained, not weakened to obtain a pass.

The user approved replacing BOTH encoders with `google/siglip2-base-patch16-224`,
same revision `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2` for image and text.
[IMPLEMENTATION_CONTRACT.md](IMPLEMENTATION_CONTRACT.md) is authoritative:
schema 2, 768-dimensional raw outputs, 64 text positions, only `input_ids` as
text input, both original tokenizer JSON resources, explicit lowercase and
EOS/right-padding policy. The App pins `swift-transformers` 1.3.4 / `Tokenizers`
for local JSON loading; the Foundation-only core is separate. Do not mix a
SigLIP image encoder with the retired CLIP text encoder or old index vectors.

### Completed validation — evidence from corrected run 35824403795

| Gate | Historical build 6 evidence / then-remaining boundary |
| --- | --- |
| Python static checks | 30 passed, reported for this change; not rerun by this documentation edit. Static checks are not model export or native parity. |
| Pure Swift core | 79 passed, zero failures in this run. |
| FP32 Python/Core ML export | Passed: 17 texts + 6 synthetic images = 23 cases, 92 stage comparisons and a 17×6 paired cosine matrix; measured values below. |
| Native generated parity | All 7 GeneratedModelParityTests passed in 72.985 seconds: exact Gemma IDs/masks including Final_Sigma, same-tensor runtime, native preprocessing and requested CPU / `.all` checks. No parity skip. |
| Production encoder API coverage | Passed with asserted counts: 23 predictions (17 text + 6 image previews), 58 measurements (12 tensor + 46 normalized embedding comparisons). These are executed results, distinct from the exporter's 92 comparisons; diagnostic tensor measurements are not bit-exact Pillow gates. |
| App tests | 178 total: 177 passed, 1 physical-device file-protection test explicitly skipped on simulator, 0 failures. The 7 generated parity tests are included, not additional App tests. |
| UI tests | All 7 passed on the iOS 18.5 simulator; `TEST SUCCEEDED`. |
| Device build | iPhoneOS arm64 Release `BUILD SUCCEEDED`; unsigned FP32 package, not a physical-iPhone execution test. |
| New unsigned IPA | Artifact 10734323054 downloaded completely with bounded-memory streaming; local length and SHA-256 verified. Identity and link below. |
| iPhone behavior / performance | `PENDING-DEVICE`: not established by static, CPU or simulator results; no additional user diagnostic/query round is requested. |
| Distribution review | `PENDING-LICENSE-REVIEW`: shared model card declares Apache-2.0; copying license evidence is not legal certification. |

Measured FP32 export report (not physical-device measurements):

| Metric | Corrected-run value |
| --- | --- |
| Minimum embedding cosine across 92 comparisons | 0.9999999999960657 |
| Maximum raw component difference | 0.000011444091796875 |
| Maximum paired text/image cosine matrix difference | 1.8557397291063538e-7 |

Model version:
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
The export JSON's native `not-run` statuses were produced **before XCTest**;
they are provenance, not failures or a claim that the subsequent native tests
did not run. The later passing XCTest results establish native parity. Exact
token IDs/masks, full same-input tensor controls and all numerical thresholds
remain unchanged; synthetic parity is not real-library quality evidence.

### Verified IPA and bounded visual review

- Toolchain: **Xcode 16.4 / Swift 6**, with App Swift 5 language mode;
  **iphoneos18.5 SDK / arm64 / minimum iOS 17.0 / FP32**.
- [Unsigned IPA artifact 10734323054](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795/artifacts/10734323054):
  outer artifact **1,408,905,095 bytes**; inner IPA **1,408,903,848 bytes**.
- IPA SHA-256:
  `529b8ae5f708f57d14929fccf4a374dfb943d0e950b7671239e99f69b5acd98e`.
- **Download actually completed**, with bounded-memory streaming and verified
  local length/SHA-256:
  [build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa](../build/device-download/35824403795/LocalImageIQ-iphoneos-unsigned.ipa).
  This was the verified build 6 package, not a pending download or the build 7 IPA.
  It remains unsigned and requires local Sideloadly signing before installation.
- **17 native UI screenshots retrieved; only 4 reviewed**: Home, Library,
  Settings and hero-results layout, in the downscaled
  [build/ui-review/35824403795/siglip2-ui-contact.jpg](../build/ui-review/35824403795/siglip2-ui-contact.jpg).
  Synthetic/test scenes only, no private photos. Retrieval of the other 13 is
  not visual review; neither these screenshots nor simulator `.all` tests
  establish physical-phone performance or actual Neural Engine execution.

### Historical installation and required migration from CLIP to build 6

1. Overwrite using the same Sideloadly account and effective Bundle ID. **Do not
   uninstall or manually clear the index.**
2. **Now open Library → Index / resume once** to generate the new vectors; this
   is required because the model changed. Before new vectors exist, usable
   coverage from old-model rows is expected to be **0**, not a reason to clear
   storage. Keep network access off. Original-photo downloads / “Download and Keep Originals”
   are not prerequisites. If interrupted, resume there; completed, still-valid
   new-version rows are reused.
3. Use search and photos normally. No further test queries, screenshots or
   single-photo diagnostics are required for this handoff.

Legacy 512D CLIP rows can be decoded ONLY to support migration; they are not
searchable with a SigLIP 2 768D query. The semantic modelVersion changes while
`photokit-preview-v1` stays unchanged. Image and any place-text vectors must be
regenerated under the new modelVersion, never padded or mixed across models.
Photo rows use `id` as their primary key and are replaced as reindexing succeeds.
The old IPA is retained, but it is NOT an index backup: rolling back the binary
does not promise restoration of overwritten old-model rows.

### Unchanged boundaries

- PhotoKit remains preview-first with local reduced previews accepted, network
  default off and online fallback only after explicit user opt-in. This change
  does not fix preview quality, force original downloads or guarantee offline
  access to every cloud asset. Scoring/settings/privacy policies are unchanged.
- The small desktop comparison showed trade-offs by query, language and input
  resolution, not an across-the-board winner. Desktop CPU timings are not
  iPhone latency, memory, heat or energy measurements.
- The exporter copies actual shared model-card/LICENSE/NOTICE evidence where
  present, preserves manual review and `redistributionApproved:false`; neither
  Apache-2.0 metadata nor numerical parity is certification for distribution.
- Free Apple development profiles still normally expire after seven days;
  Sideloadly is local third-party signing, not TestFlight or permanent installation.
  No Apple credentials go to chat/CI, and photos, GPS and local vectors are not
  uploaded. No new user diagnostics are part of this model replacement.

## Historical records — old versions, not SigLIP 2 proof

Everything below records the earlier builds and their then-current instructions.
In particular, old “do not rebuild” guidance applied to UI/diagnostic-only updates;
it did not waive build 6's CLIP-to-SigLIP new-vector indexing step above. That
migration is not a requirement to re-encode valid 0.3.0 image vectors for build 7.
Old success counts,
parity measurements, license findings, package sizes and checksums do not describe
the current build. Preserve them as history, not as pending-result substitutes.

## Historical: read-only single-photo check · 0.2.1 (5)

User confirmed the target is absent from Top 12 for `Dog eat my apple pen`, but
appears first for `a hand holding a broken white pen`. It is therefore indexed;
the cause of the ranking difference is still unproven. The user approved a simple
check button and screenshot workflow, not a new retrieval model or index rebuild.

The full-screen viewer now offers **Check this photo**. The check page accepts the
missed query and compares full-gallery cached rank with the rank after replacing
only this photo's vector using the existing local preview/encoder path. Request
dimensions, actual CGImage dimensions, raw degraded flag and vector cosine appear
on the screenshot card. Historical cached dimensions remain unknown.

Dedicated SQLite read-only handle; no cache reconciliation, schema writes, vector
updates, original-data requests or network fallback in this operation. The existing
AppState task chain serializes it with other work and rejects late cancelled
results. Current photo selection, query and gallery survive the check.

New tests: 18 worker/storage plus 20 state/render tests (five native screenshots).
Synthetic inputs and temporary databases only. No private photos, database or GPS
uploaded. See [PHOTO_CHECK.md](PHOTO_CHECK.md) for the test contract and phone steps.

[Run 35817552815](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35817552815)
at `36b4a7fa43fd5dd8d47cda8332fbaef4be0630ec`: **SUCCESS**, first attempt.

- Core: 79 passed. App: 152 total, 151 passed, one physical-protection skip.
  All 18 PhotoDiagnosticTests and 20 PhotoCheckPresentationTests passed, including
  actual temporary SQLite byte/hash invariance and cancellation/serialization.
- All seven existing UI navigation/keyboard tests passed. These tests do not
  exercise the new check button on a real photo; that remains a device test.
- Five new native screenshots reviewed in one 960×1360 contact sheet. Idle,
  result, unavailable-preview and large-type layouts are readable/scrollable;
  the viewer button is visible and correctly disabled for a nonexistent test ID.
  The example ranks/pixels are explicitly synthetic, not private-library findings.
- iPhoneOS arm64 Release build passed with unchanged model version and cache policy.
- [Unsigned IPA artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35817552815/artifacts/10732805206):
  **709,826,214 bytes**, SHA-256
  `a96c377ae0562022215daeffe75be778ba620137f32d2c4f43e573964b8f6465`.
- Downloaded with bounded-memory streaming and verified size/SHA-256 locally at
  `build/device-download/35817552815/LocalImageIQ-iphoneos-unsigned.ipa`.
  Review contact: `build/ui-review/35817552815/photo-check-contact.jpg`.

Overwrite with the same Sideloadly identity/effective Bundle ID. Do not uninstall,
clear or rebuild the index. Phone steps are in [PHOTO_CHECK.md](PHOTO_CHECK.md).

## Historical: photo-first UI redesign · 0.2.0 (4)

The user deferred model/retrieval changes and requested a complete UI redesign.
Home is search-first, technical controls move into Library/Settings sheets, and
results gain larger-photo/compact grids plus an ordered full-screen photo viewer.
Models, scoring, networking defaults and `photokit-preview-v1` cache identity are
unchanged. See [UI_REDESIGN.md](UI_REDESIGN.md) for exact layout and test boundaries.

Initial [run 35706493782](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35706493782)
compiled the redesigned app and passed all 79 core / 113 App tests (one physical
protection skip), including all 16 presentation tests. One navigation test failed:
the native Home screenshot exposed an unsolicited Photos permission dialog.
Photos observation now starts only after access is granted, not in client init.

[Run 35707292730](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35707292730)
verified that fix: all three presentation/navigation tests passed. The 12 native
review screenshots were inspected as a downscaled contact sheet; Home no longer
has the permission popup, Library offers Choose photos, and the photo grids and
normal/large-text Settings render correctly. One keyboard test received
`d eat my apple pen` rather than the injected full query. The previous assertion
ran only after submission, so it could not distinguish input loss from submission
mutation. Tests now assert each typed prefix before dismissal, with no retries or
query repair, and retain all exact post-dismissal assertions.

Final [run 35708194014](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35708194014)
at `b02357e128bc82313be48395dc5c3e9778c274eb`: **SUCCESS**.

- Core: 79 passed. App: 114 total, 113 passed, one physical-protection skip;
  all 16 presentation tests and seven real-model parity tests passed.
- UI: all seven passed (three navigation and four keyboard tests). Keyboard tests
  verified every injected prefix and exact text after Search/Done; no production
  query workaround or test skipping was introduced.
- Final 12 native screenshots were retrieved and reviewed as a 900×2720 contact
  sheet. The clean Home, reachable Library, normal/large-text Settings, three grid
  layouts and unavailable-photo state agree with the earlier visual review.
  Screenshots use empty UI or labelled synthetic test scenes, not private photos.
- Device Release: `BUILD SUCCEEDED`, iPhoneOS 18.5 SDK, arm64, unsigned, both real
  encoders included. The model version remains unchanged.
- [Device artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35708194014/artifacts/10684943653):
  IPA **709,723,454 bytes**, SHA-256
  `4517a52c2732c6b29873724b05d4c1f3a1c8a4bde7612c97cf58a4389c2c03e6`.
- Download completed with bounded-memory streaming and size/SHA-256 verification
  into ignored `build/device-download/35708194014/LocalImageIQ-iphoneos-unsigned.ipa`.
  Final local screenshots: `build/ui-review/35708194014/contact.jpg`.

Use the same Sideloadly account / effective bundle identifier to overwrite the
previous installation. Do not uninstall or clear/rebuild the index for this UI
update. Actual iPhone 15 / iOS 26.6.1 interaction and private-library results still
need device confirmation; full-screen photo gestures/sharing were implemented
and compiled, not claimed as real-photo end-to-end validation by these screenshots.

## Historical: search keyboard dismissal · 0.1.2 (3)

The user screenshot showed returned matches covered by the keyboard. The previous
search field had no FocusState management: calling search did not resign focus,
and there was no explicit dismissal control.

- The query field now has explicit focus and single-line submit semantics.
- Both keyboard Search and the page search button share the same action, which
  clears focus before requesting search, including unavailable/empty submissions.
- Keyboard toolbar Done and a focused-only navigation Done button dismiss without
  searching or clearing the query. Dragging the scroll view dismisses interactively.
- Opening a result clears focus. No networking, index, model or ranking changes;
  the `photokit-preview-v1` cache remains reusable after this update.

Four new XCUITest cases drive the actual simulator app: Search return, keyboard
Done/re-focus, navigation Done and drag dismissal. They do not grant Photos access
or fabricate a search index; the shared submit focus path is tested even when the
search state is not ready. Actual result rendering with a personal library remains
a separate device test. No local-network debug channel was added.

Validation [run 35694536774](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35694536774)
at `58f6783eba4a5fd4412b16635c34585c32ff9ed2`: **SUCCESS**.

- Core 79 passed; App 98 total, 97 passed and one physical-device protection skip.
- **All four SearchKeyboardTests passed** on the simulator (59.28 seconds), with
  actual software-keyboard interaction. No fake results or private images supplied.
- Device Release build succeeded with both models included.
- [Unsigned device artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35694536774/artifacts/10678914749):
  IPA 709,552,244 bytes; SHA-256
  `bce9d08d5a6f7cbcb341af7351bb84c03efbc3c381838c71a75f42c21c796c4f`.
- Downloaded and streaming-hash verified locally under
  `build/device-download/35694536774/LocalImageIQ-iphoneos-unsigned.ipa`.

Update over 0.1.1 using the same Sideloadly account / effective bundle identifier.
Do not uninstall or clear the existing index for this UI-only fix. Actual iOS
26.6.1 device keyboard behavior remains to be confirmed after installation.

## Historical: preview-first fix for optimized iCloud libraries · 0.1.1 (2)

The user confirmed the first device app opens and searches, but a real optimized
iCloud library indexed only 114 of 7,994 checked images. Full permission was present;
last error was PhotoKit 3164. This exposed an original-data request and misleading
error categorization, not a 114-image product limit.

The approved fix switches indexing to local-first PhotoKit preview requests,
accepts degraded single-callback images, encodes CGImage pixels directly, and only
falls back to a network-allowed preview request with explicit user permission.
Networking remains off by default. No full-original download prerequisite, no
UI layout redesign, and no photo upload. See [policy and device checklist](PREVIEW_INDEXING.md).

The active cache identity appends `photokit-preview-v1` to the unchanged paired
model version, so the first scan after updating rebuilds the image index using
the new input path. Reduced previews may change rankings; there is no claim that
all 7,994 assets are now locally accessible before a new device test.

New coverage includes 26 callback/policy tests, 20 worker/persistence/source-counter
tests, three direct-preview tensor tests and a real-model preview API parity test.
An actual compiler error in the new async Core ML call was fixed by retaining the
existing synchronous actor-isolated prediction path. A stale source-label assertion
was aligned with the accurate online-fallback wording; no numerical gate was weakened.

Final device validation: [run 35683805304](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35683805304),
source `71c56c66bf75bbaeeafe414af8d2cc4076b97d8c`: **SUCCESS**.

- Core: 79 tests passed, zero failures.
- App: 98 tests total, **97 passed, one physical-device protection test skipped**,
  zero failures. All seven real-model parity tests, 26 preview request tests and
  20 worker tests passed. Tests do not substitute for an optimized-iCloud device test.
- Device Release build: `BUILD SUCCEEDED`; same iPhoneOS/arm64 validation as before.
- [Replacement IPA artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35683805304/artifacts/10675548340),
  IPA 709,546,542 bytes, SHA-256
  `3481dbd842169caa96c6da8a1ba1f33517b09ec9232c81521a447e1e1a544ff5`.
- Downloaded with bounded-memory streaming into ignored
  `build/device-download/35683805304/LocalImageIQ-iphoneos-unsigned.ipa`; size and
  SHA-256 verified before publishing the final local filename. Old package retained.

Install this unsigned IPA with the same Sideloadly account/application identifier
over the old version. Keep network disabled for the first new scan and compare the
source/coverage counters. No promise of full-library offline coverage is made.

## Historical: first unsigned physical-iPhone IPA built

The user has Windows only, an **iPhone 15 / iOS 26.6.1**, no paid Apple membership,
and explicitly accepted Sideloadly for local signing. No third-party installer,
Apple driver, Apple login or signing certificate was installed/configured by CI.

[Run 35636586662](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35636586662)
at source `4dd504e33ced08a5444f4e67fab5bd3a74149577`: **SUCCESS**.
Model conversion and simulator tests passed again before the device build
(79 core tests; App 48 total, 47 passed, one physical-protection test skipped).

The subsequent Release build uses **iphoneos18.5 SDK / Xcode 16.4 / arm64**,
minimum iOS **17.0**. Both compiled encoders and vocabulary are bundled. The
packager verifies `CFBundleSupportedPlatforms=iPhoneOS`, `DTPlatformName=iphoneos`,
Mach-O platform IOS, arm64 architecture and a real Payload/App layout. This is
not a renamed simulator binary. Code signing is disabled; no mobile provisioning
profile or test bundle is included.

[Unsigned iPhone artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35636586662/artifacts/10656339002)
contains `LocalImageIQ-iphoneos-unsigned.ipa`, `device-build.json` and checksum file.

- IPA bytes: **709,536,954** (~710 MB).
- SHA-256: `f4027e85899914735d0d4f17fbbb727e0f4ca06c6406c7d0be7a80a862cc88a2`.
- Bundle ID: `com.example.localimageiq` (development placeholder; re-signing may
  assign a personal-account-specific identifier).
- **Unsigned / not directly installable / not yet tested on a physical iPhone.**

Follow [Windows iPhone installation](WINDOWS_IPHONE_INSTALL.md): the user signs
locally, pairs/trusts the device and enables Developer Mode as required. Passwords,
2FA codes and phone passcodes stay in the tool / Apple flow / phone, never in chat
or GitHub. Free development profiles normally expire after seven days.

## Historical: CLIP model-enabled validation passed

[Run 35634483200](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35634483200)
at source `b7983083e86b231a4d27ea8a548ce3382c2cf27b`: **SUCCESS**, with
`include_models=true` and `all_compute_units=true`. Only pinned public models and
synthetic inputs were used; no personal photos, GPS, database or videos uploaded.

- Both real encoders exported on Apple Silicon macOS using the pinned FP32 toolchain,
  compiled into the iOS App, loaded and exercised in the iOS 18.5 simulator.
- **79 core tests passed; 48 App tests total: 47 passed, 1 explicitly skipped,
  zero failures.** The skipped test needs physical-device file protection.
- All six generated/native parity tests ran. Cased WordPiece IDs/masks matched
  12 reference texts, including Chinese, accents, special tokens and truncation.
- Four generated image patterns cover RGB, non-square resizing, EXIF rotation
  and mirroring. Same-tensor inference and native preprocessing were checked
  separately; the latter passed its embedding-cosine acceptance criterion, not a
  claim that CGContext interpolation is pixel-identical to Pillow.
- CPU-only and `.all` inference tests passed on the simulator. This does not prove
  that a physical iPhone Neural Engine was used or establish real-device performance.

### Measured Python/Core ML conversion

16 image/text cases, four comparison stages per case:

| Metric | Measured |
| --- | --- |
| Minimum embedding cosine across conversion comparisons | 0.9999999999972214 |
| Maximum raw component difference | 0.00000858306884765625 |
| Maximum paired text/image cosine difference | 0.00000019307484327990565 |

Model version: `clip-pair-v1-8c7add0507b558a30b86c170c5d86767515f27e9f2944574eabee0dde8e4a09e`.
The Python parity JSON records native stages as `not-run` because it is emitted
before Xcode tests; the later XCTest result is the evidence for native parity.
These synthetic comparisons establish numerical compatibility, not search quality
on a user's real collection.

### Download and remaining boundary

[Private build artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35634483200/artifacts/10655548861):
715,390,511 bytes; embedded `LocalImageIQ-Simulator.zip`: 715,482,546 bytes.
Includes compiled encoders, simulator App, XCTest results and conversion reports.
The report was inspected using 96,764 bytes of ranged reads; the large artifact
was not loaded into this workspace/editor.

This is an **FP32 simulator build, not a signed iPhone IPA**. Model memory, speed,
heat, real PhotoKit permission flows and locked-device protection still need a
physical iPhone. Optional geography data is not bundled, so no offline location
coverage or reproduction of location-enhanced desktop demo rankings is claimed.
TestFlight / App Store submission has not happened. Text-model card declares
Apache-2.0; the pinned image-model card has no license declaration in its header.
Model redistribution review remains incomplete; do not treat the numerical report
as legal approval to distribute the package publicly.

Next: choose the authorized Apple signing / device-installation route, then validate
on device. No Apple credentials, certificates or billing settings have been requested
or changed by this workflow.

The user selected **no paid Apple membership; prefer a free route**. Apple's official
free-device-testing route uses an Apple Account / Personal Team signed in locally
to Xcode on a Mac connected to the device. Profiles expire after seven days and
need reprovisioning. The current simulator ZIP cannot be installed by renaming it
to IPA. GitHub's cloud build does not provide that physical-device connection or
replace personal signing. The user subsequently confirmed Windows-only access and
approved the third-party signing route documented above instead.
See [Apple account / Personal Team documentation](https://developer.apple.com/support/compare-memberships/).

## Historical: personal repository setup and initial validation

The user supplied `xwgnick/local-image-iq-ios` and confirmed the separate personal
account login. The API verified login `xwgnick`, private visibility and push access.
Only the isolated iOS source/configuration/documentation history was uploaded.
The original enterprise repository remains unchanged; local Git remote `personal`
selects the new repository explicitly, while `origin` still points to the old one.

GitHub's hosted Apple Silicon Mac now starts successfully. Verified milestones:

- 79 `ImageIQCore` tests compiled and passed on macOS.
- XcodeGen generated the app project; Xcode 16.4 compiled the native app and tests
  after importing PhotosUI for the limited-library picker.
- A test-only Swift type-inference timeout was fixed by splitting an expression;
  the ranking expectations and production scoring were not changed.
- XcodeGen's optional resource references still entered the copy phase when files
  did not exist. `project.yml` is now model-free; `project.models.yml` adds generated
  parity resources only after successful export in a model-enabled run.
- The App and XCTest bundle compiled and executed on the iOS 18.5 simulator.
  File-protection attributes are not exposed by that simulator filesystem:
  backup exclusion remains tested there, while the separate data-protection test
  explicitly skips on simulator and still asserts the original policy on iPhone.
  The production protection settings were not relaxed.
- The initial runs below used `include_models=false` and `all_compute_units=false`.
  The subsequent successful model-enabled run is documented above. No signing or
  TestFlight submission has been performed.

Earlier model-free validation: [run 35630122554](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35630122554),
source commit `d5cff5a90cdc15d4f67ba1328007b3a55daa9bdd`: **SUCCESS**.

- macOS package: **79 tests passed**, zero failures.
- iOS App XCTest: **48 total, 42 passed, 6 skipped, zero failures**.
  Five generated-model parity tests were skipped because this build intentionally
  has no models; one data-protection test requires a physical iPhone.
- Xcode reported `TEST SUCCEEDED`; simulator app packaging and artifact upload passed.
- [Build artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35630122554/artifacts/10653728057):
  `local-image-iq-model-free-5`, 6,178,124 bytes, containing Simulator App ZIP and
  XCTest results. Download requires access to the private repository.
- This is **not an iPhone-installable IPA**. No model inference, actual photo-library
  permission interaction, TestFlight distribution or physical-device performance
  has been validated by this model-free test run.

This earlier artifact is kept as the model-free baseline; use the newer artifact
above when a model-enabled simulator App is needed.

## Historical enterprise-account attempt

- Repository: `wengxie_microsoft/local-image-iq-ios`, API verified **private**.
- Source commit: `aeae0956e9baa536282e63b84a49f1bae7fbb543`.
- Uploaded: 47 source/configuration/documentation files only; no personal photos,
  video, databases, model weights or caches.
- [Run 35626471451](https://github.com/wengxie_microsoft/local-image-iq-ios/actions/runs/35626471451):
  dispatched once, `include_models=false`, `all_compute_units=false`.
- Result: failed **before any job step**; job `106421974495` has no executed steps.
- Annotation: **“GitHub Actions hosted runners are disabled for this repository.”**
- Repository Actions API: `enabled=true`, `allowed_actions=all`. Merely enabling
  workflows is therefore not the missing step. No configuration was changed.

GitHub documents that repositories owned by enterprise-managed user accounts
cannot use GitHub-hosted runners; organization-owned repositories can, subject to
enterprise policy. This matches the personal-namespace repository and observed
runner rejection. See [official restrictions](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-iam/understanding-iam-for-enterprises/abilities-and-restrictions-of-managed-user-accounts#github-actions).

## Original enterprise-account restriction

An enterprise-managed personal repository needs an organization-owned repository
with runner access or an approved self-hosted Mac. An ordinary personal account's
private repository is a separate option when use of that account is permitted.
Do not change visibility, billing or organization policy to bypass a restriction.
The personal repository used above was provided by the user, not created or
transferred by the assistant.

Core ML conversion and native numerical parity remain separate from the model-free
workflow. Physical-device performance, actual photo access and signing still need
validation after the simulator milestone.