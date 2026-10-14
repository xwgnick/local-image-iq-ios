# TestFlight: first official signed build

Approved identity: `app.piankexun.ios`, marketing version `1.0`, build `46`.
The existing unsigned `0.16.5/45` development delivery is unchanged.

## Manual workflow

Run **TestFlight — signed 1.0 build46** from `main` in
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
re-upload build 46. Model conversion, native validation and actual Apple upload
must finish before declaring this build delivered.

No tester invitations, external beta review, App Review submission, price
changes or public App Store release are performed. Once processing is valid,
complete any Apple export-compliance questions and enable internal testing in
App Store Connect. Paid-app agreements and mainland distribution compliance
remain separate public-release tasks.

Do not uninstall the existing sideloaded app. A different Bundle ID/signing team
may install separately; preservation of that app's local index is not guaranteed
by installing the new TestFlight identity.

Current status: implementation and cloud validation pending; no TestFlight
upload is claimed by this document.

Run `38552330364` passed real macOS signing preflight, Core 79, and App
2145 (2144 passed / 1 existing device-only skip / 0 failures). UI ran 23 with
1 existing skip and 1 failure: after restart the location switch's coordinate
tap did not turn it off. No archive/upload was attempted. The UI test now
targets the sole nested native switch with an actual thumb drag; desired-value
and ON/OFF restart persistence assertions remain unchanged.

Targeted run `38560413931`, source
`ce94543379bf3569b7891de42aa1686e7f28f22c`, executed
`testLocationEnhancementIntroductionSettingsAndRestartPersistence` on the iOS
simulator: 1 test passed, 0 failures, no skip. The full signed-delivery rerun
remains pending; this targeted result alone does not claim an Apple upload.
