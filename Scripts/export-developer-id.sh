#!/usr/bin/env bash
# Thin wrapper: build + export Developer ID app, then notarize the .app (zip).
# Prefer ./Scripts/build-macos-dmg.sh for distribution (notarized DMG).
#
# Usage:
#   ./Scripts/export-developer-id.sh
#   ./Scripts/export-developer-id.sh --skip-notarize
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

# shellcheck source=lib-signing.sh
source "${SCRIPT_DIR}/lib-signing.sh"
require_signing_env

WORK="${CLASSIC548_BUILD_WORK:-${HOME}/Library/Caches/classic548-release}"
EXPORT_DIR="${WORK}/export"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
if [[ -z "${NOTARY_ISSUER:-}" && -n "${SIGNING_DIR}" && -f "${SIGNING_DIR}/notary-issuer.txt" ]]; then
  NOTARY_ISSUER="$(tr -d '[:space:]' < "${SIGNING_DIR}/notary-issuer.txt")"
fi
NOTARY_ISSUER="${NOTARY_ISSUER:-}"

SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
  esac
done

echo "==> Building via build-macos-dmg.sh --skip-notarize (produces exported .app)"
"${SCRIPT_DIR}/build-macos-dmg.sh" --skip-notarize

APP="${EXPORT_DIR}/ClassicAFP.app"
if [[ ! -d "${APP}" ]]; then
  echo "error: expected exported app under work dir" >&2
  exit 1
fi

mkdir -p "${ROOT}/build/export"
rm -rf "${ROOT}/build/export/ClassicAFP.app"
ditto --norsrc --noextattr "${APP}" "${ROOT}/build/export/ClassicAFP.app"

if [[ "${SKIP_NOTARIZE}" -ne 0 ]]; then
  echo "Done (skip notarize): ${ROOT}/build/export/ClassicAFP.app"
  exit 0
fi

if [[ -z "${NOTARY_ISSUER}" || -z "${NOTARY_KEY_PATH}" || ! -f "${NOTARY_KEY_PATH}" || -z "${NOTARY_KEY_ID}" ]]; then
  echo "error: notary environment incomplete (NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER)." >&2
  exit 1
fi

ZIP="${ROOT}/build/export/ClassicAFP.zip"
rm -f "${ZIP}"
ditto -c -k --keepParent "${ROOT}/build/export/ClassicAFP.app" "${ZIP}"

echo "==> Notarizing zip"
xcrun notarytool submit "${ZIP}" \
  --key "${NOTARY_KEY_PATH}" \
  --key-id "${NOTARY_KEY_ID}" \
  --issuer "${NOTARY_ISSUER}" \
  --wait
xcrun stapler staple "${ROOT}/build/export/ClassicAFP.app"

echo "Done: ${ROOT}/build/export/ClassicAFP.app"
echo "Prefer ./Scripts/build-macos-dmg.sh for a notarized installer DMG."
