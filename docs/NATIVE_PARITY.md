# Native generated-model parity

## Status and scope

[GeneratedModelParityTests.swift](../Tests/GeneratedModelParityTests.swift) is an
app-hosted XCTest suite importing `LocalImageIQ` and `ImageIQCore`. It consumes
the real generated resources from [export_models.py](../scripts/export_models.py),
using the field names from that exporter and
[synthetic_fixtures.py](../scripts/synthetic_fixtures.py). It does not generate
surrogate reference embeddings, download weights, compile models at runtime,
or touch personal photos.

This change adds test source and this document only. No native compilation,
execution, export, installation, project wiring, or CI execution was performed.
Passing source checks or the Python export is not a native parity result.

## Test host and resource gate

Include the test source in the app-hosted XCTest target whose host application
and module are `LocalImageIQ`, with testability enabled. Supply the exporter's
completed model resources in the test build; Xcode must compile both model
packages to bundled `.mlmodelc` resources. There is no runtime `.mlpackage`
compilation fallback.

Required resource names (generated artifacts, not checked-in references):

- model-manifest.json
- ImageEncoder.mlmodelc and TextEncoder.mlmodelc
- vocab.txt
- tokenizer-parity.json and image-preprocess-parity.json
- All PNG and float32 little-endian tensor files named in the image document's
  `cases[].image` and `cases[].tensor` fields, normally under the fixtures folder.

Resource lookup calls the actual `BundleResources.url` API from
[ModelManifest.swift](../App/Inference/ModelManifest.swift): bundle root, Models,
Resources/Models, and Resources. `Bundle.main` is tried first, then
`Bundle(for: type(of: self))`. When the host app has a manifest, its models and
vocabulary are mandatory; a complete test bundle cannot mask broken app
packaging. A test-bundle-owned complete pair is supported when the app has no
manifest. Fixture documents may live in either bundle and must match the
selected manifest's version and pinned sources. Fixture files are resolved
relative to the image document first, then through bundle lookup, including
Xcode-flattened resources. Vocabulary, PNG, and tensor hashes are checked against
the fixture metadata when consumed. There is no source-tree, working-directory,
network, or user-provided external-path fallback.

| Build state | Result |
| --- | --- |
| No generated resources in either bundle, and no required-model environment flag | Fixture/model tests explicitly `XCTSkip`: model-free, parity not run. |
| `IMAGEIQ_REQUIRE_MODELS=1` reaches the test runner/host | Missing manifest, model, vocabulary, document, or referenced fixture fails; never silently skips for missing models. |
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

| Test | Input and acceptance |
| --- | --- |
| `testGeneratedWordPieceIDsAndMasksMatchAllCases` | Actual bundled vocabulary and native `WordPieceTokenizer`; all 128 IDs and mask entries must match exactly for every generated text case. |
| `testTextEncoderCPUReferenceAndNativeTokensParity` | Load the text model once with `.cpuOnly`. For each query, predict separately using fixed fixture IDs/mask and native-generated IDs/mask. Both raw predictions require component max absolute error ≤ 0.001 and cosine > 0.999 against both `sentenceTransformerRaw` and `coreMLRaw`. App-normalized outputs also require cosine > 0.999. Token mismatches fail independently and do not suppress the fixed-input control prediction. |
| `testImageEncoderCPUSameFloatInputParity` | Load the image model once with `.cpuOnly`; feed the full reference tensor unchanged. Against each ST/export raw vector: every component error ≤ 0.001 and cosine > 0.999; app-normalized output cosine also > 0.999. This isolates model conversion/runtime from decoding and interpolation. |
| `testNativeImagePreprocessingCPUParity` | Decode each actual fixture PNG through native preprocessing, compare every tensor component to the full reference tensor, and attach max absolute error/MAE. Raw and app-normalized output cosine must be ≥ 0.995 against both ST and export references. Non-solid tensor errors are diagnostic, not bit-exact requirements. Rotation 6 and mirror 2 examples are mandatory. |
| `testKnownSolidRGBNormalizationWithoutModels` | Six uniform sRGB images: (31,127,223), red, green, blue, black, white. Every NCHW component must match independently pinned normalization constants within 0.00001. This needs no models and does not take expected constants from the implementation under test. The generated solid fixture and its reference tensor receive the same pin in the native preprocessing test. |
| `testGeneratedPairAllComputeUnitsParityWhenRequested` | Opt in with `IMAGEIQ_TEST_ALL_COMPUTE_UNITS=1`. Repeat both text-input paths, unchanged image-tensor control, and native image preprocessing with `.all`, using the same numerical criteria. This is separate from the CPU export-comparison gates. |

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

Documents contain `schemaVersion`, `modelVersion`, `embeddingDimension`,
`embeddingsAreRaw`, and a `cases` array. Embeddings are raw 512-dimensional
projections, not normalized reference vectors. The tests validate header/source
identity against the app's `ModelManifest.validate()` contract.

Text cases use `id`, `text`, `inputIDs`, `attentionMask`,
`sentenceTransformerRaw`, and `coreMLRaw`. The text document also carries
`sequenceLength`, `textModel`, `vocabularySHA256`, and `backendNormalizer`.
The latter uses the HF keys `type`, `clean_text`, `handle_chinese_chars`,
`strip_accents`, and `lowercase`; it is not a Swift-renamed schema.

Every case is tested, including future additional cases. The current required
IDs prevent accidental coverage loss: english, chinese, case, diacritics,
combining, punctuation, special-tokens, empty, whitespace-controls,
unknown-unicode, long-word, and long-truncation. No NFC/NFD conversion,
lowercasing, accent stripping, or correction of fixture text happens in the
test. Exact comparison intentionally exposes tokenizer/normalizer bugs rather
than accepting a similar embedding as evidence of correct tokenization.
Attachments include Unicode scalar values, both token arrays, both masks, and
all mismatched positions, including length discrepancies.

Image case fields are `id`, `image`, `imageSHA256`, `sourceSize`,
`exifOrientation`, `orientedSize`, `resizedSize`, `cropXYWH`, `tensor`,
`tensorSHA256`, `tensorBytes`, `dtype`, `shape`, `layout`, `spotChecks`,
`pillowVsHFMaxAbs`, `sentenceTransformerRaw`, and `coreMLRaw`. A spot check has
`channel`, `y`, `x`, and `value`. The `tensor` string is a resource-relative path,
not an inline array or a nested reference object. Each tensor is exactly
602,112 bytes: Float32 little-endian, C-order NCHW `[1,3,224,224]`.
Byte-wise decoding avoids alignment and host-endianness assumptions; shape,
length, hash, finiteness, and JSON spot checks validate the interpretation.

The native preprocessing test calls `ImagePreprocessor.values(data:)` without
an orientation override, so that function must read EXIF from the image itself.
Independently, ImageIO reads the actual orientation and dimensions; both must
agree with the fixture. The test then passes the ImageIO-derived orientation
to `ImagePreprocessor.tensor(data:orientation:)`, because the app API requires
it, and compares that tensor exactly with the no-override native values. This
same-native-path equality is not an assertion of native/Pillow equality.
Expected orientation is never substituted for observed image metadata.

`CGContext` high-quality interpolation is not Pillow BICUBIC. The full native
tensor is measured against the export tensor, but arbitrary per-pixel error
ceilings are not imposed on interpolated images. The semantic-output acceptance
for this preprocessing path is cosine ≥ 0.995; tensor max/MAE remain visible
for diagnosis. The strict unchanged-tensor test is essential: it distinguishes
conversion/runtime discrepancies from decoder/color/orientation/interpolation
discrepancies. Synthetic patterns do not prove real-photo retrieval quality.

## Runtime, memory, and result evidence

Tests call the production tokenizer, Int32 tensor builder, image preprocessing,
and `CoreMLEncoders.normalizedProjection`. They use `MLModel` directly because
the actor's raw predictions/model configuration are private and its loader
selects `.all`. Thus CPU raw-component comparisons do not require changing app
visibility or configuration. These are not tests of the actor's loading/cache,
PhotoKit, cancellation, persistence, or search UI. Output coordinate indexing
honors Core ML strides instead of assuming contiguous output memory.

Each role's model is loaded once per test, outside query/fixture loops, not once
per query. All fixtures run serially with a per-fixture `autoreleasepool`.
Only one image fixture's bytes/tensors are processed at a time. The optional
pair test finishes/releases the text model before loading the image model.
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
configuration recorded in that run.