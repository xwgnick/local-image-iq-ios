# ImageIQCore

Foundation-only Swift package: tools 5.9, iOS 17 / macOS 14, no external package
dependencies. Implements the shared API in the
[implementation contract](../../docs/IMPLEMENTATION_CONTRACT.md).

## API and files

- [Package.swift](Package.swift): library and XCTest targets.
- [Models.swift](Sources/ImageIQCore/Models.swift): public initializers with the
  contract's exact argument names/order/defaults for `PlaceEmbedding`,
  `IndexedPhoto`, and `SearchHit`; `TokenizedText.inputIDs` and `attentionMask`
  are `[Int32]`. All four value types are `Codable` and `Sendable`.
  `IndexedPhoto` and `SearchHit` are `Identifiable`; a hit's ID is its photo ID.
- [EmbeddingMath.swift](Sources/ImageIQCore/EmbeddingMath.swift):
  `EmbeddingMath.normalized(_:) throws -> [Float]` and
  `EmbeddingMath.dot(_:_:) throws -> Float`.
- [VectorSearch.swift](Sources/ImageIQCore/VectorSearch.swift):
  `VectorSearch.search(query:photos:limit:locationWeight:) throws -> [SearchHit]`.
- [WordPieceTokenizer.swift](Sources/ImageIQCore/WordPieceTokenizer.swift):
  `WordPieceTokenizer(vocabulary:sequenceLength:) throws`, default length 128,
  and `encode(_:) -> TokenizedText`.

## Numeric and search semantics

- Normalize each raw encoder output once, before storage or retrieval. Search
  and dot products do not silently normalize inputs. Production outputs are
  512-dimensional; these numerical routines accept any nonempty matching
  dimension, including the synthetic 1D/2D test inputs.
- Normalization and inner-product accumulation use `Double` internally and
  return `Float`. This avoids intermediate Float overflow/underflow. Empty
  vectors, nonfinite components, mismatched dimensions, and unrepresentable
  Float results throw `EmbeddingError`; normalizing a zero vector also throws.
  Dot/search allow finite zero vectors without attempting to normalize them.
- Score is `q · ((1-w)I + w(L-mu))`. Missing locations use residual zero, not
  `-mu`. There is no normalization of the center, residual, or final vector.
  At weight zero this is the image dot product; at weight one it is place-only
  and unknown locations score zero (which can beat a negative residual).
- Distinct places are keyed by exact UTF-8 text, not photo frequency, vector
  equality alone, case folding, or canonical Unicode equivalence. Equal text
  must have componentwise-equal stored vectors; conflicting vectors throw
  `VectorSearchError.inconsistentPlaceVector`. Both signed zeros compare equal.
  Search does not add a tolerance that could hide stale/mixed place embeddings.
- The center includes all and only supplied records, independently of `limit`.
  By linearity, search computes `q·mu` as the mean of the unique place dot
  products; it never materializes a fused image matrix. Place accumulation is
  sorted by UTF-8 text. Float32/BLAS references may differ by rounding and need
  a measured tolerance; no bitwise cross-backend parity is claimed.
- A worst-first heap keeps at most `min(limit, photos.count)` candidates. Extra
  storage is proportional to distinct place texts plus retained candidates,
  not the full photo embedding matrix. All supplied vectors are validated,
  including at weight endpoints and at limit zero.
- Weights must be finite in inclusive `0...1`; negative limits throw. Limit
  zero returns no hits; larger limits are naturally clamped to the photo count.
  Equal Float scores use ascending UTF-8 photo ID, independent of locale. An
  identical-ID tie retains input order; search does not discard duplicate IDs.
- The caller supplies the currently authorized library/root subset and is
  responsible for model-version compatibility. No filesystem/root traversal,
  authorization inference, metadata mutation, persistent cache, or network I/O
  occurs in this package.

## Tokenizer semantics and pending parity checks

- Vocabulary line order defines IDs; no special-token IDs are hardcoded.
  `[CLS]`, `[SEP]`, `[PAD]`, `[UNK]` are required. `[MASK]` is recognized as a
  standard BERT added token when present. Duplicate byte-identical entries are
  rejected; canonically equivalent but differently encoded entries stay distinct.
- Default encoding is `[CLS]`, up to 126 payload tokens, `[SEP]`, then `[PAD]`
  to 128. The mask attends all actual tokens, including a literal `[PAD]`, and
  is zero only on generated padding. The shared initializer's explicit length
  override is supported for lengths at least two; production must use 128 to
  match the contracted model. There is no separate query-byte/row ceiling.
- Cased fast BERT behavior: remove null, replacement scalar U+FFFD, and Unicode
  categories Cc/Cf/Co, except tab/LF/CR; treat whitespace as boundaries;
  split the legacy BERT CJK ranges and Unicode punctuation, including ASCII
  punctuation/symbol ranges. Unassigned Cn scalars are retained, unlike Python
  slow BERT's broader category-C cleanup. No lowercasing, accent stripping, NFC,
  or NFD.
- All segmentation and word length accounting uses Unicode scalars, not Swift
  `Character` grapheme clusters, UTF-8 bytes, or UTF-16 code units. Greedy
  WordPiece uses `##` after the first piece, never backtracks, and returns one
  `[UNK]` for an unsegmentable word or a pre-tokenized word over 100 scalars.
  The 100-scalar threshold is WordPiece's `max_input_chars_per_word` convention,
  not an application pipeline limit. Tokens are streamed; long words do not
  require storing more than 100 scalars while looking for their boundary.
- Standard literal specials are matched before cleanup, case-sensitively,
  without word-boundary or whitespace-stripping requirements. They survive
  adjacency to ordinary/combining text, count toward payload truncation, and
  do not suppress the outer `[CLS]`/`[SEP]`. A control inserted inside a special
  spelling does not manufacture an added-token match after cleanup.

Potential Unicode/reference differences that still require the parent export:

1. Swift runtime Unicode categories and the pinned Python/Rust tokenizer's
  Unicode tables can differ for newly assigned scalars. Category-based cleanup,
   whitespace and punctuation therefore need cross-runtime reference cases.
2. HF fast `BertNormalizer` and Python slow `BasicTokenizer` are not guaranteed
  interchangeable, particularly for unassigned Cn scalars, NFC handling and
  Unicode table versions.
   This implementation deliberately does not normalize canonical equivalents.
3. Emoji ZWJ is a format character and is removed; variation selectors and
   combining marks remain. Supplementary CJK uses BERT's explicit ranges, not
   every newer Han extension. These are intentional rules, not a claim that
   all user-perceived characters become individual tokens.
4. The API receives only vocabulary and sequence length, not arbitrary added-
   token configuration. Parent export must confirm the five standard spellings
   and their `normalized=false`, `single_word=false`, `lstrip=false`, and
   `rstrip=false` behavior. Extra/custom added tokens are not inferred.
5. Invalid UTF-8/UTF-16 decoding is outside this String-based API. Test fixture
   loading must preserve original scalar sequences and must not NFC-normalize
   strings or rewrite vocabulary lines.

Parent reference fixtures should preserve the exact input text (preferably also
its code points), expected 128 Int32 IDs and mask, exact vocabulary ordering and
provenance, pinned model revision, tokenizer class/fast-versus-slow setting,
library versions, normalizer settings, added-token flags, and truncation/padding
options. No model vocabulary or purported verified HF fixtures were fabricated.
The synthetic tests below are not a substitute for those fixture comparisons.

## Test inventory and validation status

79 XCTest test methods, all synthetic and model-free:

| Test file | Methods | Coverage |
| --- | ---: | --- |
| [ModelsTests.swift](Tests/ImageIQCoreTests/ModelsTests.swift) | 5 | Codable fields/defaults, Unix timestamps, hit identity, Sendable type constraints |
| [EmbeddingMathTests.swift](Tests/ImageIQCoreTests/EmbeddingMathTests.swift) | 12 | 1D/2D/512D, norms, signs, zero/empty/shape/nonfinite errors, huge/subnormal values, dot overflow/cancellation |
| [VectorSearchTests.swift](Tests/ImageIQCoreTests/VectorSearchTests.swift) | 26 | Weights 0/1/nextDown(1), oblique query, negative/unknown scores, no renormalization, text deduplication/conflicts, root scope, relative ranking, ID ties, top-K reference, validation |
| [WordPieceTokenizerTests.swift](Tests/ImageIQCoreTests/WordPieceTokenizerTests.swift) | 36 | Casing, greedy/failed suffixes, Chinese, accents, canonical distinctions, punctuation, emoji, null/control/unassigned/combining text, literal specials, 100-scalar boundary, 126/128 truncation/padding |

The heap test contains 324 comparisons against an independent exhaustive
reference: 4 weights × 3 input orders × 9 requested limits. This is still one
XCTest method, not 324 separately executed tests.

Authored and statically reviewed on Windows. No Swift toolchain was invoked;
no compilation, XCTest run, native numerical parity measurement, or HF fixture
comparison has been performed. Editor diagnostics are not compilation evidence.
The package contains no personal photos, GPS, desktop database data, model
weights, network dependencies, or test-time downloads.