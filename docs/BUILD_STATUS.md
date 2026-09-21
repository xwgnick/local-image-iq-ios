# First cloud build — 2026-09-22

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

## Next user-controlled step

Provide an approved **organization-owned private repository** with macOS hosted
runner access, or arrange an approved self-hosted Mac. Do not make this repository
public, migrate company content outside the enterprise, enable billing, or change
organization policies just to bypass the restriction. No transfer or replacement
repository has been created by the assistant.

After the target and runner access are established, push this same isolated source
and run the model-free workflow first. Swift compilation, XCTest, Core ML export,
model parity, simulator and physical-device behavior are still **not verified**.