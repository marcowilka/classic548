# Shared Developer ID + provisioning-profile helpers for ClassicAFP.
# Sourced by build-macos-dmg.sh and export-developer-id.sh.
#
# Configure via environment or a gitignored Scripts/local-signing.env:
#   SIGNING_DIR          directory with profiles + notary key
#   SIGN_IDENTITY        Developer ID Application identity string
#   DEVELOPMENT_TEAM     Apple team ID
#   NOTARY_KEY_PATH      path to App Store Connect API .p8
#   NOTARY_KEY_ID        key ID
#   NOTARY_ISSUER        issuer UUID
#   CLASSICAFP_APP_PROFILE_NAME / CLASSICAFP_APPEX_PROFILE_NAME  (portal profile names)

_LIB_SIGNING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${_LIB_SIGNING_DIR}/local-signing.env" ]]; then
  # shellcheck disable=SC1091
  source "${_LIB_SIGNING_DIR}/local-signing.env"
fi

SIGNING_DIR="${SIGNING_DIR:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

CLASSICAFP_APP_BUNDLE_ID="de.marcowilka.classic548"
CLASSICAFP_APPEX_BUNDLE_ID="de.marcowilka.classic548.AFPFS"

CLASSICAFP_APP_PROFILE_NAME="${CLASSICAFP_APP_PROFILE_NAME:-Classic AFP 548}"
CLASSICAFP_APPEX_PROFILE_NAME="${CLASSICAFP_APPEX_PROFILE_NAME:-Classic AFP AFPFS}"

CLASSICAFP_APP_PROFILE_FILE=""
CLASSICAFP_APPEX_PROFILE_FILE=""
if [[ -n "${SIGNING_DIR}" ]]; then
  CLASSICAFP_APP_PROFILE_FILE="${SIGNING_DIR}/ClassicAFP_Developer_ID.provisionprofile"
  CLASSICAFP_APPEX_PROFILE_FILE="${SIGNING_DIR}/ClassicAFP_AFPFS_Developer_ID.provisionprofile"
fi

require_signing_env() {
  local missing=0
  if [[ -z "${SIGNING_DIR}" ]]; then
    echo "error: SIGNING_DIR is not set (use Scripts/local-signing.env)." >&2
    missing=1
  fi
  if [[ -z "${DEVELOPMENT_TEAM}" ]]; then
    echo "error: DEVELOPMENT_TEAM is not set." >&2
    missing=1
  fi
  if [[ -z "${SIGN_IDENTITY}" ]]; then
    echo "error: SIGN_IDENTITY is not set." >&2
    missing=1
  fi
  return "${missing}"
}

_classic548_profile_uuid() {
  security cms -D -i "$1" | plutil -extract UUID raw -
}

_classic548_install_one_profile() {
  local src="$1"
  local uuid dest
  uuid="$(_classic548_profile_uuid "$src")"
  if [[ -z "${uuid}" || "${uuid}" == "null" ]]; then
    echo "error: could not read UUID from profile file" >&2
    return 1
  fi
  for dest in \
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
  do
    mkdir -p "${dest}"
    cp -f "${src}" "${dest}/${uuid}.provisionprofile"
  done
  echo "    installed $(basename "${src}")"
}

# Copy Developer ID profiles into Xcode's search path.
install_classic548_provisioning_profiles() {
  local required="${1:-1}"
  if [[ -z "${SIGNING_DIR}" ]]; then
    echo "error: SIGNING_DIR is not set." >&2
    return 1
  fi
  echo "==> Installing Developer ID provisioning profiles"
  if [[ ! -f "${CLASSICAFP_APP_PROFILE_FILE}" ]]; then
    echo "    missing app provisioning profile in SIGNING_DIR" >&2
    if [[ "${required}" -ne 0 ]]; then
      return 1
    fi
    return 0
  fi
  _classic548_install_one_profile "${CLASSICAFP_APP_PROFILE_FILE}"

  if [[ -f "${CLASSICAFP_APPEX_PROFILE_FILE}" ]]; then
    _classic548_install_one_profile "${CLASSICAFP_APPEX_PROFILE_FILE}"
  else
    echo "    note: no Appex profile in SIGNING_DIR yet"
  fi
}
