# Preview-first indexing · 0.1.1 (2)

## Real-device problem

The user successfully installed and ran the app on iPhone 15 / iOS 26.6.1.
Screenshots showed full Photos authorization and 7,994 checked images, but only
114 encoded, with 7,880 unavailable. Last error: PHPhotosErrorDomain 3164
(`networkAccessRequired`). That is evidence about the last failure, not a log
proving every unavailable asset failed for the same reason.

The first implementation requested original/largest image data using
`requestImageDataAndOrientation` before shrinking it for the 224-pixel encoder.
With network access disabled, optimized iCloud libraries often cannot satisfy
that request even when useful local previews exist. The generic-error branch
also ran before cloud classification, producing a misleading zero cloud-skipped
count. Simulator encoder tests did not exercise this real-library condition.

## New source path

1. Request `requestImage`, preserving aspect ratio with a target short side of
   224 pixels. No indexing call to original-data APIs and no original-data fallback.
2. First request always disables network, uses asynchronous `fastFormat`, and
   accepts usable reduced-quality images. `fastFormat` may complete only once;
   a degraded result must not be discarded waiting for another callback.
3. Feed immutable CGImage + its actual orientation directly into the existing
   normalization/encoder; do not JPEG/PNG re-encode the preview.
4. If no local representation exists and the user explicitly enables network,
   request the same target representation with network allowed. Do not repeat
   authentication, permission, cancellation or unrelated errors as cloud requests.
5. Offline 3164 is `need network`; real errors remain `unavailable`. Counters also
   distinguish local, reduced and online-fallback previews. The latter indicates
   the network-allowed request stage, not measured network transfer.

Network remains off by default. The user does **not** need to change iCloud settings
to “Download and Keep Originals” or download the entire library. PhotoKit controls
which underlying resource it fetches: a small target is not a guarantee of small
network transfer, and local preview availability for every cloud asset is not
guaranteed. Reduced inputs may change ranking; neither synthetic tests nor successful
compilation establish quality or coverage for this user's actual optimized library.

## Upgrade and persistence

App version 0.1.1 (build 2), input policy `photokit-preview-v1`. The photo-cache key
adds the input-policy version to the unchanged model identity. Old original-data
vectors are not silently reused as preview vectors. The first new scan rebuilds
the active index, without asking the user to delete the app or original photos;
completed new records are reusable on subsequent runs. Existing old rows remain
until replaced or normal authorization/deletion reconciliation removes them.

Current reduced previews are cached as the completed representation for this input
policy. Automatic quality promotion is not implemented; do not imply that toggling
network alone upgrades already indexed reduced previews to full quality.

The database still stores no original images or GPS. Source counters are per-run
diagnostics, not a persistent per-photo quality log. Full offline geography remains
a separate missing resource; this change does not invent location labels.

## Verification

- Request policy tests use injected callbacks: local-first even with network enabled,
  degraded single-callback success, usable pixels alongside 3164/cloud flags,
  missing-resource fallback, genuine errors, orientation and cancellation races.
- Worker tests cover preview-only encoding, committed source counts, raw 3164,
  active-version filtering, rebuild/reuse, canceled scans and authorization changes.
- Native model tests compare direct preview tensors, oriented/pre-scaled synthetic
  images, and real encoder outputs to the pinned pair. These are not cloud-library tests.
- UI layout remains unchanged; descriptions and partial-coverage status were corrected.

After installing over the existing app using the same signing identity, keep the
network switch **off**, run Index / resume, and inspect authorized/indexed counts
plus local/reduced/need-network/unavailable totals. Do not promise a specific
coverage percentage before this test. If results still lack many images, collect
the new counters/errors before changing network policy or requesting originals.

References: [Apple image requests](https://developer.apple.com/documentation/photos/phimagemanager/requestimage(for:targetsize:contentmode:options:resulthandler:)),
[fastFormat single-callback behavior](https://developer.apple.com/documentation/photos/phimagerequestoptionsdeliverymode/fastformat),
[networkAccessRequired](https://developer.apple.com/documentation/photos/phphotoserror-swift.struct/code/networkaccessrequired).