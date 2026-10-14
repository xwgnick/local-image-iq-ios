# TestFlight: first official signed build

Approved identity: `app.piankexun.ios`, marketing version `1.0`, build `46`.
The existing unsigned `0.16.5/45` development delivery is unchanged.

## FP16 experiment: build 47

The next manual workflow targets `app.piankexun.ios`, `1.0 (47)`, with the
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

FP16 keeps the Float32 image/output and Int32 token interfaces. After the full
diagnostic below, the user explicitly approved the separate
`fp16-normalized-experiment-v1` policy: vector cosine strictly greater than
`0.999`, paired cosine-matrix absolute error at most `0.002`, and raw component
error recorded as a diagnostic rather than a gate. Production search normalizes
the vectors. FP32 retains its original raw maximum error `1e-3` and paired
matrix error `1e-4`; Torch wrapper/trace and image preprocessing gates are
unchanged for both precisions. Reports and manifests name the policy.

FP16 must also pass full native model/App/UI gates, including a new paired
score comparison against FP32 references on both CPU and all compute units.
Failure stops delivery, not a silent FP32 fallback or automatic threshold
adjustment. The signed exported IPA must actually be at most
900 MiB before any Apple package validation/upload. The delivery report records
precision, model version, bytes, SHA-256 and the build46 byte baseline.

Status: run `38589052732`, source
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

Current status: signed `1.0 (46)` uploaded and Apple processing confirmed
`VALID` by run `38570734400`. Internal tester access and any export-compliance
questions still need to be completed in App Store Connect. No App Review or
public App Store release was requested.

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
