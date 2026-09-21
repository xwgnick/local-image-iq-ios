# Pinned paired Core ML models — explicit conversion only

No weights, model packages or generated fixtures are checked into Git. Models are
generated only by the explicitly requested macOS workflow and included in its
private build artifact. See [current build evidence](../../docs/BUILD_STATUS.md)
for conversion and native-test outcomes; source availability alone is not a pass.
The paired model interface is specified in the
[implementation contract](../../docs/IMPLEMENTATION_CONTRACT.md).

## Exact contract

| Component | Pinned source / interface |
| --- | --- |
| Image | `sentence-transformers/clip-ViT-B-32` @ `327ab6726d33c0e22f920c83f2ff9e4bd38ca37f` |
| Text | `sentence-transformers/clip-ViT-B-32-multilingual-v1` @ `58edf8cada9e398793dca955574a48cbb7f18be2` |
| Image input | `pixel_values`, Float32, `[1,3,224,224]` |
| Text inputs | `input_ids`, `attention_mask`, Int32, `[1,128]` each |
| Both outputs | `output_embedding`, Float32, raw `[1,512]` |

Image wrapper uses `image[0].model.vision_model` pooled output followed by
`image[0].model.visual_projection`. Text uses `text[0].auto_model` (DistilBERT),
attention-mask mean including CLS/SEP, then `text[2].linear` (768→512, no bias,
Identity activation). “Identity” describes the activation, NOT the learned
projection matrix. There is **no L2 normalization in either exported graph**.
Swift normalizes each output once before storage/retrieval.

Image preprocessing: apply EXIF orientation, RGB, bicubic shortest-side resize
to 224, center crop 224×224, `/255`, normalize NCHW with mean
`[0.48145466,0.4578275,0.40821073]` and standard deviation
`[0.26862954,0.26130258,0.27577711]`. The other resized dimension and center-crop
offsets use floor. No resize/normalization is embedded in the Core ML graph.
Pillow is the Python reference. Native interpolation is not assumed bit-identical;
the generated native tests separately measure tensor and embedding differences.

Text uses cased WordPiece, Chinese-character splitting, no lowercasing or accent
stripping, CLS + right-truncated tokens + SEP, right padding to 128. Public inputs
and converter types are Int32; the wrapper coerces to `torch.long` internally.
The original HF WordPiece per-word behavior is not an application query-length cap.

## Files and manual macOS workflow

- [export_models.py](../../scripts/export_models.py): explicit export, validation,
  measured parity and manifest-last publication.
- [encoder_wrappers.py](../../scripts/encoder_wrappers.py): raw image/text wrappers.
- [model_contract.py](../../scripts/model_contract.py): constants, metadata checks,
  deterministic identity and synthetic query definitions (stdlib only).
- [synthetic_fixtures.py](../../scripts/synthetic_fixtures.py): procedural RGB/EXIF patterns.
- [requirements-coreml.txt](../../scripts/requirements-coreml.txt): pinned environment.
- [test_static.py](../../scripts/test_static.py): stdlib AST/schema/version/publication smoke tests.
- [check_project.mjs](../../scripts/check_project.mjs): dependency-free, read-only Node checks.

Use **native Apple Silicon macOS 14+ and CPython 3.11**. PyTorch 2.5.1 does not
provide this environment for Intel macOS; do not run the interpreter under Rosetta.
Core ML predictions cannot be validated on Windows/Linux. The requested toolchain
is pinned to CoreMLTools 8.3.0, Torch 2.5.1, Transformers 4.48.3,
SentenceTransformers 3.4.1, NumPy 1.26.4 and Pillow 11.1.0, plus pinned HF hub,
tokenizers and safetensors versions. Exact installed versions are checked before
loading; actual validation outcomes are recorded in the build evidence above.

From the `local_image_iq_ios` directory, an explicitly invoked macOS workflow can
use the following steps. They are instructions only, not executed by this change:

```sh
python3.11 -m venv .venv-coreml
. .venv-coreml/bin/activate
python scripts/test_static.py
python -m pip install -r scripts/requirements-coreml.txt
python scripts/export_models.py --download
```

`--download` permits only the two public revision-pinned snapshots, without a
token or remote code. Without it, the exporter requires complete local HF cache
snapshots and sets offline mode. An existing `HF_HUB_OFFLINE=1` or
`TRANSFORMERS_OFFLINE=1` is not silently overridden by `--download`; use a fresh
manual job/environment for downloading. Public package/model network access is
only part of that later manual workflow. No photos, GPS, private database, browser
session, secret or training job is accepted or needed.

The workflow is `workflow_dispatch` only, in the intended private repository with
an Apple Silicon runner. It provides no signing/TestFlight path. A clean venv
avoids accidental torchvision or other unrelated environment interference.

The static source/resource checks can be invoked separately:

```sh
node scripts/check_project.mjs --self-test
node scripts/check_project.mjs
node scripts/check_project.mjs --models
```

Default App layout is `App/` and `App/Info.plist`; use `--app-dir` and `--plist`
if the final layout differs. The checker reads the Foundation core package,
Swift test presence, API source markers, Photos plist strings and optionally
generated schemas, hashes and recorded numerical gates. Its plist check is
**lexical, not a complete XML parser**; it cannot validate Swift signatures,
runtime behavior or bundle membership. Run `plutil -lint` on the actual plist,
`swift test` and an Xcode simulator build separately on macOS. A model-free build
is not semantic-search readiness. No fake Swift compilation claim is emitted.

## What must pass before publication

1. Check the shared contract text, exact snapshot revisions, complete module lists,
   CLIP processor configuration, DistilBERT width/length, all pooling modes, dense
   dimensions/bias/activation and tokenizer settings. Extra/unused modules fail;
   they are never silently dropped. Effective loaded configurations are checked too.
2. Load the real SentenceTransformer pair on CPU in eval/FP32 mode. ST's legacy
   CLIP loader may not forward attention kwargs, so its inner CLIP model is
   explicitly reloaded from the same pinned local weights with eager attention.
   Text also explicitly requests eager attention. Reject SDPA/Flash modules and
   fused-attention trace operations. Original `SentenceTransformer.encode` remains
   the pipeline reference, with `normalize_embeddings=False`.
3. Trace fixed batch-one inputs; check the trace using a second pattern and a
   long fully populated text mask. Convert to iOS 17 ML Programs with FP32 compute,
   Float32 outputs and `CPU_ONLY`. Validate feature names, tensor dtypes and shapes.
4. Save/reload both packages; predict every generated case with the reloaded models.
   Compare original ST→wrapper, wrapper→trace, trace→Core ML and original ST→Core ML.
   Measure raw-vector max absolute error, cosine and both vector norms. Check all
   synthetic query/image cross-cosines against the original paired pipeline.
5. Emit provenance, fixture JSON and the passing report; hash every published
   artifact; only then publish `model-manifest.json` as the completion marker.

Default measured gates (all parameters are recorded in the report):

| Gate | Default |
| --- | --- |
| Each raw-vector cosine | strictly `> 0.999`, `--min-cosine` can tighten it |
| Original ST vs wrapper; wrapper vs trace | max abs `<= 1e-5`, `--torch-max-abs` |
| Trace/original ST vs Core ML | max abs `<= 1e-3`, `--conversion-max-abs` |
| Original vs converted text/image cosine matrix | max abs `<= 1e-4`, `--similarity-max-abs` |
| Independent PIL/NumPy vs HF input tensor | max abs `<= 1e-6`, `--preprocess-max-abs` |

These are declared numerical acceptance tolerances, not measured outcomes or
production limits on users/photos/query bytes. FP32 reordering can cause small
roundoff; the absolute-error gate additionally detects magnitude errors that
cosine alone misses (such as accidental normalization). Do not widen a failing
gate just to pass: inspect the recorded comparison and underlying cause first.
FP16/ANE optimization is deliberately deferred; it needs a separate measured
gate and semantic model-version change, never a silently substituted package.

## Publication, identity, provenance and licenses

Generated resources are `ImageEncoder.mlpackage`, `TextEncoder.mlpackage`,
`vocab.txt`, `model-manifest.json`, `provenance.json`, `parity-report.json`,
`tokenizer-parity.json`, `image-preprocess-parity.json`, `fixtures/` and `licenses/`.
Xcode must compile the two packages to `.mlmodelc`; configure the parent app target
to include the vocabulary and manifest. Fixture copies may be test-only to avoid
shipping them in the app. This exporter does not modify project/test-target files.

At the start of a rerun the previous manifest is removed. New data is produced in
a temporary sibling directory on the same filesystem. On success only the listed
exporter-owned resources are replaced, with the manifest renamed last. README and
optional geography remain untouched. Failure/interruption before commit leaves
no valid manifest; leftover old packages are not a successful rerun. Do not run
multiple exporters/builds concurrently against the same output directory.

Minimum schema is exactly `schemaVersion:1`, `modelVersion`, `dimension:512`,
`sequenceLength:128`, `imageSize:224`, `imageModel:{id,revision}`,
`textModel:{id,revision}`, `imageInput:"pixel_values"`,
`textInputs:["input_ids","attention_mask"]`, `output:"output_embedding"`.
`modelVersion` is `clip-pair-v1-` plus SHA-256 of canonical JSON containing the
two source IDs/revisions, feature contracts and preprocessing/projection/precision
contract. It excludes timestamps, machine paths and report hashes. Rewording the
Markdown does not itself change it; changing model/preprocessing semantics must.

Additional fields record features, preprocessing, Python parity status and artifact
SHA-256. Provenance records source config/weight hashes, export-source/contract
hashes, actual package/OS versions and copied public model-card/license evidence.
Hashing reads weights only during the explicitly invoked export, in streaming
chunks. No source paths or credentials are written to provenance.

Model-card license declarations are recorded verbatim as declarations, not verified
legal conclusions. A missing LICENSE is recorded as missing evidence, never filled
in with an invented permission. `redistributionApproved:false` remains set even
after numerical parity passes. Review both model sources, upstream/data obligations
and dependency licenses before any redistribution. Do not publish unknown-license
weights or assume a private build gives redistribution rights.

## Generated fixture schema and native test handoff

All JSON uses UTF-8, `schemaVersion:1` and the same `modelVersion`. Files are emitted
under this Models directory only when export passes; nothing is written into a
Package's Tests directory. Parent tests may copy/link these generated resources.

**Tokenizer JSON**: top-level `sequenceLength:128`, `embeddingDimension:512`,
`embeddingsAreRaw:true`, vocabulary SHA-256 and `cases`. Each case has `id`, `text`,
`inputIDs` and `attentionMask` (both exactly 128 integers), plus
`sentenceTransformerRaw` and `coreMLRaw` (each 512 floats). English, Chinese, case,
precomposed diacritics, combining marks, punctuation, literal special tokens, empty
text, controls/whitespace, supplementary Unicode, long words and truncation are
covered. The original ST HF fast tokenizer is authoritative; its fixed padding is
checked against ST's own tokenization. The effective tokenizer class and backend
normalizer are recorded. A different slow tokenizer is not substituted or imposed
as an extra gate on Unicode behavior. Swift must
compare **every ID and mask element**, preserving literal special-token behavior;
do not merely compare decoded text. No Unicode normalization should be added.

**Image JSON**: top-level `embeddingDimension:512`, `embeddingsAreRaw:true`,
preprocessing metadata and `cases`. Four procedural RGB PNGs cover a solid color,
non-square checkerboard, EXIF rotation 6 and EXIF mirror 2 (no GPS/other photo EXIF).
Each case records relative image/tensor paths and SHA-256, source/oriented/resized
dimensions, orientation, crop rectangle, full-tensor byte count, spot checks and
both raw 512-float outputs. Each `.f32le` is 602,112 bytes: 150,528 little-endian
Float32 values in contiguous `[1,3,224,224]` NCHW order. Index is
`channel * 224 * 224 + y * 224 + x`. Four tensors total about 2.30 MiB.

`spotChecks` are small readable diagnostics, **not a substitute for full-tensor
comparison**. On simulator, read the source PNG via the app's real image path,
honor EXIF, check orientation/geometry, compare the full native input tensor with
the reference, then feed the same tensor to the compiled models and measure raw
output parity. Decode little-endian bytes without assuming Data pointer alignment.
Pillow-vs-HF agreement does not prove CoreGraphics/ImageIO-vs-Pillow agreement.
Native interpolation tolerances must be measured and documented separately; do
not reuse the Python preprocessing gate as an unsupported native claim.

`parity-report.json` includes per-stage numerical comparisons and `pairedCosines`
with query IDs, image IDs, original matrix, converted matrix and maximum error.
It explicitly records native tokenizer, native preprocessing and native model
runtime gates as `not-run`. Synthetic parity does not establish retrieval quality,
physical-device latency, heat or limited-Photos/iCloud behavior.

## Optional geography

No geography exporter or `Places.geojson` is supplied in this scoped change.
Later conversion should accept an explicitly selected public boundary folder and
its source/license manifest, preserve verified ADM1/ADM2 and CHN/NLD/FRA/DEU labels,
and validate parent relationships spatially before composing hierarchical labels.
Do not fabricate parents from filenames or assume `shapeName` contains a province.
No GPS/photo database input or online geocoder fallback is needed or permitted.