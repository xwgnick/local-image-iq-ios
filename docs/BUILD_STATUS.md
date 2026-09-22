# Cloud build status — 2026-09-22

## Search keyboard dismissal · 0.1.2 (3)

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

## Preview-first fix for optimized iCloud libraries · 0.1.1 (2)

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

## Latest: unsigned physical-iPhone IPA built

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

## Latest: model-enabled validation passed

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

## Active personal repository

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