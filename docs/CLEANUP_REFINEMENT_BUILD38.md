# 0.15.0 / build38 — approved refinement implementation

Status: **DELIVERED / PASS-PACKAGE / PERMANENT SINGLE-TEST EXCEPTION / PENDING-DEVICE**. Version **0.15.0 / build38**, release source **`782765fcfdea08b136f5aa5378b0c1258d01441f`**. The third full validation succeeded after seven targeted runs and two failed full validations. User approved the comprehensive cleanup design and V5 hero on 2026-10-10, then added three native requirements; all are included in this package.

**[Download unsigned IPA](https://github.com/xwgnick/local-image-iq-ios/releases/download/ci-38054261362-1/LocalImageIQ-0.15.0-build38-iphoneos-unsigned.ipa)** / [verified local IPA](../build/device-download/38054261362/LocalImageIQ-0.15.0-build38-iphoneos-unsigned.ipa). Use the same Sideloadly account and effective Bundle ID to overwrite the existing installation. Do not uninstall, clear data, reauthorize or rebuild the index just to upgrade.

## Included scope

### Unreleased follow-up — 2026-10-11

Local source changes, **not included in the delivered build38 IPA**:

- Group overview rows retain their 44pt header actions and five square previews.
  Group spacing decreases from20pt to4pt, row spacing from8pt to4pt, and
  divider top padding from12pt to4pt. At ordinary text sizes this removes32pt
  per group-to-group interval without shrinking previews or changing selection.
  Large text remains free to increase header height.
- Privacy and About shows short local-processing, cloud, deletion and sharing
  summaries with two initially collapsed “了解详情” disclosures. Existing detailed
  statements remain available; OCR retention, explicit single-photo cloud
  consent, deletion propagation and recipients retaining copies stay visible.
  This is a layered product notice, not a legal-compliance certification.
- Initial suggestions remain 身份证, 猫猫追逐逗猫棒 and 海边日落; the last submits
  海边的日落. They fill empty history slots and are not fabricated saved searches.
- Added native compact-row sizing coverage at320/393pt and ordinary/maximum
  accessibility text, plus privacy-summary boundary regression coverage.
  Native execution and a new release remain pending; Windows source checks
  cannot establish rendered layout or iPhone acceptance.

### Delivered build38 scope

Follow-up build39 native validation:

- Targeted1 run38123466637/job114422822269, source
  `94f8b7f79b2cea1bd419f23bdd466a647e4673fb`: FAILED, no IPA.
  Compilation passed. OCR11 and recent-query16 passed; refinement6 had two
  assertion failures in the new compact-row method. App33 methods in37.030s
  (wall44.573s). The new privacy disclosure UI method passed in52.445s.
  The sizing test used the whole hosting controller's fitting height, which
  includes host space rather than measuring the row itself. It now observes
  the actual fixed-height row geometry, keeping the same header/preview/spacing
  thresholds and large-text coverage. Production spacing and privacy unchanged.

- Approved V5 homepage artwork only; system B02 AppIcon and launch assets unchanged.
- Remove lower-left indexed-count footer; keep counts available in Library and the existing upper home subtitle.
- Recent query chips use measured text widths, compress only when the single row cannot fit; full stored/action/accessibility query remains unchanged.
- OFF→ON OCR triggers one incremental text-index pass; saved ON restoration does not. Busy work defers one intent, OFF cancels, valid commits remain. Shared photo/OCR bottom capsule, no inline update-text button; Library manual maintenance remains.
- Navigation selected text only; same muted icon color and no selected background.
- Cleanup settings: similarity plus presentation-only minimum group count, each with info. Default .95 only for missing/invalid old similarity preference; minimum count begins at2 and uses actual maximum group size.
- Lightweight group rows, five preview tiles, full detail preserved. Group tri-state selection includes all members, never implicitly keeps one. Hidden selected counts disclosed and bound to confirmation. Current-group and whole-selection clear labels are distinct.
- Retained browsing identity separated from selection/deletion authority. Inactive/locked content hidden; readable fresh metadata can restore presentation while full source verification proceeds. Real revoke/change clears old content. Successful deletion updates retained subsets and uses compact status, not a second mandatory fullscreen wait. Not a promise of never regrouping.
- Result ellipsis removed. Per-query correction actions live on the leading search icon (tap/long-press and AX actions), not a delegate replacement of the native text-selection menu; system editing remains intact. Live query/resolution guards reject obsolete actions.
- Compact real search waiting UI. Cache-miss rebuild encoding/write moved off the response critical path; full source checks remain. Valid-cache cold hash/decode/matrix costs remain, no claimed phone latency yet.
- HQ224/Fast preview retained; automatic local viewport/zoom upgrade, single-photo explicit cloud consent, retained image/zoom on failure/cancel, late callback/source isolation. Sharing labels actual preview/HD rendition, not original.

## Validation policy

Targeted native workflow first, full release only after related checks pass. No added waiver; permanent drag-dismiss-keyboard exception remains SKIP, not PASS. No real private Photos deletion, no uninstall/data reset/reindex requirement. Same Sideloadly identity for overwrite installation after delivery.

New source tests cover adaptive chips/navigation, OCR intent/drain/footer/library, HD demand/permissions/late callbacks, cleanup filters/multi-selection/browsing authority, cold-cache cost and exact scores, secondary menu and integrated root presentation. Source/static review is not native validation; exact runs/results will be appended as available.

## Validation ledger

1. Targeted run38041139808 / job114181461565, source `d321dfab731c0952e6fcb2f2cee3c42b87056afa`: FAILED at test compilation, not a test pass. Production compile reached test compilation. Two test-source issues: integer arithmetic inferred as Int in CGFloat expectation; subscription attempted to use a projected publisher for computed `selectionSessionID`. Fixed by explicit CGFloat arithmetic and observing actual groups publication (after session assignment). No production safety gates or assertions weakened; no IPA from this run.
2. Targeted run38041450136 / job114182355819, source `a34b4bfea9c18c8cd4ed105e8276a48c68db2a75`: FAILED at test compilation. Swift type checker exceeded its expression budget in the HD test pixel-count reduce expression. Replaced it with equivalent typed loop and unchanged RGB thresholds. No production or acceptance change.
3. Targeted run38041736416 / job114183173531, source `0ac4b20b2a4b582da0bda6e0f5f55528cb1cb104`: compilation passed; App296 tests,294 passed/2 failed,0 skipped,182.279 test seconds/wall183.970. Failures: foreign UIMenu input identity assumption (UIKit copies assigned menu) and UISlider intrinsic31pt incorrectly equated to external44pt touch area. Corrected to installed-menu identity with foreign-action execution checks, and external geometry plus actual hit-routing checks. New external UI test failed because empty search menu button appeared in AX before any search; fixed production empty state to disable interaction and exclude its accessible subtree/identifier while retaining layout identity. No acceptance waiver; no IPA. All other requested App classes passed this run, including OCR, HQ, adaptive widths, cold-cache and integrated root tests.
4. Targeted run38043053575 / job114186984240, source `3e19f78ee76cb90467e476c9930ad0e6c960e9ba`: App30 methods,29 passed/1 failed with10 assertion records,78.088/wall81.591. Menu/root/control suites passed; strict slider hit-routing exposed a genuine issue: padded outer44pt bands routed to the scroll ancestor rather than the31pt slider, plus alignment insets. Fixed production slider sizing/alignment/hit bounds, not relaxed assertions. External UI3 methods:2 passed/1 existing model-required OCR test skipped,352.605/wall352.609. Root AX and cleanup UI passed. The OCR method's pre-existing model-free skip is NOT a release waiver or pass; it must execute with models in full validation and is omitted from further model-free selectors.
5. Targeted run38044049211 / job114189878465, same final pre-full source `32e9d43374fce11c9213a729983a559452cf71ac`: SUCCESS,13 passed/0 failed/0 skipped,42.476/wall42.488. Native44pt slider edge hit routes verified.
6. Full validation1 run38044590594 / job114191447493, same `32e9d43`: FAILED, no IPA. Core79 passed. App2055 methods/1 existing SQLite skip/13 assertion failures (8 methods),987.871/wall996.636. External UI17/1 permanent keyboard skip/3 failed,1833.020/wall1833.060. Legacy failures: OCR manual-only/privacy text; two navigation fixtures and AX fixture omitted synthetic browsing access; publication teardown incorrectly required retained data to be erased rather than display/selection authority hidden; physical edge test tried old30-tile overview sample176 although approved overview now first5. Updated meaningful expectations/fixtures, not production safety. Debug-off translation test had one strict absent-node timeout after scrolling; existing recording at45.8s shows toggle OFF/no diagnostics visible, not proof of AX absence. No production debug change without root cause; exact test will be rerun with stronger failure attachments.

Failed full1 UI evidence downloaded and SHA verified: draft408897328, UI asset627778735,32,057,638 bytes,SHA `320e3fe932d7fd2932af9069078d8c9a70fce989e75cee09b190d4415ce74d4a`. Not a successful package. Its cold-cache synthetic comparison:256×768, old eager0.778978s/new critical0.719236s/deferred tail0.012589s. Rank/score bits equal, one source hash each; new critical path had zero packing/enveloping/writes versus old786,432 packed bytes. Eager ran first with uncontrolled OS caches, no PhotoKit/ML/translation; do not claim a phone speedup ratio.

7. Targeted6 run38048771635 / job114203507656, source `53a1272ba4661195452eba882fac8a91a805ffb2`: SUCCESS,47 App passed/0 skipped/0 failed,44.194/wall44.778; two external UI tests passed,223.394/wall223.402. Strict debug-off failure did not reproduce, no production debug change or timeout relaxation.
8. Full2 run38049627993 / job114205969739, same `53a1272`: App2056/1 existing SQLite skip/0 failed,1018.149/wall1025.157. UI17/1 permanent keyboard skip/1 failed,2004.467/wall2004.490. OCR full-model UI and physical cleanup gesture passed. Sole failure same Chinese UI test but now initial Settings root's absent debug-launch-timing query, before ever opening Advanced. Trace shows first query at25.88s, internal lookup retries30.15s, waiter timeout—not explicit exists=true evidence. No IPA.

Candidate test-helper correction: perform strict synchronous exists query BEFORE constructing disappearance expectation; if true retain original5-second wait and require final exists=false. A timed-out positive branch still fails even if final query is false. Initial snapshot time is now outside the wait window (total helper time may increase), not a wall-clock responsiveness assertion. Dedicated native control verifies absent passes, stable existing Settings Done is rejected with timeout, then dismissed Done passes. No expected-failure/skip added. Actual AX leak remains an alternative unless runtime evidence rules it out; do not label root cause proven solely by a passing rerun.

9. Targeted7 [run38053578620 / job114217431981](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38053578620/job/114217431981), source `782765fcfdea08b136f5aa5378b0c1258d01441f`: SUCCESS. DebugTools7 passed,31.508/wall31.516; external Chinese translation controls1 passed121.256 and StrictAbsenceProbe1 passed20.681, combined141.937/wall141.944. Zero failed/skipped. Initial queries returned exists=false; positive control still rejects a genuinely present Done button. No production debug fix or added waiver is claimed.
10. Full3 [run38054261362 / job114219383113](https://github.com/xwgnick/local-image-iq-ios/actions/runs/38054261362/job/114219383113), same release source: **SUCCESS**. Core79 passed,0.272/wall0.278. App2056 = **2055 passed / 1 existing SQLite simulator skip / 0 failed**,891.462/wall896.020. External UI18 = **17 passed / 1 permanent keyboard skip / 0 failed**,1735.096/wall1735.121. Real-model parity8 passed109.059/wall109.064 (included in App count); CPU/`.all`/20 actors retained. Workflow completed2026-10-10T14:07:55Z. No additional run was dispatched after interruption; the exact existing run was found completed.

## Final checks and evidence

- Only two final test skips: `SQLitePhotoStoreTests.testCacheFileProtectionOnPhysicalDevice` (simulator lacks physical data-protection attributes) and user-approved `SearchKeyboardTests.testDraggingScrollViewDismissesKeyboard`. Skip is not pass. The model-required OCR UI test executed in this full run, not skipped. Done, selection, navigation and other safety checks remained required.
- Actual final cold-cache comparison:256 records ×768 dimensions; old eager **0.565147792s**, new critical **0.512154833s**, deferred tail **0.009878583s**. Both paths perform one2,502,656-byte source hash and one SQL load, validate all256 records, and preserve exact rank/score bits. New critical work has zero packing/enveloping/write; deferred work packs786,432 bytes and stages76,475 bytes. Eager ran first, OS caches uncontrolled, no PhotoKit/ML/translation; **not a phone speedup claim**. [Original measured attachment](../build/ui-review/38054261362/cold-search-preparation.json).
- Parent actually viewed [six-scene native contact sheet](../build/ui-review/38054261362/build38-native-review.jpg),1020×1550, with [scene hashes and IPA metadata](../build/ui-review/38054261362/build38-native-review.json): V5 home, adaptive long history, expanded cleanup controls, hidden group selection, OCR footer after photo-work handoff, empty default viewer. Five sources1179×2556, viewer393×852. No bulk full-size image review.
- Cleanup screenshots are synthetic standalone hosts with a Done/manual-regroup control, not the embedded production navigation mode. Colored thumbnails are fixtures. Viewer screenshot contains no real photo, so it does **not** visually prove HD/cloud rendering. HD demand, local/cloud scope, cancellation, late callbacks and stable layout are covered by native tests; actual device Photos/iCloud and perceived speed remain unverified. No private Photos were accessed/deleted for testing.

## Published package and full local verification

- [Release ci-38054261362-1](https://github.com/xwgnick/local-image-iq-ios/releases/tag/ci-38054261362-1): ID **408988698**, published **2026-10-10T14:07:49Z**,9 assets, prerelease, not draft. Bound to the exact successful source above.
- IPA asset **628129794**, **1,420,430,690 bytes**. Full streamed local download SHA-256: **`c8448a137b24289bd7e58476b7f381003694d6706f73892fd872abbd86500e2c`**. [Download verification record](../build/device-download/38054261362/release-fetch-2fbf5c04-b7a9-49fc-97bf-67047d2a7936.json).
- **7-Zip26.04 full archive CRC: Everything is Ok**;11 folders,30 files,1,570,772,614 bytes unpacked. Actual IPA Info.plist read confirms0.15.0/38, `com.example.localimageiq`, LaunchScreen, minimumiOS17, SDKiphoneos18.5/Xcode1640. Package is unsigned arm64; no Apple credentials used. Original package verification does not verify the later locally re-signed IPA.
- UI evidence asset **628129334**,11,824,191 bytes, fully downloaded and SHA-256 verified: **`fb8df24bb640a090f06845a631f818cdff1484dcd82f71575cde0c539c33ee33`**. [UI download record](../build/ui-review/38054261362/release-ui-review-9f4e3394-01e2-45bf-8ca2-9a7601b69c1d.json).
- Model identity remains SigLIP2 base224 revision-pinned768D; Places15,175,079 bytes /2943 features and prior SHA unchanged. No cross-version full model-weight byte comparison was performed in this delivery check.

This closes the source/validation/package milestone, not physical-device acceptance. Earlier failures and cold measurements remain above as history, not additional successful releases or measurements to average together.