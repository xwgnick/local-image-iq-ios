# Cloud build status — 2026-09-22

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
- All dispatched runs use `include_models=false` and `all_compute_units=false`.
  No models have been downloaded, converted, signed or submitted to TestFlight.

Latest validation: [run 35630122554](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35630122554),
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

Next: explicit model-enabled conversion and parity run, then device validation and
signing. No model-enabled workflow has yet been dispatched.

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