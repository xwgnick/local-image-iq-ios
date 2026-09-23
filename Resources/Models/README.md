# Pinned SigLIP 2 Core ML models — schema 2

**SigLIP 2 export and native validation are pending.** This source/configuration
update does not run conversion, tests, builds or device packaging. Historical
CLIP results in [build evidence](../../docs/BUILD_STATUS.md) do not establish
SigLIP 2 parity. Generated models, tokenizer data and fixtures are excluded from
source control; their presence alone is not a validation result.

The authoritative fields are defined by `base_manifest()` in
[model_contract.py](../../scripts/model_contract.py) and the emitted records in
[export_models.py](../../scripts/export_models.py). See also the shared
[implementation contract](../../docs/IMPLEMENTATION_CONTRACT.md).

## Exact encoder contract

| Component | Pinned source / interface |
| --- | --- |
| Both encoders | `google/siglip2-base-patch16-224` |
| Shared revision | `75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2` |
| Image input | `pixel_values`, Float32, `[1,3,224,224]` |
| Text input (IDs only) | `input_ids`, Int32, `[1,64]` |
| Both outputs | `output_embedding`, Float32, raw `[1,768]` |

One built-in Transformers `SiglipModel` supplies both towers. This is the fixed
224/patch-16 model, not NaFlex. The image wrapper preserves the complete learned
vision attention pooling head; the text wrapper preserves the learned text head
and pools the final sequence position (index 63, potentially PAD), not the last
nonpadding token or EOS. Both return raw `pooler_output`. There is no mean pooling,
replacement projection, output L2 normalization, sigmoid, logit scale or logit
bias in either encoder. Swift L2-normalizes each encoder output once.

Image preprocessing applies EXIF orientation, converts to RGB, then **warps the
entire image directly to 224×224** using Pillow 11.1.0 BILINEAR (`resample=2`).
It neither preserves aspect ratio nor center-crops. Divide by 255, normalize
with mean and std both `[0.5,0.5,0.5]`, and lay out NCHW Float32. These pixel
operations are outside the Core ML graph. Native CoreGraphics interpolation
must be validated separately; Python/HF agreement does not establish native parity.

Text uses explicit Python `str.lower()` followed by the pinned
`GemmaTokenizerFast` BPE/byte-fallback tokenizer. The runtime requires both
`tokenizer.json` and `tokenizer_config.json`, copied byte-for-byte from the same
checkpoint. Preserve the JSON normalizer and added tokens; do not substitute
WordPiece, casefolding, trimming, accent stripping or manual Chinese splitting.
Take at most 63 content tokens, append EOS id 1, then right-pad with PAD id 0 to
64. No automatic BOS is added; literal BOS id 2, UNK id 3 and other added tokens
remain valid content. Empty text produces `[1,0,...,0]`.

Fixture `attentionMask` remains a 64-element exact-tokenization check, **never a
model input**. A literal content PAD has mask 1, so masks cannot be inferred from
nonzero IDs. The wrapper converts public Int32 IDs to `torch.long` internally.
Swift lowercasing/tokenization still needs exact multilingual fixture comparison,
particularly contextual Greek sigma, Turkish dotted I and combining marks.

## Export environment and validation boundaries

Export requires native Apple Silicon macOS 14+ and CPython 3.11, with the versions
in [requirements-coreml.txt](../../scripts/requirements-coreml.txt): CoreMLTools
8.3.0, Torch 2.5.1, Transformers 4.48.3, NumPy 1.26.4, Pillow 11.1.0, HF Hub 0.28.1,
tokenizers 0.21.0, safetensors 0.5.2 and protobuf 4.25.6. No SentenceTransformers
or sentencepiece package is required; the fast JSON path does not convert a slow
SentencePiece model. Windows/Linux cannot execute the required Core ML parity.

Default export is cache-only. Explicit `--download` permits the one pinned public
snapshot without a token or remote code, not two per-role downloads. Existing
offline environment flags are not silently cleared. Export loads the shared
weights once and hashes each selected source file once using streaming reads.
Inputs are procedural patterns and fixed synthetic queries, never private photos,
GPS, databases or credentials. This documentation does not authorize execution.

Before publishing an export, the exporter must:

1. Validate the shared contract, snapshot configs and resolved architecture,
   including Siglip pooling heads, vocabulary size 256000, tokenizer policy,
   warp geometry and normalization. Reject checkpoint-loading mismatches.
2. Load the shared model on CPU in eval/FP32 with eager attention. Reject fused
   attention modules/trace operations. The reference is independent
   `get_image_features()` / `get_text_features()`, which return raw Tensors in
   pinned Transformers 4.48.3, not normalized paired-forward embeddings.
3. Reload the two copied tokenizer JSONs from staging and compare all IDs/masks
   with the source tokenizer. Trace fixed batch-one inputs with additional
   image/text checks. Convert FP32 iOS 17 ML Programs and validate fixed feature
   names, shapes and dtypes.
4. Save/reload both packages and predict every generated case using `CPU_ONLY`.
   Compare `referenceVsWrapper`, `wrapperVsTrace`, `traceVsCoreML` and
   `referenceVsCoreML`, then compare the complete text/image cosine matrices.
5. Write provenance, fixtures and the passing report, hash all staged artifacts,
   and publish the manifest last as the completion marker.

| Numerical gate | Default acceptance |
| --- | --- |
| Every raw-vector comparison | cosine strictly `> 0.999` |
| Reference vs wrapper; wrapper vs trace | max abs `<= 1e-5` |
| Trace/reference vs saved Core ML | max abs `<= 1e-3` |
| Reference vs Core ML paired cosine matrix | max abs `<= 1e-4` |
| Independent Pillow/NumPy vs HF input tensor | max abs `<= 1e-6` |

CLI overrides may tighten, never weaken these gates. They are declared numerical
tolerances, not measured results or production limits. Raw-vector absolute error
also checks magnitude, which cosine alone cannot do. FP16/quantization/ANE-specific
optimization is not validated by this FP32 export.

[check_project.mjs](../../scripts/check_project.mjs) preserves read-only source
layout, Foundation-core API markers and Photos plist checks. Model-enabled mode
also checks schema 2, pinned identities, preprocessing, artifact SHA-256, shared
source tokenizer hashes, fixture shapes/IDs/masks, case coverage and recorded
numerical gates. These are **lexical/resource checks, not Swift compilation,
complete XML parsing or a rerun of model predictions**. Native tests, Xcode bundle
membership and device behavior remain separate gates. A model-free build is not
semantic-search readiness.

## Resource ownership and device packaging

The app's default `Resources/Models` source entry in
[project.yml](../../project.yml) collects the production resources:

- `ImageEncoder.mlpackage` and `TextEncoder.mlpackage` (Xcode compiles to `.mlmodelc`).
- `model-manifest.json`.
- `tokenizer.json` and `tokenizer_config.json`, together in one runtime directory.

[project.models.yml](../../project.models.yml) adds only generated test resources
to `LocalImageIQTests`: `tokenizer-parity.json`, `image-preprocess-parity.json`,
`parity-report.json`, `provenance.json`, and the `fixtures` folder reference.
These are excluded from the production app's folder sources, as are license
evidence and this README. Do not duplicate runtime resources in the model-enabled
variant or rely on a test bundle to supply missing production tokenizer files.
The exporter no longer produces `vocab.txt` and removes that retired owned output
on a successful publish. It leaves this README and optional geography untouched.

[package_device.mjs](../../scripts/package_device.mjs) requires the pinned schema-2
768D manifest, IDs-only text interface, both compiled encoders and both tokenizer
JSONs with matching manifest hashes in the same directory. Existing physical
iOS/arm64 Mach-O checks and unsigned/no-provisioning/no-test-bundle checks remain.
An unsigned IPA still needs local signing; packaging does not prove native parity,
installability without re-signing, physical-device quality or performance.

At rerun start the old manifest is invalidated. Export writes to a temporary
sibling directory, replaces only owned resources on success and renames the new
manifest last. Old packages without a valid manifest are stale, not a fallback.
Do not run concurrent exports/builds against the same output directory. Ignore
rules cover generated model/tokenizer/weight resources and staging directories,
not script source or source-controlled test fixtures.

## Manifest, provenance and licenses

Manifest fields are `schemaVersion:2`, `dimension:768`, `sequenceLength:64`,
`imageSize:224`, the identical `imageModel`/`textModel` source objects,
`imageInput:"pixel_values"`, `textInputs:["input_ids"]`,
`output:"output_embedding"`, `tokenizerFile:"tokenizer.json"`,
`tokenizerConfigFile:"tokenizer_config.json"`, `features` and `preprocessing`.
`modelVersion` is `siglip2-b16-224-v1-` plus 64 lowercase SHA-256 characters of
canonical JSON containing `imageModel`, `textModel`, `features`, `preprocessing`.
Timestamps, paths and reports are not part of that semantic identity. The model
change requires rebuilding image and text/place vectors; do not mix old 512D
embeddings with new 768D embeddings in an index.

Successful export additionally records `parity.status:"passed"` for Python
conversion only, its report/precision/compute units, `provenance:"provenance.json"`,
`redistributionApproved:false` and `artifactsSHA256`. The manifest does not hash
itself. Provenance schema 2 has one `sources.shared` record with the pinned
`id`, `revision`, `roles:["image","text"]`, source-file hashes and actual license
evidence. It also records checked configs, package/OS versions and contract/export
source hashes. `licenses/shared` holds copied evidence;
`licenses/review-required.json` keeps the manual review requirement explicit.

The public model card declares Apache-2.0; this is a declaration, not a completed
legal review. Missing evidence is not permission. Numerical parity does not
change `redistributionApproved:false`. Review checkpoint/tokenizer, upstream/data
obligations and dependency licenses before redistribution.

## Generated fixture schema and pending native handoff

Exporter-generated metadata/fixture reports use UTF-8, `schemaVersion:2` and the
same `modelVersion`; the two original tokenizer JSONs retain their upstream
format. Fixture roots carry `embeddingDimension:768`, `embeddingsAreRaw:true`,
`reference`, `nativeParity:"not-run"` and `cases`.

Tokenizer parity additionally records `sequenceLength:64`, `textModel`, both
tokenizer filenames, `tokenizerSHA256` and `configSHA256` (the latter hashes the
tokenizer config, not model config), `tokenizerClass`, `tokenizerOptions`,
`preprocessing` and `backendNormalizer`. Each case has `id`, `text`,
`lowercasedText`, 64 `inputIDs`, 64 `attentionMask` values, and 768-float
`referenceRaw` / `coreMLRaw`. There is no legacy vocabulary hash or
`sentenceTransformerRaw` alias. Compare every ID/mask, not merely decoded text.

Image parity additionally records `imageModel` and `preprocessing`. Each case
keeps relative image/tensor paths and hashes, source/oriented dimensions, EXIF
orientation, `resizedSize:[224,224]`, `cropXYWH:[0,0,224,224]`, full tensor size,
spot checks and both raw 768D outputs. The crop rectangle describes the full warp,
not a pixel-removal step. Each `.f32le` contains 602,112 bytes of little-endian
Float32 `[1,3,224,224]` NCHW; spot checks do not replace full-tensor comparison.

Current generated coverage is 17 synthetic queries and 6 procedural images:
solid RGB, a nonsquare checker, EXIF rotation/mirror, 68×120 and 112×199 low-resolution
patterns. The report has 23 cases, 92 stage comparisons and a 17×6 `pairedCosines`
matrix with `queryIDs`, `imageIDs`, `reference`, `coreML` and `maxAbs`.

The exporter leaves `nativeTokenizerParity`, `nativeImagePreprocessParity` and
`nativeModelRuntimeParity` as `not-run`, and `semanticRetrievalQuality` as
`not-evaluated`; manifest native statuses are also `not-run`. Exact native Unicode
tokenization, full native tensor geometry/pixels, same-input Core ML outputs and
the actual app encoder path must be checked separately using the updated native
tests. Historical CLIP tests cannot stand in for these SigLIP 2 gates. Synthetic
conversion parity does not prove PhotoKit availability, retrieval improvements,
physical-device latency or thermal behavior.

## Optional geography

No geography export or boundary pack is supplied by this change. Optional
`Places.geojson` remains independently sourced/licensed and is not a tokenizer or
model fixture. No online geocoder fallback or private photo/GPS input is added.