# 片刻寻 · App Store engineering preparation

This work prepares the existing personal, on-device app for submission. It does
not enroll an Apple account, change the placeholder Bundle ID, sign a build,
determine mainland-China filing applicability, or grant
legal clearance. **build40 (0.16.0) is the last delivered unsigned IPA**, not an
App Store submission. Feature development is paused at that candidate.

The owner has not enrolled in the paid program and approved preparation of
account-independent submission materials on 2026-10-12. See the
[first-release materials](APP_STORE_SUBMISSION.md) and
[Simplified Chinese metadata draft](app-store/metadata.zh-Hans.json).
Submission metadata remains an unsubmitted draft. The owner subsequently approved
public operator 谢文戈, `xiewenge_neu@163.com`, GitHub Pages and support-message
deletion within 90 days after resolution, subject to necessary retention.
The [privacy policy](https://xwgnick.github.io/local-image-iq-ios/privacy.html)
and [support page](https://xwgnick.github.io/local-image-iq-ios/support.html)
were published by run `38199490327` and verified over HTTPS. No test email
was sent; mainland network reachability remains unverified.

## Toolchain and behavior

- Both manual workflows select **Xcode 26.3 / iOS 26.2 SDK** on the existing
  standard `macos-15` public runner. The exact version is verified; no fallback
  to the runner's Xcode 16.4 default. Simulator selection requires iOS 26.2.
- Minimum iOS remains **17.0**, Swift language mode remains **5**, and existing
  model, tokenization, geometry, numerical and test gates are not relaxed.
- `UIDesignRequiresCompatibility = YES` temporarily preserves the previous SDK's
  system UI. Apple ignores this key for SDK 27 and later; a future SDK 27
  migration needs an explicit design review, not an indefinite compatibility
  promise.
- The seven iOS-linked packages are constrained to their build39 versions.
  `scripts/release_dependencies.json` records exact commits, linked targets and
  the source privacy review. Other resolved packages may be test-only or
  non-Apple dependencies; a resolved package is not automatically shipped code.
- Before compilation, CI resolves once into `build/SourcePackages`, verifies
  the audited revisions and notices, and disables automatic re-resolution.
  A dependency update requires a fresh target-graph/privacy/license review.
- The full workflow now has `publish_release` (default `true`, preserving the
  existing release path). Engineering validation uses `false`: tests and device
  package checks still run, but only evidence is retained; no new app is published.

Sources:
[current upload minimum](https://developer.apple.com/news/upcoming-requirements/?id=04282026a),
[runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md),
[UI compatibility](https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility).

## Privacy manifest review

The app's `App/PrivacyInfo.xcprivacy` declares no tracking domains, no tracking,
and no data collection by the developer or integrated partners in the current
app's execution paths. This is not a claim that Apple system services never
communicate with Apple.

| Category | Reason | Actual use |
| --- | --- | --- |
| User defaults | `CA92.1` | App-owned translation/OCR preferences, cleanup threshold and startup state; no other-app or MDM reads |
| File timestamps | `C617.1` | App-container index/cache identity and staleness checks; `stat`/`fstat`/`lstat` and metadata reads |
| System boot time | `35F9.1` | Elapsed startup/search timing inside the app; no raw boot-time transmission |

PhotoKit asset dates are not the same API category as filesystem timestamps.
No disk-capacity or installed-keyboard reason is declared without a matching use.
`swift-huggingface` reads file size/type in download helpers, not the timestamp
properties on Apple's list; those network helpers are not called by this app.
The app calls the tokenizer's local `modelFolder` initializer.

The seven package source trees were inspected at the recorded revisions.
On iOS, Swift Crypto reexports Apple CryptoKit and supplies its own no-collection,
no-required-reason manifest in `swift-crypto_Crypto.bundle`; BoringSSL/CXKCP are
not in the iOS target graph. The app does not substitute its own declaration for
that SDK resource. CI checks the actual app bundle for both manifests.
Source inspection is not a substitute for Apple's binary/submission validation
or an exhaustive runtime network audit.

Sources:
[required reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api),
[approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype),
[privacy labels](https://developer.apple.com/app-store/app-privacy-details/).

## Third-party license review

`Resources/Legal/ThirdPartyNotices.txt` includes full package license/notice
texts, the Pillow permission/disclaimer, model attribution and conversion
description, and the existing full geoBoundaries/source attribution.
`third-party-manifest.json` records exact package revisions and notice hashes.
The notices are available offline under **Privacy & About > Third-party notices**.

| Material | Public license evidence | Treatment / limitation |
| --- | --- | --- |
| SigLIP 2 paired model and tokenizer | Pinned Google model card: Apache-2.0 | Include Apache text, source revision and conversion description; do not infer that the Gemma tokenizer class name imports unrelated Gemma model terms |
| swift-transformers, swift-huggingface, swift-jinja | Apache-2.0 | Full root licenses retained |
| swift-collections | Apache-2.0 with Swift exception | Full `LICENSE.txt`, including exception, retained |
| swift-crypto | Apache-2.0 | Both `LICENSE.txt` and `NOTICE.txt` retained; non-iOS crypto targets are not represented as shipped |
| EventSource, yyjson | MIT | Full copyright, permission and disclaimer retained |
| Pillow resampling adaptation | MIT-CMU | Existing full source notice also shipped in end-user-readable form; Swift adaptation identified |
| geoBoundaries / country sources | CC BY 4.0 collection; per-source Public Domain/PDDL/Etalab/Germany Attribution/CC0 records | Existing attribution, license links, historical dates and transformations retained |

These permissive licenses generally authorize redistribution subject to their
terms; a separate personal permission letter is not automatically required.
CHN/ADM1's release metadata has an incomplete Wikimedia `licenseSource` link.
On 2026-10-12 the pinned source ZIP's `meta.txt` and `license.png` recovered the
full [original file](https://commons.wikimedia.org/wiki/File:China_blank_province_map.svg):
author Newfraferz87, own work, released to the public domain. Both the archived
license screenshot and current file page were verified. This resolves that
specific source-link gap; see the [evidence record](APP_STORE_SUBMISSION.md).
Bundling notices does not repair missing provenance or determine China-specific
map/geographic-data obligations. No model/data `redistributionApproved` flag has
been changed to `true`, and numerical parity is not legal approval.

To reproduce/verify notices after XcodeGen and dependency resolution:

```sh
xcodebuild -resolvePackageDependencies -project LocalImageIQ.xcodeproj \
  -scheme LocalImageIQ -clonedSourcePackagesDirPath build/SourcePackages
node scripts/prepare_legal_notices.mjs build/SourcePackages/checkouts --check
```

For a reviewed dependency update, omit `--check` to regenerate the two tracked
legal resources, inspect changed licenses, update the inventory/project pins,
then validate the native target graph again. No package source is patched.

## Published policy and support pages

- [Privacy source](app-store/privacy.html)
- [Support source](app-store/support.html)

These static pages have no scripts, forms, analytics or remote fonts.
The owner approved the operator identity, contact email, GitHub Pages hosting
and 90-day support-message rule on 2026-10-12. The draft banners were removed
and publication verified (HTTPS 200; browser content and responsive layout).
GitHub's security IP logging is disclosed. No email from Git history is reused.
Receiving a support email and reachability across mainland networks remain
unverified.

The app's local privacy UI remains usable offline. Preparation commit
`7364a8470bfd704fb60cf62ce201afb3b7b69613` adds explicit external policy/support
links without loading them automatically. The metadata draft contains the
verified URLs. Native verification is recorded separately from source changes;
the delivered build40 IPA does not acquire these links remotely.

## Validation and remaining release boundary

Local Node tests cover declarations, exact toolchain/runtime selection, unchanged
iOS deployment target, notice integrity and workflow integration. Native
`ReleaseResourceTests` parse the actual bundled plist and read the actual legal
resources. The UI test opens notices and returns without starting indexing.
The device packager also verifies SDK and final IPA entry presence.

Native execution results must be recorded after CI; source checks alone are not
a successful Xcode build, real model parity, physical-device validation, or an
App Store acceptance. This task does not replace existing full release gates.

### Execution record

- Engineering commit: `00c601d73b8ffd5d40ac2b7bb26cceb1f1a4f65e`, pushed to the
  existing personal public repository with the owner's explicit approval.
  The policy/support drafts and this record remain local and were not pushed.
- Node 22 regression run: **144 passed, 0 failed, 0 skipped**. After normalizing
  the generated notice's final newline, the **8 release-specific tests passed**
  again. Notice generation and verification cover all seven audited checkouts.
- The VS Code test tool did not discover these Node tests; the repository's
  existing `node --test` runner was used instead. The default Node 18.0 binary
  does not support that flag; the already-installed Node 22 runtime was used.
- Local Python launcher was unavailable (`python` exit 9009; `py` not found).
  No local Python test pass is claimed; the full native workflow runs the
  existing Python contract tests using setup-python.
- Browser checks: both local pages load with their shared stylesheet and draft
  banners, navigation works, no horizontal overflow at 375px and 1280px
  viewports, dark-mode styles apply, and there are no scripts or forms.
- Targeted native run:
  [38157158588](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38157158588),
  job `114522395894`, exact commit above: **failed**. Native compilation, all four
  new resource tests and both UI tests passed. Of 55 App tests, one compact-row
  test failed waiting for its lifecycle-based geometry callback (two failure
  diagnostics); 54 passed. The compact-row measurement now uses the existing
  native-host preference-delivery pattern instead of `onAppear`/`onChange`.
  Width, preview size, spacing, Dynamic Type and height thresholds are unchanged.
- The preference-delivery change did **not** resolve the native-host failure:
  [38158030022](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38158030022),
  job `114524946217`, commit `762feec5f8f33b91e55aa3393f02524e18059664`, failed.
  App: 53/55 methods passed; the compact-row measurement and the existing OCR
  child-publication test timed out. All four resource tests and both UI tests
  passed again. No new skip or relaxed geometry threshold was authorized.
- The owner subsequently approved the name **片刻寻**, store title
  **片刻寻－AI搜照片与相似清理**, subtitle
  **凭记忆线索找照片，挑选清理相似画面**, and tagline
  **找到想看的，留下值得的。** Policy/support drafts use the new name but remain
  unpublished. Internal install/storage identifiers remain unchanged.
- Build40 combines that branding with the approved cleanup selection/held-image
  redesign and a PhotoKit image-change relevance filter. Initial source commit:
  `72b9d66acdbc4a72aab10e84c8053f3c7ad607c8`. Targeted native run
  [38164379874](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38164379874),
  job `114543767370`, failed: 212/215 App methods passed; the compact-row
  measurement and two browser tests failed (13 diagnostics). All seven new
  cleanup tests, five resource tests, 45 photo-sync state tests, eleven OCR
  presentation tests, and the real-touch edge-return UI test passed.
- Follow-up commit `898d4ed25456e43bfd7efcaf9372524a67ae8773` fixes the row
  preference reducer's default-value identity, aligns browser assertions with
  the approved shared selection mode, and adds physical held-preview interaction
  plus fifteen-photo deletion notification tests. Geometry thresholds remain
  unchanged. Run
  [38165647830](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38165647830)
  completed with **217 App tests and 2 real-touch UI tests passed, 0 failed,
  0 skipped**. The original geometry thresholds passed. The workflow itself
  failed because its result parser did not recognize Xcode 26's `Runtime Warning`
  metadata node, not because XCTest failed.
- The captured summary/tree replay passes all 16 requested selectors after
  explicitly supporting runtime-warning leaves; warnings remain in the report,
  never count as executed tests, and unknown shapes/failures still fail closed.
  All **33 parser regression tests pass**. The single warning node belongs to
  the compact-row test: its direct call into an unmounted sheet accessed
  `StateObject`/`Environment` outside SwiftUI installation. The production row
  is now a shared view mounted directly by the geometry test, retaining the
  same layout and thresholds.
- Follow-up commit `206e69405e381b042ca44dfc6f31fec6cb462bbe`, targeted run
  [38166864780](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38166864780),
  job `114551127171`: **passed, 14 App tests plus 1 real-touch UI test, 0 failed,
  0 skipped, no runtime-warning nodes**. All three requested selectors were
  validated, including the original row geometry thresholds and shared cleanup
  selection/held-preview behavior. The full model/device release run has now
  been requested; this targeted success alone is not an IPA delivery.
- The renamed legal bundle passes all eight release-resource Node tests.
  Branded release title/body changes pass all 104 publication tests after
  updating the one old exact-heading assertion. Technical archive names remain
  stable; the published release title uses the new Chinese name.

### Build40 delivery

Full run [38167404946](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38167404946),
job `114552729482`, source `206e69405e381b042ca44dfc6f31fec6cb462bbe` succeeded:
Core79 passed; App2073 passed plus the existing SQLite physical-device skip;
UI20 passed plus the approved keyboard skip; real-model8 passed (included in App).
No new skips. Release `ci-38167404946-1` published the unsigned arm64 IPA.
Full local download (1,420,660,564 bytes), SHA-256
`b80ff3bba1efe4fcd566eb1a3b2068acfed61f2df09e401a26fa167e02fb028d`,
and all-entry CRC verification passed after the computer restarted.
Three synthetic native cleanup screenshots were inspected. This is delivery,
not physical-device validation, App Store acceptance or legal clearance.
At that delivery point policy/support drafts were local and unpublished.
They were subsequently approved and published as recorded above.

Still required before public App Store release: developer enrollment, formal
Bundle ID/signing, verified inclusion of policy links in the submission build, distribution compliance
review, applicable mainland compliance, App Store metadata and Apple review.

### Account-independent preparation after feature freeze

- Pages run `38199490327` deployed the approved public identity, contact and
  retention policy. Only the explicit website allowlist is deployed.
- Commit `7364a8470bfd704fb60cf62ce201afb3b7b69613` adds external policy/support
  links and the recovered CHN/ADM1 source evidence to generated offline notices.
  All 11 related Node tests passed. Targeted native run `38201031094` covers
  resource contracts and the existing notices-navigation UI test.
- First real-photo screenshot run `38199785425` compiled but failed its exact
  indexing gate: exported accessibility evidence showed no Photos permission
  and zero indexed photos. It produced no approved store screenshots.
- Commit `fa9e56aa84bdfdc1a2d063e851568230b2c4a8d2`, run `38201428817`, uses
  the real Photos consent UI after test installation and disables parallel
  testing. It retains the exact twelve-photo gate and production model/grouping
  behavior. Six frames per device are planned, without OCR or comparison frames.
- [Written compliance inquiries](app-store/compliance-inquiries.zh-Hans.txt)
  preserve the actual system-networking boundaries. They have not been sent.
  Apple support requires the owner's account; no identity, enrollment, filing
  or legal declaration is fabricated. The recovered source license is distinct
  from still-unresolved geographic-data regulation applicability.
