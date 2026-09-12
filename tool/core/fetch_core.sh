#!/usr/bin/env bash
# Downloads the Recon core Android AAR for local builds, verifies it against
# the release's SHA256SUMS, and extracts it into android/app/libs/. Run from
# the hiddify-app repo root: tool/core/fetch_core.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CORE_VERSION=$(tr -d '\r' < dependencies.properties | sed -n 's/^core.version=//p')
if [ -z "$CORE_VERSION" ]; then
  echo "fetch_core.sh: could not read core.version from dependencies.properties" >&2
  exit 1
fi

ARCHIVE="hiddify-lib-android.tar.gz"
CHECKSUMS="SHA256SUMS"
RELEASE_URL="https://github.com/bambolumba-y/recon-core/releases/download/v${CORE_VERSION}"
LIBS_DIR="android/app/libs"

# Prefer GNU coreutils' sha256sum; fall back to macOS/BSD's shasum -a 256.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "fetch_core.sh: neither sha256sum nor shasum is available to verify the checksum" >&2
    exit 1
  fi
}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "fetch_core.sh: downloading ${ARCHIVE} for recon-core v${CORE_VERSION}"
curl -fL "${RELEASE_URL}/${ARCHIVE}" -o "${WORKDIR}/${ARCHIVE}"
curl -fL "${RELEASE_URL}/${CHECKSUMS}" -o "${WORKDIR}/${CHECKSUMS}"

EXPECTED=$(grep -E "[[:space:]]\*?${ARCHIVE}\$" "${WORKDIR}/${CHECKSUMS}" | awk '{print $1}')
if [ -z "$EXPECTED" ]; then
  echo "fetch_core.sh: ${ARCHIVE} not listed in ${CHECKSUMS}" >&2
  exit 1
fi

ACTUAL=$(sha256_of "${WORKDIR}/${ARCHIVE}")
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "fetch_core.sh: checksum mismatch for ${ARCHIVE}" >&2
  echo "fetch_core.sh: expected ${EXPECTED}, got ${ACTUAL}" >&2
  exit 1
fi

mkdir -p "${LIBS_DIR}"
tar xz -C "${LIBS_DIR}/" -f "${WORKDIR}/${ARCHIVE}"
ls -la "${LIBS_DIR}"
echo "fetch_core.sh: verified checksum and extracted ${ARCHIVE} into ${LIBS_DIR}"
