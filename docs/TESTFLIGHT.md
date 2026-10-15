# TestFlight: signed builds and FP16 experiment

Approved identity: `app.piankexun.ios`, marketing version `1.0`.
Delivered builds: FP32 baseline `46` and FP16 experiment `47`.
The existing unsigned `0.16.5/45` development delivery is unchanged.

## Interactive startup: build 48 (delivery pending)

The user approved a new TestFlight `1.0 (48)` with the interactive-startup
changes: show home immediately, automatically request initially undetermined
Photos access, respect denial/limited access, and prepare Core ML models with
the asynchronous loading API. Search and indexing still require model readiness.
Build 47 remains delivered and must not be uploaded again.

Build 48 keeps build47's pinned FP16 model identity and
`fp16-real-photo-experiment-v2` acceptance, including full native App/UI tests,
all 48 approved real-photo queries on CPU/all compute units, and the 900 MiB
signed IPA ceiling. It does not intentionally change model/index identity from
47, so this startup-only update does not itself require rebuilding embeddings.
The earlier FP32-to-FP16 reindex requirement still applies when upgrading from 46.

Pre-delivery native evidence: run `38678725925` compiled the startup changes
and passed the first-launch Photos/denial/navigation UI test and keyboard tests
(one existing model-only skip). After correcting a test expectation lifecycle,
run `38680220532` passed all 19 launch-state tests with no failures or skips.
These checks do not establish real-device responsiveness during model loading.
Signing, upload and Apple `VALID` processing for 48 are still pending.
No public release, external beta review or tester invitation is requested.

## FP16 experiment: build 47

The completed manual workflow delivered `app.piankexun.ios`, `1.0 (47)`, with the
same pinned source model converted using Core ML `FLOAT16`. Build 46 remains
the delivered FP32 baseline, not an upload target. FP32 remains the default
export for all other workflows; only TestFlight explicitly requests
`--precision float16`.

Precision is part of the semantic model-version hash. FP16 cannot reuse FP32
image/place embeddings or search/grouping caches: existing version checks
exclude old embeddings, and indexing must regenerate them for this model.
Installing build 47 updates the same app; it is not a side-by-side app.
Switching back to build 46 also requires embeddings for its model version.
Do not uninstall the app or clear its data just to change builds.

FP16 keeps the Float32 image/output and Int32 token interfaces. The delivered
build uses the explicitly approved `fp16-real-photo-experiment-v2` policy,
described below and in [the shared contract](IMPLEMENTATION_CONTRACT.md).
The earlier `fp16-normalized-experiment-v1` scalar policy and its failures are
historical. Native cross-platform numerical differences remain diagnostics,
not numerical-parity claims. Production search normalizes the vectors.
FP32, macOS export integrity, Torch wrapper/trace, exact tokenizer and native
preprocessing/output-validity gates remain unchanged.

FP16 must pass full native model/App/UI gates and reproduce or improve every
approved real-photo query outcome on both CPU and all compute units.
Failure stops delivery, not a silent FP32 fallback or automatic threshold
adjustment. The signed exported IPA must actually be at most
900 MiB before any Apple package validation/upload. The delivery report records
precision, model version, bytes, SHA-256 and the build46 byte baseline.

### Confirmed build47 delivery

Run [`38625232929`](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38625232929),
source `18dcc907a24d969cbcbd4e66186721a2eee6d317`, job `116062586593`,
completed signing, archive/export verification, Apple validation, one upload
and Apple processing with state **`VALID`**.

- Core: 79 tests, zero failures.
- Targeted OCR/location switch persistence: 2 tests, zero failures, no skips.
- Full App suite: 2151 tests, zero failures, 1 existing skip.
- Full UI suite: 23 tests, zero failures, 1 existing skip.
- All 48 real-photo queries reproduced the approved per-query acceptance on
  each compute configuration; no additional query regression was accepted.
- Signed IPA: **723,337,143 bytes** (723.34 MB / 689.83 MiB), below 900 MiB.
  Build46 was 1,422,924,391 bytes: the signed IPA is **49.17% smaller**.
  These are exported IPA bytes, not Apple's thinned download or installed size.
- IPA SHA-256:
  `c4f5552648e605eff37bd381c5fccc25c384b51b848a52b88b0c782bf56e0aef`.
- Apple app ID: `6822662787`; build ID:
  `bc72e6f1-c178-4777-8394-984a713568ed`.

Delivery artifact `11930101239` was downloaded and ZIP SHA-256 verified as
`4007247a22a401c38bed3d87d54f2216fc4d0065abeabfed61ccfa43e64cdc27`.
Current real-photo evidence artifact `11929851992` was independently downloaded
and ZIP SHA-256 verified as
`c3f3d77d7a33e6d529722ffcdf17ecd1dd2ee1675b20bb8ed2a875de09e0f7a3`.
Its native JSON SHA-256,
`e5885e05b7a1da07d453c1cb63b88a6d8a541ac6254f2d884c531b44ceaa56b8`,
matches the delivery report. The downloaded current report passed the same
per-query validator locally, and corpus metadata SHA-256 matched the pinned
approval. Artifacts contain public metadata and measurements, not photos,
model bundles, signing material or the IPA.

Upload/Apple processing does not automatically add build47 to an internal
test group or invite testers. If TestFlight still shows only build46, select
build47 in the existing internal group's Builds page and resolve any
build-specific export-compliance prompt. No App Review, external beta review
or public App Store release was submitted. Upgrade without uninstalling;
the changed model version requires regenerating photo embeddings. Real-device
search quality, indexing speed, memory, heat and cleanup grouping still need
the user's trial; successful delivery is not proof of semantic equivalence.

### Historical validation attempts

The following failures/pending statements describe their individual earlier
attempts, not the current delivery status above.

Initial run `38589052732`, source
`ad0a7cdc1107808f15506941013be056631199a2`, stopped at the first FP16
conversion numerical gate. The `image/solid-rgb/traceVsCoreML` comparison
measured maximum raw-component error `0.03011798858642578` versus the `0.001`
ceiling, with cosine `0.9999644498041236` (above the `0.999` floor).
This is not a full-corpus or real-photo quality result. No valid model manifest,
signed archive, IPA delivery or Apple upload was produced. Build 46 is unchanged.
Do not relax the limits merely to pass this sample; a different precision or
quality-acceptance strategy requires an explicit decision and further evidence.

The user approved completing diagnostics before deciding any FP16-specific
acceptance criteria. The separate `FP16 numerical and synthetic ranking
diagnostics` workflow has no signing/API Secrets, archive or upload path.
`--diagnostic-report` measures all fixtures against the unchanged limits,
records actual failures, paired cosine matrices, synthetic ranking changes
and uncompiled package sizes, and never publishes a model manifest. Successful
completion of this diagnostic workflow means measurements were collected, not
that FP16 passed acceptance or was delivered. Real-photo quality is still
outside the procedural fixture coverage.

Diagnostic run `38590381626`, source
`9d81b38a3e683ef31ced355a3b3ce2b41a474b5b`, completed all 23 fixtures
(6 image, 17 text). Its 32 static and 3 numerical-helper tests passed.
The measurements are:

| Measurement | Image | Text |
| --- | --- | --- |
| Maximum raw component error vs FP32 reference | 0.043406322598457336 | 0.070577621459960938 |
| Minimum vector cosine vs FP32 reference | 0.9997303931246716 | 0.99996642483864939 |
| Cases failing the unchanged 0.001 raw error limit | 6/6 | 17/17 |
| Cases failing the unchanged 0.999 cosine floor | 0/6 | 0/17 |
| Uncompiled FP16 package bytes | 184744518 | 564752123 |

Maximum paired text/image cosine score error was `0.0015915427430773788`,
above the unchanged `0.0001` limit. Across 17 queries against six procedural
images, top-1 and top-3 membership did not change. This is small synthetic
coverage, not evidence of unchanged real-photo rankings or cleanup clusters.
Combined uncompiled packages total `749496641` bytes; no IPA or actual App Store
download size was measured.

The report explicitly says `passed=false`, `diagnosticOnly=true`,
`modelsPublished=false`, model version
`siglip2-b16-224-v1-4db0c5989d73c0669fd1909e8e2d91502351b75390a9cee1a2bc0ba2ec3b6c62`.
Artifact `11906514421` was downloaded and its ZIP SHA-256 checked against
GitHub's digest:
`ded433da54203bcd4b714e53848b5e05ce8242297c16f34c59c4168ca64cd6a3`.
At this diagnostic point no acceptance thresholds had changed, no native FP16
tests or signed archive had run, and no build47 upload had occurred.

The user subsequently accepted the FP16-specific criteria listed above and
approved continuing to an experimental TestFlight build for device comparison.
This is an intentional precision-specific acceptance change, not a claim that
the original FP32 numerical gates passed. Delivery remains pending a new full
native and signing run. Real-photo quality and device performance remain
unverified.

Full native run `38591652520`, source
`1b3881fa2de171935894dc07d7be24f003355e06`, passed macOS export under the
explicitly approved FP16 policy but failed the iOS simulator gate. App ran
2146 tests (1 existing skip), with 409 failed assertions in six generated
image/pair parity cases; text CPU parity, exact tokenizer parity and solid
normalization passed. UI ran 23 tests with 1 existing skip and zero failures.
The lowest failed vector cosine was `0.984854658309532`; maximum paired score
error was `0.011170282959938049`, above the approved `0.002` ceiling.
Same-float-input image CPU parity also failed, so native preprocessing alone
does not explain the difference. CPU and all-compute paired checks each
reported 50 failed comparisons. This establishes a native runtime acceptance
failure, not a proven faulty operator or real-device result. No signed archive
or Apple upload occurred. Do not loosen the approved policy to ship it.

An alternative is to retain the known-good FP32 image encoder and use FP16
only for the large text encoder, whose native parity passed. It requires a
distinct per-role model identity and revalidation of paired scores and actual
IPA size. This alternative has not yet been approved or tested.

The user requested measuring the actual top-five ordering impact rather than
treating a score-error ceiling as proof of poor retrieval quality. No further
acceptance limit has been changed and no mixed-precision switch was approved.
The dedicated `fp16-native-ranking.yml` workflow exports both model pairs from
the pinned checkpoint; the baseline models are compiled into the test bundle
only through `project.fp16-diagnostic.yml`. The diagnostic compares native
FP32 against native FP16 (not just a Torch reference), on CPU and all compute
units using identical inputs. For every query it retains full scores/orders,
top-one changes, top-five overlap, exact top-five order changes, pair inversions
among shared top-five members, and baseline top-one/top-five-boundary score gaps.
The ranker has an independent synthetic regression test. Diagnostic completion
does not imply unchanged rankings or acceptance; data are retained as native
test attachments. Coverage remains only six procedural images and 17 queries,
not a representative real-photo library. No signing or upload is performed.

Native ranking run `38602055699`, source
`bbc5f92a0d6f54406988e5fa4180c83bb6cf4ab8`, executed both diagnostic tests:
2 passed, 0 skipped, 0 failures. The attached measurement completed all
17 queries on CPU and all compute units. Both configurations gave identical
scores and ranking results; these are repeated configurations, not 34
independent queries.

| Per-configuration result | Count |
| --- | --- |
| Top-one result unchanged | 15/17 |
| Top-five membership unchanged | 15/17 |
| Exact ordered top-five unchanged | 8/17 |
| Aggregate top-five overlap | 83/85 (97.65%) |
| Pair inversions among shared top-five members | 10 |

The top-one changes were `special-tokens` (baseline first/second score gap
about `0.002331`) and `turkish-unicode-chinese` (about `0.000046`).
Top-five membership changed for `english` and `case`: each retained four of
five baseline results, with baseline fifth/sixth gaps about `0.002608` and
`0.000638`. The remaining changed queries only reordered the same five images.
The `chinese` fixture's exact top-five order did not change. These are
tokenizer/Unicode stress queries against procedural patterns, not a realistic
semantic retrieval benchmark; none of these counts establishes relevant-photo
recall or user-perceived quality. Maximum native FP32/FP16 score delta was
`0.011170408664966767`.

Artifact `11914727178` was downloaded and ZIP digest verified as
`d4908e193d61ead5cda88c93868733fefb1383bb50282d910a9eb41a275abfb5`.
It retains complete score vectors, image orders, gaps and runtime identities.
The FP32 baseline version is
`siglip2-b16-224-v1-3c94a2fa253442aa6c19ce6d0cf97a5ecbeffaa78dbf04d973022171afa8e45b`;
the FP16 candidate version is
`siglip2-b16-224-v1-4db0c5989d73c0669fd1909e8e2d91502351b75390a9cee1a2bc0ba2ec3b6c62`.
No scalar gate was relaxed, no mixed-precision switch made, and no build47
was signed or uploaded. A representative real-photo ranking/relevance
evaluation is still needed before a ranking-based quality acceptance decision.

The user approved a public real-photo diagnostic. `fp16-native-ranking.yml`
now has an opt-in `real_photos` boolean, leaving the synthetic diagnostic as
the default. `prepare_real_photo_benchmark.py` uses the official COCO 2017
validation annotations with pinned archive and JSON SHA-256, filters strictly
to the image-level CC BY 2.0 license, and selects 240 distinct images in a fixed
hash order, including at least eight positives for each of 24 predetermined
object categories. Two fixed Chinese queries per category give 48 prompts;
these are correlated prompts, not 48 independent categories. Selection and
queries are fixed before looking at model predictions.

The [COCO terms](https://cocodataset.org/dataset/termsofuse.htm) distinguish
CC BY 4.0 annotations from each photo's Flickr license. The benchmark retains
each photo's source/Flickr URL, license and SHA-256, records COCO annotation
credit and the native preprocessing transformation, and publishes metadata
and measurements only, not photographs or model bundles. License filtering
uses the pinned COCO license record, not an invented blanket license for all
COCO images. All photo downloads use the TLS-valid official Amazon S3 bucket
endpoint; certificate verification is never disabled.

`project.real-photo-diagnostic.yml` adds the corpus to the test target only.
Native FP32/FP16 comparisons use the same original JPEGs through app
preprocessing and the same native Chinese tokenizer, on CPU and all compute
units. Results retain full score/order data, top-five drift and score gaps,
plus annotated-object hits in the top five, top-one label relevance and binary
nDCG@5 for each model. Object presence is only a relevance proxy: no human
semantic judgments, attribute/compositional queries, translation, personal
library, cleanup grouping quality or real-device performance claim is made.
This diagnostic neither changes existing acceptance gates nor signs/uploads
build 47.

### Completed public real-photo diagnostic

Run `38606281528`, source
`8bd84fc6a86775e870cfd6a7f58499ae6614611d`, job `115997901703`,
completed the native real-photo comparison and both metric helper tests:
3 executed, 0 failures, no skips. This means the diagnostic executed, not that
FP16 passed a quality acceptance gate. The corpus contains 240 unique photos,
24 categories and 48 fixed Chinese prompts. Its SHA-256 is
`651d5a599206f659513f18c1bc85e48912a6ccc6f6ae211c6a21cb2dbb421712`.

CPU-only and all-compute configurations produced identical complete scores and
rankings. The report contains 96 ranking and 96 relevance measurements, but
only 48 distinct queries, with two correlated prompts per category.

| Ranking agreement, per configuration | Result |
| --- | --- |
| Top-one result unchanged | 39/48 (81.25%) |
| Top-five membership unchanged | 28/48 (58.33%) |
| Exact ordered top-five unchanged | 14/48 (29.17%) |
| Aggregate top-five overlap | 215/240 result slots (89.58%) |
| Pair inversions among shared top-five members | 55 |
| Maximum native FP32/FP16 score difference | 0.02077447540908979 |

| Object-label relevance, per configuration | FP32 | FP16 |
| --- | --- | --- |
| Relevant top-five result slots | 193/240 (80.42%) | 196/240 (81.67%) |
| Relevant first results | 41/48 (85.42%) | 40/48 (83.33%) |
| Mean binary nDCG@5 | 0.8134834825 | 0.8239985363 |

Binary nDCG@5 improved for 8 prompts, declined for 4 and was unchanged for 36.
Declines were `boat-phrase` (0.52963 to 0.38357; relevant top-five hits 3 to 2),
`dining table-noun` (0.85393 to 0.66084; hits remain 4),
`cell phone-noun` (0.78601 to 0.66084; hits remain 4), and
`cell phone-phrase` (0.68435 to 0.65481; hits remain 3).
For example, `boat-phrase` lost the boat-labeled photo
[`000000508101.jpg`](https://s3.amazonaws.com/images.cocodataset.org/val2017/000000508101.jpg)
from its top five and introduced photos `000000261888.jpg` and
`000000422836.jpg`, neither labeled with a boat. Top-one changed for
`person-phrase`, `car-phrase`, `train-phrase`, `cat-noun`, `cat-phrase`,
`cow-phrase`, `couch-noun`, `dining table-noun` and `cell phone-noun`;
their baseline first/second score gaps ranged from about 0.000194 to 0.003680.

Artifact `11915854432` was downloaded and its ZIP digest verified as
`0be411da9f6f9f592b81836e61c702e4b8e9762258db7d93ae29a44787760bfc`.
It contains the source/license manifest and native JSON measurements only,
not photos. Full stored scores were independently re-sorted, and recorded
top-one/top-five agreement, score errors and relevance metrics were checked
against the corpus labels.

The results demonstrate ranking changes, not uniform quality degradation:
average top-five label precision and nDCG rose slightly, while first-result
label relevance fell slightly and individual prompts regressed. This small,
object-focused corpus and annotation-presence proxy cannot establish semantic
equivalence, statistical significance or performance on a personal library.
The earlier native numerical failure is retained as evidence, not described
as numerical parity. After reviewing these results, the user explicitly
approved continuing TestFlight build47 using the real-photo outcomes instead
of native scalar-error blockers. The new policy is
`fp16-real-photo-experiment-v2`; the prior policy and its failures above are
historical, not the current build47 acceptance criteria.

The full signed workflow reruns the same corpus on CPU and all compute units
alongside all App/UI tests. Before signing, every query must reproduce its
approved FP16 relevance metrics or improve, without increased top-one/top-five
ranking drift; baseline metrics and corpus/model identities are pinned.
Numerical discrepancies remain explicit diagnostic rejections in native JSON
and logs. Tokenizer, preprocessing, model output validity, app normalization,
FP32 gates and macOS export integrity checks are not weakened. The actual IPA
must still be at most 900 MiB. FP32 models and public photos remain test-only;
only source/license metadata, measurements and safe delivery evidence are
published. At that policy change, build47 had not yet been signed or uploaded;
the confirmed delivery is recorded above.

The first full v2 attempt, run `38611880124` from
`3e70e89d3828240005eaf2a86830f12066432cc1`, passed source tests, Core 79 and
both model exports, then stopped during resource preparation: its workflow
incorrectly passed unsupported `--download` to the corpus preparation script.
No App/UI execution, archive or upload was reached. The workflow now uses the
same no-argument invocation as the successful real-photo diagnostic, with a
regression test that parses both workflows' actual arguments through the
corpus script's argument parser.

Run `38613130419`, source `b6b1ce44f2548d5db5f8c8da4d79b1120afb191a`,
job `116021330933`, completed Core 79 and App 2151 (1 existing skip),
with zero failures. The native 240-photo comparison and diagnostic-input
helper executed successfully; this alone does not confirm the subsequent
per-query acceptance checker. UI executed 23 (1 existing skip), with one
failure in the OCR opt-in test: a coordinate tap intended to turn the native
switch OFF left its value ON and the exact-value wait timed out. No archive
or upload was reached.

The OCR test now reuses the inner native-thumb drag already validated by the
location-persistence test; production behavior and exact state/privacy checks
are unchanged. The full signed workflow first runs both switch-persistence
tests with real models, then still runs the complete App/UI suite. Native
real-photo JSON is now exported and checked without signing credentials even
when a later UI test fails, so unrelated UI failures cannot discard the
completed ranking/relevance evidence. Failed native/UI tests still block
signing and upload.

Synthetic numerical/native tests do not establish real-photo retrieval quality,
ranking equivalence, phone speed or peak memory. Those need comparison on the
tester's device after a successful experimental delivery.

## Manual workflow

Run **TestFlight — signed FP16 1.0 build47** from `main` in
`xwgnick/local-image-iq-ios` only. The workflow performs API/app preflight,
pinned resource preparation, full native App/UI tests with real models, a
manually signed arm64 Release archive and App Store export, exported identity,
signature, profile, privacy/legal and resource checks, Apple package validation,
one upload, then up to 30 minutes of Apple processing checks.

Required repository Actions Secrets:

- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`
- `APPLE_TEAM_ID`
- `IOS_DISTRIBUTION_P12_BASE64`, `IOS_DISTRIBUTION_P12_PASSWORD`
- `IOS_PROVISION_PROFILE_BASE64`

Use an App Store Connect team API key with Developer access and the approved
Apple Distribution certificate/profile. Keep original key material outside the
repository. Never put private keys, P12 passwords or Base64 exports in Git,
chat, logs or artifacts.

Credentials are exposed only to preflight and signing/upload steps, removed
from child-process environments, stored in a temporary restricted directory,
and cleaned with the temporary keychain and installed profile. No signed IPA,
archive, profile or private key is published as a public GitHub Release/artifact.
Only `testflight-delivery.json`, containing non-secret delivery evidence, is
retained. This is a public source repository: audit workflow changes before
allowing future runs to use its signing Secrets.

Keychain rejected the original OpenSSL 3 PBES2 P12 during the first two
preflights (`security import`: MAC verification failed); API authentication and
the app lookup already passed, and no upload was attempted. The runner converts
the original P12 with OpenSSL 3 to a temporary Keychain-compatible 3DES/SHA1 P12,
using the same password through restricted files. This affects only the
temporary import container, not the Apple certificate, application signature,
API authentication or original stored P12. All intermediate files are cleaned.

The final report distinguishes an attempted upload, an accepted upload and
Apple `VALID` processing. On a failed/ambiguous upload or processing timeout,
inspect App Store Connect and the existing run before retrying. Never blindly
re-upload an attempted build. Model conversion, native validation and actual Apple upload
must finish before declaring this build delivered.

No tester invitations, external beta review, App Review submission, price
changes or public App Store release are performed. Once processing is valid,
complete any Apple export-compliance questions and enable internal testing in
App Store Connect. Paid-app agreements and mainland distribution compliance
remain separate public-release tasks.

Do not uninstall the existing sideloaded app. A different Bundle ID/signing team
may install separately; preservation of that app's local index is not guaranteed
by installing the new TestFlight identity.

Current status: signed FP32 `1.0 (46)` and FP16 experiment `1.0 (47)` uploaded,
with Apple processing confirmed `VALID` by runs `38570734400` and
`38625232929`, respectively. Test-group availability and build-specific
export-compliance responses are managed separately in App Store Connect.
No App Review or public App Store release was requested.

## Validation history

Run `38552330364` passed real macOS signing preflight, Core 79, and App
2145 (2144 passed / 1 existing device-only skip / 0 failures). UI ran 23 with
1 existing skip and 1 failure: after restart the location switch's coordinate
tap did not turn it off. No archive/upload was attempted. The UI test now
targets the sole nested native switch with an actual thumb drag; desired-value
and ON/OFF restart persistence assertions remain unchanged.

Targeted run `38560413931`, source
`ce94543379bf3569b7891de42aa1686e7f28f22c`, executed
`testLocationEnhancementIntroductionSettingsAndRestartPersistence` on the iOS
simulator: 1 test passed, 0 failures, no skip. This targeted result alone did
not establish an Apple upload.

Run `38561852604`, source `fa89e28e255fe372c686a1bfe590ccf72708c728`,
passed Core 79, App 2145 (1 existing skip), and UI 23 (1 existing skip),
all with zero failures. Archive then failed because command-line provisioning
settings also reached the `swift-transformers_Hub` and `swift-crypto_Crypto`
resource bundles, which do not support provisioning profiles. No Apple upload
was attempted. The signing variant `project.testflight.yml` now scopes official
identity and manual signing to `LocalImageIQ` only and is generated after native
tests pass. Archive arguments pass custom variables referenced only by that
application target, not global provisioning or bundle identity overrides.
The subsequent run below verifies the actual archive, export and upload.

## Confirmed first TestFlight delivery

- [Successful workflow run](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38570734400):
  source `1a3a28d2bbbe595b5f80f4110d8e3ab93efabdfe`.
- Core: 79 passed; App: 2145 executed, 2144 passed, 1 existing skip;
  UI: 23 executed, 22 passed, 1 existing skip. Zero failures.
- Signed arm64 Release archive and App Store export succeeded. Exported
  identity, signature, entitlements, exact profile, privacy/legal resources,
  Places and both production models passed validation.
- Apple accepted the upload and confirmed `processingState=VALID` at
  `2026-10-14T14:38:28Z`.
- App Store Connect app ID: `6822662787`; Apple build ID:
  `1b2233dc-8458-42cc-b99e-b65c53a609f1`.
- Signed IPA: `1422924391` bytes, SHA-256
  `4c055100cae06a497b28f96fffe57355f1a820d9ee3f243f273c7b6bacbb4fb8`.
  The IPA itself is not published as a GitHub artifact.
- [Safe delivery report artifact](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38570734400/artifacts/11903526696):
  downloaded and its ZIP SHA-256 verified against GitHub's artifact digest,
  `6bbcde8542284662475cbbad08bfc556d4da02c7d4c10cd119dc05f5b7b94725`.
  The report confirms `signed=true`, `nativeValidation=true`,
  `uploadAccepted=true`, `processingState=VALID`,
  `publicStoreSubmission=false`.

Do not rerun upload for build 46. Open App Store Connect, select the app, then
TestFlight and `1.0 (46)`. Check export compliance based on the actual encryption
usage before answering any questions; do not assume that local-only operation
means no encryption. Configure an internal testing group and tester access
there. No tester was automatically invited, and Apple processing success is not
confirmation of installation or tester availability.
