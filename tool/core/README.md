# Recon core download

`fetch_core.sh` downloads the prebuilt Recon core Android AAR from the
`bambolumba-y/recon-core` release matching `core.version` in
`dependencies.properties`, verifies it against the release's `SHA256SUMS`,
and extracts it into `android/app/libs/`, which is git-ignored and must
never be committed.

Run it from the `hiddify-app` repo root:

```sh
tool/core/fetch_core.sh
```
