# Native generated-model parity — SigLIP 2 / schema 2

## Current status: 0.3.1 (7) — native parity passed; IPA verified

Source HEAD `18ad52d37690ecfbf92b63a21285a6c3e8e753d4`;
[CI 35840838147](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147)
/ [job 107115240763](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/job/107115240763).
**SUCCESS on the first attempt, with no fix/retry needed**; logs contain
`TEST SUCCEEDED` and `BUILD SUCCEEDED`. This documentation-only edit records the
supplied verified results; it runs no commands, tests, downloads or CI queries.

- Source/static checks **30 passed**; core **79 passed**. App **215 total:
  214 passed, 1 physical-device file-protection skip on simulator, 0 failures**.
- **All 7 GeneratedModelParityTests passed in 67.736 seconds**, with no parity
  skip. All **7 UI tests passed in 202.143 seconds**. The parity tests are included
  in the App total, not seven additional App tests.
- IndexPipeline **15**, PlaceAvailability **17**, BundledPlaces **2**, and
  IndexPlacesPresentation **3** tests all passed, also included in the App total.
  Public-place generation and test_places passed; 25 tests is the code/prior-local
  declared count, not a separately verified CI log total here.
- [Model-report artifact 10741671604](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35840838147/artifacts/10741671604)
  records **23 cases, 92 comparisons**, minimum cosine `0.9999999999960657`,
  maximum raw component difference `0.000011444091796875`, and maximum paired
  matrix difference `1.8557397291063538e-7`. These are this run's export results,
  not relabelled build 6 values. Native `not-run` exporter markers precede XCTest;
  the later passing XCTest results establish native parity.
- Simulator/device App resources and IPA validation passed; iPhoneOS arm64
  Release build succeeded. Device report: **0.3.1 (7), iphoneos18.5, arm64 Release,
  unsigned, Xcode 16.4, minimum iOS 17.0**. Artifact **10741731376** was completely
  downloaded with bounded-memory streaming; local length/SHA-256 verified and
  post-download report written/checked. Exact identity and local package link:
  [BUILD_STATUS.md](BUILD_STATUS.md).
- **20 native UI frames retrieved, only 3 new index/place frames reviewed** in the
  [960×680 contact sheet](../build/ui-review/35840838147/index-places-contact.jpg):
  Library after backfill, Library with zero GPS, and Settings with locations not
  checked. Visible content is readable; disclosures remained collapsed, so not
  every expanded internal counter was visually checked. Counts are synthetic,
  not user GPS results; this is not a physical-iPhone test.

This is not another model migration. Both image and text remain
`google/siglip2-base-patch16-224` at revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`, with the same schema 2 / FP32 /
768D contract, tokenizer, preprocessing, `photokit-preview-v1` and modelVersion:
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
Build 6's results below remain the historical numerical baseline. Build 7's own
passing XCTest results above establish its native parity; unchanged model identity
or successful conversion alone would not establish that result.

Build 7 adds one-ahead cache/PhotoKit preparation overlapped with parent processing,
not multiple inference workers: one model pair, serial inference and ordered
commits, with the child cancelled/drained on exit and late PhotoKit callbacks
ignored by the existing gate. No new arbitrary limits or network policy changes.
Separate pipeline/place tests cover these contracts; generated-model parity alone
does not establish cancellation, persistence or location classification.

Actual **device-package** checks confirm the China/France/Germany/Netherlands pack:
**2,943 features, 15,175,079 bytes, CHN/FRA/DEU/NLD, 8 sources**, GeoJSON SHA-256
`41d12962d73abf3976c55a83299a963385670c9f331597ab1ead6ddc0ed47ab4`, and manifest
SHA-256 `0b060aab6515670f136beed831ec043fe8d9e9bdce25c23802e8e9b3bda61812`.
These are not merely local [manifest](../Resources/Places/places-manifest.json)
metadata. Sources represent 2017–2022 administrative boundaries, not
global/current-address coverage.
[BundledPlacesTests.swift](../Tests/BundledPlacesTests.swift) checks the host app's
bytes/hash/counts and four public city reference points plus uncovered New York;
both tests passed in this run. That is not a private-library GPS measurement.

Install the delivered IPA using the same Sideloadly identity/effective Bundle ID.
Valid 0.3.0 image vectors are reused in one **Library → Index / resume**
places-backfill pass; no uninstall, index clear or whole-image re-encoding.
Only new/changed photos need normal image encoding. GPS observations are per scan,
separate from saved labels, with no-GPS/no-pack/outside/unavailable distinguished.
Weight **0.6** and centered scoring stay unchanged; added place inputs intentionally
can change rankings. Keep the app foreground and network off. User-side installation
and physical-phone behavior, file protection, performance and private-library
coverage are not yet verified; no speedup or coverage is promised. Model/geography
license review remains separate. Full scope and delivery evidence:
[INDEX_PIPELINE_PLACES.md](INDEX_PIPELINE_PLACES.md) and
[BUILD_STATUS.md](BUILD_STATUS.md).

## Historical evidence: 0.3.0 (6) — native parity passed; IPA verified

All execution counts, measured values, package and review results in this section
belong to the previous build 6, not build 7.

User-approved paired model replacement, source
`f9a2c85e9307cf365a8c2f62ec57eaf6e01bad78`.
[CI 35824403795](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35824403795)
/ job `107062896845`: **SUCCESS**, with `TEST SUCCEEDED` and `BUILD SUCCEEDED`.
Xcode 16.4 / Swift 6 toolchain (App Swift 5 language mode), iOS 18.5 simulator;
unsigned FP32 device build uses iphoneos18.5 / arm64 / minimum iOS 17.0.

- Core: **79 passed**. App: **178 total, 177 passed, 1 physical-protection skip,
  0 failures**. All **7 UI tests passed**. Thirty Python static tests also passed;
  static/core results are not substitutes for the native evidence below.
- **All 7 GeneratedModelParityTests passed in 72.985 seconds**, with no parity
  skip: exact Gemma IDs/masks including Final_Sigma, full same-tensor controls,
  native preprocessing and requested CPU / `.all` checks. Gates are unchanged.
- The production encoder API test **passed with asserted counts of 23 predictions
  (17 text + 6 image previews) and 58 measurements**. These are actual execution
  results, not planned coverage; measurement types and their limits are below.
- Corrected-run FP32 export: **23 cases, 92 comparisons**; minimum cosine
  `0.9999999999960657`, maximum raw error `0.000011444091796875`, and maximum
  paired-matrix difference `1.8557397291063538e-7`.
- The build 6 IPA download is **complete**, with bounded-memory streaming and local
  length/SHA-256 verification. Artifact 10734323054 and exact package identity
  are recorded in [BUILD_STATUS.md](BUILD_STATUS.md); this is not a device test.
- 17 native UI screenshots were retrieved, but **only 4** (Home, Library,
  Settings, hero results) reviewed in the downscaled
  [contact sheet](../build/ui-review/35824403795/siglip2-ui-contact.jpg).
  Synthetic/test scenes only, no private photos; not 17 reviewed screenshots.

Model version:
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`.
Export JSON native `not-run` markers were emitted **before XCTest** and remain
provenance, not failure indicators. The subsequent passing XCTest is the native
evidence; it does not rewrite the export inputs.

### Initial failed run and correction retained

[Run 35823153931](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35823153931)
at `aee4cdc00be92e1699f68baa9ef7ccc72cbcfbda` passed static/core checks, FP32
export, same-tensor native predictions and all seven UI tests, but **failed**
native low-resolution resizing and Greek Final_Sigma checks. The correction uses
Pillow-compatible 22-bit separable bilinear resampling and Unicode Final_Sigma
context, with ten image and three Unicode regression tests added. **68×120 and
112×199 native cases now pass**, as do exact token checks. Fixtures, queries,
full same-tensor controls and numerical thresholds were not weakened or bypassed.

Historical CLIP/WordPiece/raw-512 reports and prior successful builds are retained
in [BUILD_STATUS.md](BUILD_STATUS.md). They are not proof for SigLIP 2. All
acceptance requirements below describe the unchanged tests that passed in the
corrected build 6 run and again in build 7, whose XCTest evidence is recorded above.
Physical-iPhone behavior/performance and license review remain separate boundaries.

## Authoritative model and tokenizer contract

[IMPLEMENTATION_CONTRACT.md](IMPLEMENTATION_CONTRACT.md) defines schema 2. Both
image and text use `google/siglip2-base-patch16-224`, revision
`75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`; never mix old and new towers.

- Image input: `pixel_values`, Float32 `[1,3,224,224]`. Apply EXIF orientation,
  RGB conversion, direct 224×224 warp with no aspect preservation or center crop.
  The independent reference uses Pillow 11.1.0 BILINEAR (`resample=2`), division
  by 255, then mean/std `[0.5,0.5,0.5]` in NCHW layout.
- Text input: ONLY `input_ids`, Int32 `[1,64]`. Both outputs are raw Float32
  `[1,768]` `output_embedding` values from `pooler_output`. Keep the learned
  vision pooling/text heads; text pools position 63 even when it contains PAD.
  No masked mean, last-EOS pooling, replacement projection, sigmoid, logit
  scale/bias or export-side L2 normalization. Swift normalizes once for storage
  and retrieval.
- Native [SigLIPTokenizer.swift](../App/Inference/SigLIPTokenizer.swift) uses the
  `Tokenizers` product of `swift-transformers` **1.3.4**, pinned in
  [project.yml](../project.yml). It loads both unchanged JSON resources locally
  with strict loading, never downloads or falls back to the retired tokenizer.
  This App dependency does not change the Foundation-only core's dependency
  boundary.
- The Python reference explicitly calls `str.lower()` before its local fast
  Gemma tokenizer. Swift explicitly lowercases before JSON tokenization; exact
  multilingual fixtures must establish parity, not an assumption that all
  Unicode lowercasing is identical. Preserve the JSON normalizer and added
  tokens; no trimming, casefolding, accent stripping or manual Chinese splitting.
- Retain at most 63 content tokens, append EOS 1, right-pad PAD 0 to 64; no
  automatic BOS. Literal BOS 2, UNK 3, EOS and PAD remain content. A literal PAD
  has mask 1, so masks cannot be inferred from nonzero IDs. Empty input is
  `[1,0,...,0]`. `attentionMask` is checked in fixtures but NEVER sent to Core ML.

## Test scope

[GeneratedModelParityTests.swift](../Tests/GeneratedModelParityTests.swift) is an
app-hosted XCTest suite importing `LocalImageIQ` and `ImageIQCore`. It consumes
the real generated resources from [export_models.py](../scripts/export_models.py),
using the field names from that exporter and
[synthetic_fixtures.py](../scripts/synthetic_fixtures.py). It does not generate
surrogate reference embeddings, download weights, compile models at runtime,
or touch personal photos.

The native consumer and generated tests target this contract and passed in the
historical corrected build 6 run and in the current build 7 run above. Source
presence alone would not establish execution. This
documentation edit performs no export, test run, installation or CI action;
passing source checks or Python export alone is not a native parity result.

## Test host and resource gate

Include the test source in the app-hosted XCTest target whose host application
and module are `LocalImageIQ`, with testability enabled. Supply the exporter's
completed model resources in the test build; Xcode must compile both model
packages to bundled `.mlmodelc` resources. There is no runtime `.mlpackage`
compilation fallback.

Required resource names (generated artifacts, not checked-in references):

- model-manifest.json
- ImageEncoder.mlmodelc and TextEncoder.mlmodelc
- tokenizer.json and tokenizer_config.json, byte-for-byte from the shared revision
- tokenizer-parity.json and image-preprocess-parity.json
- All PNG and float32 little-endian tensor files named in the image document's
  `cases[].image` and `cases[].tensor` fields, normally under the fixtures folder.

Resource lookup calls the actual `BundleResources.url` API from
[ModelManifest.swift](../App/Inference/ModelManifest.swift): bundle root, Models,
Resources/Models, and Resources. `Bundle.main` is tried first, then
`Bundle(for: type(of: self))`. When the host app has a manifest, its models and
two tokenizer JSONs are mandatory; a complete test bundle cannot mask broken app
packaging. A test-bundle-owned complete pair is supported when the app has no
manifest. Fixture documents may live in either bundle and must match the
selected manifest's version and pinned sources. Fixture files are resolved
relative to the image document first, then through bundle lookup, including
Xcode-flattened resources. Both tokenizer JSONs must be colocated and owned by
the selected manifest bundle; their two hashes, and PNG/tensor hashes, are
checked against fixture metadata. No retired vocabulary resource is required.
There is no source-tree, working-directory, network, or user-provided external-path
fallback.

| Build state | Result |
| --- | --- |
| No generated resources in either bundle, and no required-model environment flag | Fixture/model tests explicitly `XCTSkip`: model-free, parity not run. |
| `IMAGEIQ_REQUIRE_MODELS=1` reaches the test runner/host | Missing manifest, model, either tokenizer JSON, document, or referenced fixture fails; never silently skips for missing models. |
| App manifest exists, even without the flag | Model-enabled automatically; missing resources fail. |
| Test-bundle manifest exists, or partial model/fixture resources exist without a manifest | Complete test-bundle pair is tested, or incomplete packaging fails rather than skips. |
| Generated resources are present but malformed, mismatched, or model loading/prediction fails | Fails; no model-free fallback. |

Inject environment variables into the actual XCTest runner/test-host process
through the scheme/test plan or runner configuration. A variable set only in an
outer build shell is not proof it reaches XCTest. The attachment records
`requireModels`, `resourceGate`, and the selected bundle. A model-enabled CI
runner should set `IMAGEIQ_REQUIRE_MODELS=1` even if it expects the app manifest:
this detects accidentally omitting the entire model resource set.

The independent solid-color test always runs without model resources. An
optional `.all` test checks resource availability before its engine opt-in skip;
its skip cannot conceal missing resources in an enabled build.

## Tests and numerical acceptance

The requirements below remain the unchanged test contract. Both build 6 and
build 7 passed all seven tests; their run-specific timings and totals are separate
above. Per-test prediction/measurement counts below are assertions in that contract,
not extra suite tests or additional exporter comparisons.

| Test | Input and acceptance |
| --- | --- |
| `testGeneratedGemmaIDsAndMasksMatchAllCases` | Actual bundled JSONs and native `SigLIPTokenizer`; all 64 IDs and mask entries match exactly for each of the 17 pinned cases. |
| `testTextEncoderCPUReferenceAndNativeTokensParity` | Load text model once with `.cpuOnly`. For every query, predict separately from fixed fixture IDs and native IDs; no mask model input. Both raw predictions require maxAbs ≤ 0.001 and cosine > 0.999 against both `referenceRaw` and `coreMLRaw`; app-normalized output cosine > 0.999. Token mismatches fail independently without suppressing the fixed-input control. |
| `testImageEncoderCPUSameFloatInputParity` | Load image model once with `.cpuOnly`, feeding each full reference tensor unchanged. Against both raw references: maxAbs ≤ 0.001 and cosine > 0.999; app-normalized cosine > 0.999. This isolates runtime/conversion from interpolation and decoding. |
| `testNativeImagePreprocessingCPUParity` | Decode all six PNGs through native preprocessing; attach full-tensor maxAbs/MAE. Raw and normalized embedding cosine ≥ 0.995 against both references. Interpolated pixel errors are diagnostic, not bit-exact gates; EXIF rotation/mirroring and both low-resolution inputs are mandatory. |
| `testKnownSolidRGBNormalizationWithoutModels` | Six uniform sRGB colors: (31,127,223), red, green, blue, black, white. Every NCHW component matches independently pinned mean/std 0.5 within 0.00001. Requires no models and does not derive expected constants from production code. |
| `testGeneratedPairAllComputeUnitsParityWhenRequested` | Opt in with `IMAGEIQ_TEST_ALL_COMPUTE_UNITS=1`. Repeat both text-input paths, unchanged image-tensor control, and native image preprocessing with `.all`, using the same numerical criteria. This is separate from the CPU export-comparison gates. |
| `testAppEncodersModelSizedPreviewAndAllTextReferenceParity` | Exercise production `CoreMLEncoders` with `.all` in every model-enabled build, independently of the optional-engine flag. Six actual-sized synthetic CGImage previews + 17 texts yield 23 predictions. Outputs must already be 768D unit vectors (norm error ≤ 1e-5); compare to each normalized raw reference with image cosine ≥ 0.995 and text cosine > 0.999. The 58-measurement count was asserted and passed; details below. |

The production API test retains raw ImageIO pixels, including **68×120** and
**112×199**, until the App actor performs its 224×224 warp. There is no test-side
preview upscaling or PNG/JPEG round trip. ImageIO reads actual EXIF orientation;
fixture metadata is a check, not a substitute for that observation.

Asserted counts for this API test, which passed in both build 6 and build 7:

- 6 image + 17 text predictions = **23**.
- 6 exact direct-CGImage/native-data tensor comparisons + 6 diagnostic native/HF
  tensor comparisons = **12** tensor measurements.
- Each of 23 normalized outputs compared with two raw references after reference
  normalization = **46** embedding gates. Total **58** measurements.
- Do not normalize the App output again and hide a normalization bug. The test
  checks its norm directly. These counts are not the entire suite's test count.

Separately, the exporter completed 23 cases × four stages = **92** comparisons:
`referenceVsWrapper`, `wrapperVsTrace`, `traceVsCoreML`, `referenceVsCoreML`.
Every stage requires cosine > 0.999; the first two require maxAbs ≤ 1e-5, the
saved Core ML comparisons ≤ 1e-3. The 17×6 paired cosine matrix has 102 entries
and requires maxAbs ≤ 1e-4; independent Pillow/HF pixels require ≤ 1e-6.
All export gates passed in build 6 and build 7. Their measured minima/maxima are
recorded in the separate run sections above; build 7's own model-report artifact
10741671604 supplies its values even though they match build 6 numerically.

All criteria above are numerical validation assertions, not production search
filters, query rejection policies, runtime ceilings, performance quotas, or
claims about retrieval quality. Thresholds are explicit constants in the tests;
they are not relaxed based on a fixture's recorded result. An actual failure
requires diagnosis, not a claim that native parity has been established.

`.all` permits Core ML to select available engines; it does not prove that the
Neural Engine or GPU actually executed a particular operation. The attachment
records the requested configuration and OS, not a guessed execution engine.
CPU parity and optional device-engine parity are distinct gates. Simulator
success cannot establish physical-device performance or engine parity.

## Fixture contract and coverage

Documents contain `schemaVersion:2`, `modelVersion`, `embeddingDimension:768`,
`embeddingsAreRaw:true`, `reference`, `nativeParity:"not-run"`, and `cases`.
Embeddings are raw 768-dimensional pooler outputs, not normalized reference
vectors. Tests validate header/source identity against `ModelManifest.validate()`.
The exported semantic version is `siglip2-b16-224-v1-` followed by the canonical
contract's 64-character lowercase SHA-256, not a report timestamp or old CLIP ID.

Text cases use `id`, `text`, `lowercasedText`, `inputIDs`, `attentionMask`,
`referenceRaw`, and `coreMLRaw`. The root also carries `sequenceLength:64`,
`textModel`, `tokenizerFile`, `tokenizerConfigFile`, `tokenizerSHA256`,
`configSHA256`, `tokenizerClass:"GemmaTokenizerFast"`, `tokenizerOptions`,
`preprocessing`, and `backendNormalizer`. The two hashes cover the tokenizer
JSON and its tokenizer configuration, not the model configuration. No legacy
vocabulary hash or SentenceTransformer reference alias is used.

Exactly 17 IDs and their original UTF-8 text are pinned, preventing missing,
extra, duplicate or silently simplified cases: english, chinese, case,
diacritics, combining, punctuation, special-tokens, empty, whitespace-controls,
unknown-unicode, long-word, long-truncation, greek-sigma,
turkish-unicode-chinese, gemma-turn-tokens, literal-pad, whitespace-only.
Feed original text to the production tokenizer, which applies explicit lowercase;
do not repair fixture text, change normalization or replace exact IDs with an
embedding-similarity check. Attachments preserve Unicode scalars, arrays,
masks and mismatched positions. Greek contextual sigma, dotted I, combining
marks, Chinese and literal PAD are real parity gates, not optional examples.

Image case fields are `id`, `image`, `imageSHA256`, `sourceSize`,
`exifOrientation`, `orientedSize`, `resizedSize`, `cropXYWH`, `tensor`,
`tensorSHA256`, `tensorBytes`, `dtype`, `shape`, `layout`, `spotChecks`,
`pillowVsHFMaxAbs`, `referenceRaw`, and `coreMLRaw`. A spot check has
`channel`, `y`, `x`, and `value`. The `tensor` string is a resource-relative path,
not an inline array or a nested reference object. Each tensor is exactly
602,112 bytes: Float32 little-endian, C-order NCHW `[1,3,224,224]`.
Byte-wise decoding avoids alignment and host-endianness assumptions; shape,
length, hash, finiteness, and JSON spot checks validate the interpretation.

Exactly six image cases are required: solid-rgb (224×224), checker-nonsquare
(319×231), exif-rotate-6 (321×197), exif-mirror-2 (197×321), lowres-68x120
(68×120), lowres-112-portrait (112×199). Original and oriented dimensions are
distinct; `resizedSize:[224,224]` and `cropXYWH:[0,0,224,224]` describe the whole
warped input, **not a crop operation**. The small images are procedural fixtures,
not captured PhotoKit data or proof of actual preview quality.

The native preprocessing test calls `ImagePreprocessor.values(data:)` without
an orientation override, so that function must read EXIF from the image itself.
Independently, ImageIO reads the actual orientation and dimensions; both must
agree with the fixture. The test then passes the ImageIO-derived orientation
to `ImagePreprocessor.tensor(data:orientation:)`, because the app API requires
it, and compares that tensor exactly with the no-override native values. This
same-native-path equality is not an assertion of native/Pillow equality.
Expected orientation is never substituted for observed image metadata.

Quartz only converts native pixels to sRGB; an explicit separable, 22-bit fixed-point
resampler follows Pillow 11.1.0 BILINEAR, including downsampling and per-pass 8-bit rounding.
EXIF is applied by integer pixel addressing before resizing. The full native
tensor is measured against the export tensor, but arbitrary per-pixel error
ceilings are not imposed on interpolated images. The semantic-output acceptance
for this preprocessing path is cosine ≥ 0.995; tensor max/MAE remain visible
for diagnosis. The strict unchanged-tensor test is essential: it distinguishes
conversion/runtime discrepancies from decoder/color/orientation/interpolation
discrepancies. Synthetic patterns do not prove real-photo retrieval quality.

## Runtime, memory, and result evidence

Tests call the production tokenizer, Int32 tensor builder, image preprocessing,
and `CoreMLEncoders.normalizedProjection`. Direct model tests use `MLModel`
because the actor's raw predictions/configuration are private and it selects
`.all`. CPU raw-component comparisons therefore need no production visibility
change. The separate API test exercises the actual actor's prepare, image-preview
and text calls. Neither path establishes PhotoKit availability, cancellation,
persistence or search UI behavior. Output coordinate indexing honors Core ML
strides instead of assuming contiguous memory.

Each role's model is loaded once per test, outside query/fixture loops, not once
per query. All fixtures run serially with a per-fixture `autoreleasepool`.
Only one image fixture's bytes/tensors are processed at a time. The optional
pair test finishes/releases the text model before loading the image model.
The production API test reuses one encoder actor for all 23 predictions.
Xcode runner-level parallelization is separate; select serial test execution
when memory measurements require avoiding overlapping test processes. The
suite adds no arbitrary memory caps, timeout rules, or speed requirements.

Each test adds an in-memory JSON `XCTAttachment` with `.keepAlways`, for retention
in the runner's `.xcresult`. Reports contain per-case raw/normalized cosine,
component max error, MAE, vector norms, acceptance bounds, token differences,
and stage/reference-group summaries (worst max error, mean case MAE, minimum
cosine, comparison/rejection counts). Reports also retain skip/error reasons
and any measurements completed before an error. They contain synthetic inputs
only; no photos, GPS, or user-library paths. The suite itself writes no files,
including no edits to source resources or export parity markers.

`completed` means the test body returned, not that all XCTest assertions passed.
XCTest failures and per-measurement `accepted` fields must be inspected; a
diagnostic-only tensor measurement being accepted means it was structurally
valid, not bit-exact. Token failures are reported independently. Group summaries
do not combine tensor-error units with embedding-error units. Preserve the
runner's result bundle to retain attachments, including successful runs.

Exporter `nativeParity: "not-run"` markers are preserved as input provenance;
this suite does not rewrite them to "passed". Only a subsequently executed
native XCTest result can establish these gates, on the OS and requested compute
configuration recorded in that run. Runs 35824403795 (build 6) and 35840838147
(build 7) each supplied passing native results; their pre-XCTest JSON markers are
not failed or unexecuted XCTest results.

## Migration, device use and unchanged boundaries

### Current: 0.3.0 → 0.3.1, reuse image vectors and backfill places

The semantic modelVersion and image policy do not change. The new IPA has passed
its gates and been completely downloaded/verified. Overwrite with the same
Sideloadly account/effective Bundle ID and open **Library → Index / resume** once.
Do not uninstall, clear storage or rebuild every image vector. Still-valid 0.3.0
rows bypass pixel fetch and image inference while locations are checked; changed
labels/geography or removed GPS can update/remove place embeddings, and compatible
distinct-place text vectors can be reused. New/changed photos encode normally.
Keep the app open and network off; interrupted indexing resumes through the same
entry. No original-download prerequisite or additional diagnostic round is added.

### Historical: 0.2.x CLIP → 0.3.0 SigLIP 2 model migration

That semantic modelVersion change required fresh image AND place-text vectors.
Legacy 512D cache decoding exists only for migration, not SigLIP 2 search or a
fallback encoder. The build 6 IPA was verified: overwrite with the same Sideloadly
account/effective Bundle ID, then **must use Library → Index / resume once**.
Before new vectors exist, old-model usable coverage is expected to be **0**
because that model changed. This does not apply to valid 0.3.0 rows in build 7.
Do not uninstall or manually clear the index.
Interrupted indexing reuses completed,
still-valid new rows. Photo `id` primary-key replacement means retained old IPA
files are not old-index backups; rollback cannot promise restored old vectors.

### Shared boundaries

`photokit-preview-v1` remains preview-first with reduced images accepted, network
default off, and fallback only after explicit user opt-in. Original downloads
are not required. This is not a preview-quality fix or a promise that every
cloud photo is available offline. After indexing, normal use is enough; no
extra test queries, diagnostic screenshots or user testing round is requested.

Synthetic numerical parity is not retrieval-quality evidence. The desktop
comparison had language/query/resolution trade-offs, not universal improvement;
desktop CPU timings and simulator `.all` results are not physical-iPhone
latency, engine, memory or heat measurements. Diagnostic scores/cosines cannot
be compared directly across CLIP and SigLIP 2 as a controlled quality measure.

Privacy and signing do not change: photos, GPS and vectors stay local; Apple
credentials do not go to chat/CI. Free development profiles normally expire
after seven days. The shared model card declares Apache-2.0; the exporter
copies actual license evidence where available and retains
`redistributionApproved:false` and manual review. License copies and successful
numerical checks are not legal certification for distribution.