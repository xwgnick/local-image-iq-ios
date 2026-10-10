# 0.15.0 / build38 — approved refinement implementation

Status: implementation and targeted native validation in progress. No build38 IPA has been released. Build37 remains the delivered package. User approved the comprehensive cleanup design and V5 hero on 2026-10-10, then added three native requirements.

## Included scope

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