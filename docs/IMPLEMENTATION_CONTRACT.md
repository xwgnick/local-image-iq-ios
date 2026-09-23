# Local Image IQ — native iOS milestone

Recovered agreement: SwiftUI + PhotoKit + Core ML, developed from Windows;
manual macOS GitHub Actions builds in a **private** repository. No web wrapper,
photo uploads, automatic repository publication, developer-account credentials,
signing or TestFlight submission in this milestone.

## Scope and delivery boundary

First native vertical slice: authorize a photo subset, index locally, reuse
unchanged records, search text, preview a result. Limited Photos access must work.
Indexing is foreground/cancellable, not a promise of unlimited background work.
iCloud-only photos are skipped unless the user explicitly enables downloading
originals. No application server is needed.

Windows has no Swift/Xcode or configured Git remote. A source/config check is
not an iOS compilation. Model export, native numerical parity, simulator build,
physical-device latency, heat and signing remain separately verifiable gates.
The app must report missing bundled models honestly, never simulate relevance.

## Pinned paired models — SigLIP 2 replacement (schema 2)

- Image and text: the SAME public `google/siglip2-base-patch16-224` checkpoint,
  revision `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2`.
  This replaces the former encoder pair; there is no legacy model branch.
  The pinned sparse config has `model_type: siglip`, text vocabulary 256000,
  and built-in Siglip text/vision types, not NaFlex or custom remote code.
  Resolve and check the Transformers 4.48.3 architectural defaults before loading
  weights: both towers hidden size 768, 12 layers, 12 heads, MLP width 3072;
  vision patch size 16, image size 224; text maximum positions 64.
- Image input `pixel_values`: Float32 `[1,3,224,224]`.
- Text input `input_ids`: Int32 `[1,64]`, the ONLY text model input.
- Both outputs `output_embedding`: Float32 `[1,768]`, **raw pooler_output**.
  The independent Python reference calls `SiglipModel.get_image_features()` and
  `SiglipModel.get_text_features()`; in pinned Transformers 4.48.3 these return
  raw Tensors. The wrappers call `vision_model(...).pooler_output` and
  `text_model(input_ids=...).pooler_output`, respectively. Keep the entire learned
  vision attention pooling head and text head. Text pools the final sequence
  position (index 63, which can contain PAD), not the last mask=1/EOS position.
  Do not add mean pooling, an EOS search, a replacement projection, sigmoid,
  logit scale, logit bias or output L2 normalization. Internal model layer norms
  remain unchanged. Never use the normalized paired `SiglipModel.forward()` as
  the raw reference.
  Swift normalizes each encoder output exactly once before storage/retrieval.
- Image: apply EXIF orientation, convert to RGB, warp directly to 224x224 with
  Pillow 11.1.0 BILINEAR (`resample=2`), without preserving aspect ratio and
  without center cropping; divide by 255 and normalize NCHW with both mean
  `[0.5,0.5,0.5]` and std `[0.5,0.5,0.5]`.
  Independent Pillow/NumPy pixels must match the pinned `SiglipImageProcessor`
  at maxAbs <= 1e-6. Preserve `sourceSize` (original width/height before EXIF),
  `orientedSize`, and `resizedSize:[224,224]`. Keep `cropXYWH:[0,0,224,224]`
  for compatible fixture decoding: it describes the full warped tensor, NOT
  an operation that removes pixels. Native CoreGraphics adaptation/parity is
  separate; high-quality CoreGraphics interpolation is not assumed identical.
- Text: explicit Python `str.lower()` BEFORE calling local HF
  `AutoTokenizer(..., use_fast=True)` / `GemmaTokenizerFast`. Merely setting
  `do_lower_case` in config is insufficient in 4.48.3. This is not casefold,
  locale-sensitive lowercase, trimming, accent stripping or manual Chinese
  splitting. Preserve the bundled tokenizer JSON normalizer and added tokens.
  The authoritative tokenizer call uses `add_special_tokens=True`,
  `truncation=True`, `max_length=64`, `padding="max_length"`,
  `return_attention_mask=True`, `return_token_type_ids=False`.
  At most 63 content tokens plus one appended EOS id 1, no automatic BOS,
  right-pad with PAD id 0 to 64. BOS id 2 and UNK id 3 remain valid literal
  content tokens. Literal `<eos>`, `<bos>`, `<pad>` and other Gemma added tokens
  must not be removed or escaped. A literal content PAD has attention mask 1;
  do not derive masks from `input_ids != 0`. Empty input is `[1,0,...,0]`.
  `attentionMask` is retained in fixtures for exact checks but NEVER passed to
  the reference model, wrapper, trace or Core ML model.
  Greek contextual sigma, Turkish dotted I, combining marks and Chinese require
  exact fixture parity; do not assume Swift lowercase behavior is identical.

Bundle resources (produced by an explicit macOS conversion step):
`ImageEncoder.mlpackage`, `TextEncoder.mlpackage`, `tokenizer.json`,
`tokenizer_config.json`, `model-manifest.json`.
The two tokenizer JSONs are required runtime resources, copied byte-for-byte
from the same checkpoint, not regenerated or simplified. The exporter reloads
them from staging without any slow SentencePiece file and compares all query
IDs/masks with the source tokenizer. Xcode compiles model packages to `.mlmodelc`.
No `vocab.txt` is produced: successful publishing removes that retired
exporter-owned file if present. Unowned README/Places resources remain untouched.
Optional offline boundaries: `Places.geojson`; no online geocoder fallback.

Manifest template fields: `schemaVersion:2`, `modelVersion` (string),
`dimension:768`, `sequenceLength:64`, `imageSize:224`,
`imageModel` and `textModel` (objects with `id`, `revision`),
`imageInput:"pixel_values"`, `textInputs:["input_ids"]`,
`output:"output_embedding"`, `tokenizerFile:"tokenizer.json"`,
`tokenizerConfigFile:"tokenizer_config.json"`, `features`, `preprocessing`.
`features` has exactly three groups: `image.pixel_values` float32 `[1,3,224,224]`,
`text.input_ids` int32 `[1,64]`, `output.output_embedding` float32 `[1,768]`.
The semantic version is the exact prefix `siglip2-b16-224-v1-` followed by
64 lowercase hexadecimal SHA-256 characters of canonical JSON containing
`imageModel`, `textModel`, `features`, `preprocessing` (sorted keys, compact
separators, UTF-8, unescaped Unicode, no NaN). It is not a timestamp/path/report
hash. Preprocessing includes the tokenizer filenames, explicit lowercase,
special-token policy, unmasked pooling, warp geometry and raw-output policy.

The successfully exported manifest additionally has `parity`,
`provenance:"provenance.json"`, `redistributionApproved:false`, and
`artifactsSHA256` for all staged files except the manifest itself. `parity`
contains `status:"passed"`, `report:"parity-report.json"`, `precision:"float32"`,
`computeUnits:"CPU_ONLY"`, and `nativeTokenizer`, `nativePreprocessing`,
`nativeRuntime` each `"not-run"`. Only publish this commit marker last after
successful conversion, saved-package reload and all Python numerical gates.
A failed rerun invalidates any previous marker; old packages without a valid
marker are stale, never a successful fallback.

### Fixture and parity schema (all exporter-generated JSON schemaVersion 2)

Tokenizer and image fixture roots share `schemaVersion`, `modelVersion`,
`embeddingDimension:768`, `embeddingsAreRaw:true`, `reference` (description),
`nativeParity:"not-run"`, and `cases`.

- `tokenizer-parity.json` also contains `sequenceLength:64`, `textModel`,
  `tokenizerFile`, `tokenizerConfigFile`, `tokenizerSHA256` (tokenizer.json bytes),
  `configSHA256` (tokenizer_config.json bytes, NOT the model config),
  `tokenizerClass:"GemmaTokenizerFast"`, `tokenizerOptions`, `preprocessing`,
  and `backendNormalizer`. Each case has `id`, original `text`, `lowercasedText`,
  `inputIDs` (64 integers), `attentionMask` (64 binary integers),
  `referenceRaw` and `coreMLRaw` (768 finite floats each). Hashes must equal
  the corresponding `artifactsSHA256` entries. There is no legacy vocabulary hash.
- `image-preprocess-parity.json` also contains `imageModel` and image
  `preprocessing`. Each case has `id`, `image`, `imageSHA256`, `sourceSize`,
  `exifOrientation`, `orientedSize`, `resizedSize`, `cropXYWH`, `tensor`,
  `tensorSHA256`, `tensorBytes:602112`, `dtype:"float32-little-endian"`,
  `shape:[1,3,224,224]`, `layout:"NCHW"`, `spotChecks`, `pillowVsHFMaxAbs`,
  `referenceRaw` and `coreMLRaw`. Full pixel tensors live in binary fixtures,
  not enormous JSON float arrays.
- `parity-report.json` has `schemaVersion`, `modelVersion`, `precision`,
  `computeUnits`, `thresholds`, `cases`, `pairedCosines`, `passed:true`,
  `nativeTokenizerParity`, `nativeImagePreprocessParity`,
  `nativeModelRuntimeParity` (all `"not-run"`), and
  `semanticRetrievalQuality:"not-evaluated"`.
  Each case is `{role,id,comparisons}`. Comparison keys are exactly
  `referenceVsWrapper`, `wrapperVsTrace`, `traceVsCoreML`, `referenceVsCoreML`;
  each measurement has `maxAbs`, `cosine`, `referenceNorm`, `candidateNorm`.
  `pairedCosines` has `queryIDs`, `imageIDs`, `reference` and `coreML`
  matrices, plus `maxAbs`. No legacy reference field aliases are emitted.

All four stages require cosine > 0.999 (strict). Reference/wrapper and
wrapper/trace require maxAbs <= 1e-5; both saved Core ML comparisons require
maxAbs <= 1e-3. The complete paired text/image cosine matrix requires
maxAbs <= 1e-4. Report threshold keys are `minCosineExclusive`,
`conversionMaxAbsInclusive`, `torchMaxAbsInclusive`, `similarityMaxAbsInclusive`,
`preprocessMaxAbsInclusive`. CLI overrides may tighten but never weaken these
gates. Reject nonfinite/zero vectors, wrong tensor dtype/shape, changed Core ML
feature names/order and flexible shapes. L2 normalization is used only to
compute comparison cosines, never to overwrite raw fixtures or model outputs.

Coverage: 17 queries (the original 12 categories, now with Gemma special tokens,
plus `greek-sigma`, `turkish-unicode-chinese`, `gemma-turn-tokens`, `literal-pad`,
`whitespace-only`); 6 procedural images (original solid RGB, nonsquare checker,
EXIF rotation 6 and mirror 2, plus `lowres-68x120` at 68×120 and
`lowres-112-portrait` at 112×199). This yields 23 cases, 92 stage comparisons
and a 17×6 paired matrix (102 entries). These are numerical/conversion fixtures,
not retrieval-quality tests or evidence of real PhotoKit image quality.

### Environment, source provenance and handoff

FP32 first and only in this scope: macOS 14+ native Apple Silicon, CPython 3.11,
coremltools 8.3.0, torch 2.5.1, transformers 4.48.3, tokenizers 0.21.0,
NumPy 1.26.4, Pillow 11.1.0, huggingface-hub 0.28.1, safetensors 0.5.2,
protobuf 4.25.6. No SentenceTransformer or sentencepiece dependency; the fast
JSON path does not convert tokenizer.model. Protobuf is pinned for Core ML.
Use eager attention, strict checked TorchScript tracing, FP32 ML Programs,
iOS 17 minimum target and CPU_ONLY prediction after save/reload. There is no
FP16, quantization or export-only parity bypass in this change.

Default export is cache-only. `--download` permits only the exact pinned public
revision with `token=False`, no implicit credentials, telemetry disabled and
`trust_remote_code=False` on local loaders. One snapshot download invocation,
one shared weight load and one streaming hash of each source file, not two
per-role downloads/hashes. No private photos, databases, GPS, or other private
assets are accepted or searched for.

`provenance.json` schema 2 retains `createdUTC`, `environment`, `sources`,
`validatedConfigs`, `implementationContractSHA256`, `exportSourceSHA256`,
`precision`, `computeUnits`, `attentionImplementation`, `training:false`,
`inputs`, `redistributionApproved:false`, and the shared schema/model version.
`sources` has ONE `shared` record with `id`, `revision`, `roles:["image","text"]`,
`sha256`, `licenseEvidence`, `modelCardDeclaredLicense`, `licenseStatus`,
`redistributionApproved:false`. Copy actual model-card/LICENSE/NOTICE evidence
under `licenses/shared/`; do not invent missing license files. The public model
card declares Apache-2.0; `licenses/review-required.json` preserves the manual
license-review requirement rather than treating numerical parity as permission.

There are 30 stdlib-only static test methods covering this contract, metadata
drift, Unicode/token boundaries, resource ownership, public single-snapshot
provenance and immutable gates. Writing those tests does not mean they ran.
macOS export and native adaptation are separate pending gates. Swift, native
tokenizer/preprocessor, manifest consumers, generated parity tests, resource
packaging, checkers and workflow are outside this seven-file change. They must
be coordinated to schema 2 and both required tokenizer JSONs; unchanged
schema-1/WordPiece consumers are incompatible, not evidence that export passed.
Changing the semantic modelVersion requires rebuilding old image AND text/place
vectors; old and new embeddings must never share an index.

## Shared Swift core API (ImageIQCore, Foundation only)

Swift tools 5.9, iOS 17 / macOS 14; no fetched Swift dependencies.

- `EmbeddingMath.normalized(_ vector: [Float]) throws -> [Float]`
- `EmbeddingMath.dot(_ lhs: [Float], _ rhs: [Float]) throws -> Float`
- `PlaceEmbedding(text: String, vector: [Float])` (Codable, Sendable)
- `IndexedPhoto(id: String, modificationTime: Double, modelVersion: String,
  imageEmbedding: [Float], location: PlaceEmbedding? = nil,
  creationTime: Double? = nil)` (Codable, Sendable, Identifiable).
  Modification time is seconds since Unix epoch, not a display label.
- `SearchHit(photo: IndexedPhoto, score: Float)` (Sendable, Identifiable).
- `VectorSearch.search(query: [Float], photos: [IndexedPhoto], limit: Int,
  locationWeight: Float) throws -> [SearchHit]`
  Exact dot products; distinct-place mean scoped to supplied records. Formula
  `(1-w)I + w(L-mu)`, no final normalization; missing place residual=0;
  inclusive 0...1. Duplicate equal scores sorted by asset identifier.
- Native tokenizer adaptation must consume both Gemma JSON resources and the
  lowercase/EOS/PAD contract above. Retain `TokenizedText` fields
  `inputIDs: [Int32]`, `attentionMask: [Int32]` for checking, but feed only IDs
  to Core ML. The old WordPiece API is not the schema-2 tokenizer. No arbitrary
  query-byte ceiling; no claim of implemented Swift parity in this exporter change.

## Storage, privacy and validation

Photo identifiers are scoped by current PhotoKit authorization: remove inaccessible
or deleted photos before presenting search results. An interrupted refresh must
not destructively prune records using a partial enumeration. Image modifications
invalidate vectors. Local cache is excluded from device backups and deleted by
an explicit UI action; never index application demo pictures automatically.

Test fixtures are synthetic/public test patterns, never personal images, GPS,
desktop database or video assets. CI is workflow_dispatch only. Model-free CI
checks compilation/tests, **not** semantic-search readiness. Model-enabled CI
must compare exported Core ML predictions with the pinned PyTorch pair, test
Swift tokenizer/preprocessing fixtures, and report the distinction.