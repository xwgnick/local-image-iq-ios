# Cloud build status — 2026-09-22

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
replace personal signing. A Mac to use for installation has not been confirmed.
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