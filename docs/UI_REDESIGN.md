# Photo-first UI · 0.2.0 (4)

The user explicitly deferred model/retrieval-quality work and requested a simpler,
modern, friendly whole-app interface, especially the display of search results.

## Screen hierarchy

- Home: one headline, compact library status, immediately visible search field,
  a few optional query suggestions and photo results. No score table, location
  formula, model version, indexing counters or cloud-policy essay above the results.
- Library sheet: Photos authorization, saved coverage, index/resume and progress,
  explicit iCloud choice. Raw diagnostic information stays inside Details.
- Photos change observation starts only after authorization is available, avoiding
  an implicit permission popup before the user chooses to connect their library.
- Settings sheet: real result-count setting; location contribution and scores under
  Advanced; cache maintenance requires explicit confirmation. No cosmetic fake controls.
- Empty, searching, no-result, error and unavailable-image states have distinct,
  concise messages. A failed query is not presented as a successful zero-result query.

## Photos

- Top 3, larger-photo mode: rank 1 full-width 4:3, followed by two square tiles.
- More results: two-column 4:5 photo grid. Compact option: three-column square grid.
- Tiles clip within explicit bounds; original rank order is never changed by layout.
  Only a small rank indicator is overlaid; scores are available in Advanced.
- Tap a result for full-image fit on black, swipe through results in their existing
  order, pinch to zoom, double-tap to reset and share the displayed photo.
- Only the selected viewer page requests its large image. It uses the existing
  explicit network policy, and sharing rechecks access and strips source metadata.
- Pending thumbnails, revoked access and unavailable cloud previews do not show
  stale images from a prior request. No synthetic images enter production search.

## What this does NOT change

Model pair, preprocessing, preview-quality behavior, database/cache version, ranking,
query casing, default Top 3, location weight 0.6 and default-off networking remain
unchanged. The dog/Apple-pen regression is **not fixed or declared fixed** by this UI
release. Version 0.1.1/0.1.2 indexes remain reusable; do not clear/rebuild them merely
to install the redesign.

Keyboard Search and the inline button share focus dismissal. Keyboard Done and
navigation Done remain available, and dragging dismisses interactively. Search
completion brings the input/results area into view. No LAN debugging added.

## Validation

Existing mathematical, model, index, privacy and keyboard tests remain enabled.
New presentation tests use synthetic, clearly labelled scenes in the **test target
only**, rendering the actual generic photo-grid component at phone-sized viewports.
They cover three-result hero, twelve-result top/bottom and compact layout, home
states, missing assets, Dynamic Type and completed-query state transitions.

UI tests navigate the actual unauthorized simulator app, check search visibility at
launch and the absence of technical controls on Home, open/close Library/Settings,
expand Advanced and recheck keyboard behavior. Screenshot attachments are exported
from xcresult into a separate private review artifact. Compile/test success alone
is not a visual-layout approval: inspect a small contact sheet before delivery.

Run 35707292730 supplied 12 native UIReview screenshots, inspected together as a
small contact sheet. This confirmed bounded hero/2-column/3-column tiles, readable
empty/ready Home, missing-asset placeholders, reachable Library authorization and
normal/large-text Settings. All three navigation tests passed with no unsolicited
Photos permission popup after the observer-lifecycle fix. The new test drawings
are layout evidence, not real-library retrieval-quality evidence.

That run still failed one existing keyboard test: two characters were absent
after submit. Per-keystroke prefix assertions now identify input-stage loss before
any dismissal; tests neither replace/retry missing text nor loosen the exact
post-submit query check.

Final [run 35708194014](https://github.com/xwgnick/local-image-iq-ios/actions/runs/35708194014)
passed: 79 core, 113 App and all seven UI tests; one physical-protection App test
was explicitly skipped on simulator. All 16 presentation tests ran. Its 12 native
screenshots were also retrieved and visually reviewed in a 900×2720 contact sheet
under ignored `build/ui-review/35708194014/contact.jpg`. The source commit is
`b02357e128bc82313be48395dc5c3e9778c274eb`; the arm64 iPhoneOS Release IPA was built,
downloaded and size/SHA-256 verified. See [build record](BUILD_STATUS.md).

The screenshots validate these specific rendered layouts; they do not exercise
real-photo viewer paging/zoom/sharing end to end. Those paths are implemented,
compiled and statically reviewed, with physical-device validation still required.

Physical iPhone/iOS 26.6.1 results, accessibility behavior and the user's actual photo
collection still require device confirmation. Public/private photos are not uploaded
to CI for this layout task; review screenshots contain only test drawings or empty UI.