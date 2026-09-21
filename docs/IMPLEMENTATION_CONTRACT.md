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

## Pinned paired models

- Image: `sentence-transformers/clip-ViT-B-32`, revision
  `327ab6726d33c0e22f920c83f2ff9e4bd38ca37f`.
- Text: `sentence-transformers/clip-ViT-B-32-multilingual-v1`, revision
  `58edf8cada9e398793dca955574a48cbb7f18be2`.
- Image input `pixel_values`: Float32 `[1,3,224,224]`.
- Text inputs `input_ids`, `attention_mask`: Int32 `[1,128]`.
- Both outputs `output_embedding`: Float32 `[1,512]`, **raw projection**.
  Swift normalizes each encoder output exactly once before storage/retrieval.
- Image: oriented RGB, resize shortest side to 224 with bicubic interpolation,
  center crop 224 square, divide by 255, normalize NCHW with
  mean `[0.48145466,0.4578275,0.40821073]`,
  std `[0.26862954,0.26130258,0.27577711]`.
  Native interpolation parity must be measured, not assumed identical to Pillow.
- Text: cased WordPiece, no lowercasing or accent stripping, Chinese character
  splitting, `[CLS]` + truncated tokens + `[SEP]`, pad to 128. DistilBERT hidden
  state -> attention-mask mean -> bias-free identity dense 768→512.

Bundle resources (produced by an explicit macOS conversion step):
`ImageEncoder.mlpackage`, `TextEncoder.mlpackage`, `vocab.txt`,
`model-manifest.json`. Xcode compiles model packages to `.mlmodelc`.
Optional offline boundaries: `Places.geojson`; no online geocoder fallback.

Manifest minimum fields: `schemaVersion:1`, `modelVersion` (string),
`dimension:512`, `sequenceLength:128`, `imageSize:224`,
`imageModel` and `textModel` (objects with `id`, `revision`),
`imageInput:"pixel_values"`, `textInputs:["input_ids","attention_mask"]`,
`output:"output_embedding"`. Additional provenance/parity fields allowed.

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
- `WordPieceTokenizer(vocabulary: [String], sequenceLength: Int = 128) throws`;
  `encode(_ text: String) -> TokenizedText`, fields `inputIDs: [Int32]`,
  `attentionMask: [Int32]`. No arbitrary query-byte ceiling.

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