#!/usr/bin/env bash
# Build ClassicAFP (macOS) Release, sign with Developer ID, package DMG, notarize + staple.
#
# Usage:
#   ./Scripts/build-macos-dmg.sh
#   ./Scripts/build-macos-dmg.sh --skip-build
#   ./Scripts/build-macos-dmg.sh --skip-notarize
#
# Requires Scripts/local-signing.env (gitignored) or equivalent environment:
#   SIGNING_DIR, DEVELOPMENT_TEAM, SIGN_IDENTITY,
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#
# Outputs: dist/ClassicAFP-<version>-mac.dmg
# Work dir: ~/Library/Caches/classic548-release (override with CLASSIC548_BUILD_WORK)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${ROOT}/ClassicAFP.xcodeproj"
SCHEME="ClassicAFP"
CONFIG="Release"
WORK="${CLASSIC548_BUILD_WORK:-${HOME}/Library/Caches/classic548-release}"
DERIVED="${WORK}/DerivedData-mac"
DIST="${ROOT}/dist"
ARCHIVE="${WORK}/ClassicAFP.xcarchive"
EXPORT_DIR="${WORK}/export"
STAGE="${WORK}/dmg-stage"
VOL_NAME="ClassicAFP"
BUNDLE_ID="de.marcowilka.classic548"
APPEX_BUNDLE_ID="de.marcowilka.classic548.AFPFS"

# shellcheck source=lib-signing.sh
source "${SCRIPT_DIR}/lib-signing.sh"
require_signing_env

NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
if [[ -z "${NOTARY_ISSUER:-}" && -n "${SIGNING_DIR}" && -f "${SIGNING_DIR}/notary-issuer.txt" ]]; then
  NOTARY_ISSUER="$(tr -d '[:space:]' < "${SIGNING_DIR}/notary-issuer.txt")"
fi
NOTARY_ISSUER="${NOTARY_ISSUER:-}"

SKIP_BUILD=0
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
  esac
done

cd "${ROOT}"
mkdir -p "${DIST}" "${WORK}"
export COPYFILE_DISABLE=1

strip_codesign_xattrs() {
  local target="$1"
  [[ -e "${target}" ]] || return 0
  xattr -cr "${target}" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "${target}" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "${target}" 2>/dev/null || true
  xattr -d com.apple.quarantine "${target}" 2>/dev/null || true
}

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  echo "==> Generating app icon"
  "${SCRIPT_DIR}/generate-app-icon.sh"
  strip_codesign_xattrs "${ROOT}/Resources"

  if command -v xcodegen >/dev/null 2>&1; then
    echo "==> xcodegen generate"
    xcodegen generate
  else
    echo "warning: xcodegen not found; using existing ${PROJECT}" >&2
  fi

  EXPORT_PLIST="${DIST}/ExportOptions-DeveloperID.plist"
  # Appex profile only listed when the file is present (portal may lag).
  APPEX_PROFILE_ENTRY=""
  if [[ -f "${CLASSICAFP_APPEX_PROFILE_FILE}" ]]; then
    APPEX_PROFILE_ENTRY="
		<key>${APPEX_BUNDLE_ID}</key>
		<string>${CLASSICAFP_APPEX_PROFILE_NAME}</string>"
  fi
  cat > "${EXPORT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${DEVELOPMENT_TEAM}</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>${BUNDLE_ID}</key>
		<string>${CLASSICAFP_APP_PROFILE_NAME}</string>${APPEX_PROFILE_ENTRY}
	</dict>
</dict>
</plist>
EOF

  echo "==> Installing provisioning profiles"
  install_classic548_provisioning_profiles 1

  echo "==> xcodebuild archive ${SCHEME}"
  echo "    derivedData: ${DERIVED}"
  echo "    profile: ${CLASSICAFP_APP_PROFILE_NAME}"
  rm -rf "${ARCHIVE}" "${EXPORT_DIR}" "${DERIVED}"
  set +e
  # Archive with Automatic + Apple Development. Developer ID + profiles are
  # applied only at exportArchive (manual). Mixing Developer ID identity into
  # an Automatic archive fails with "conflicting provisioning settings".
  xcodebuild archive \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -derivedDataPath "${DERIVED}" \
    -archivePath "${ARCHIVE}" \
    -destination 'generic/platform=macOS' \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS='arm64' \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY='Apple Development' \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    PROVISIONING_PROFILE= \
    PROVISIONING_PROFILE_SPECIFIER= \
    OTHER_CODE_SIGN_FLAGS='--timestamp' \
    ENABLE_HARDENED_RUNTIME=YES \
    > "${DIST}/build-macos.log" 2>&1
  archive_status=$?
  set -e
  if [[ "${archive_status}" -ne 0 ]]; then
    tail -n 80 "${DIST}/build-macos.log"
    echo "error: archive failed (exit ${archive_status}) — see ${DIST}/build-macos.log" >&2
    exit "${archive_status}"
  fi

  echo "==> xcodebuild -exportArchive (Developer ID)"
  mkdir -p "${EXPORT_DIR}"
  set +e
  xcodebuild -exportArchive \
    -archivePath "${ARCHIVE}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_PLIST}" \
    >> "${DIST}/build-macos.log" 2>&1
  export_status=$?
  set -e
  if [[ "${export_status}" -ne 0 ]]; then
    APP_FROM_ARCHIVE="${ARCHIVE}/Products/Applications/ClassicAFP.app"
    if [[ -d "${APP_FROM_ARCHIVE}" ]]; then
      echo "warning: exportArchive failed; using archive Products copy" >&2
      rm -rf "${EXPORT_DIR}/ClassicAFP.app"
      ditto --norsrc --noextattr "${APP_FROM_ARCHIVE}" "${EXPORT_DIR}/ClassicAFP.app"
    else
      tail -n 80 "${DIST}/build-macos.log"
      echo "error: exportArchive failed (exit ${export_status}) — see ${DIST}/build-macos.log" >&2
      exit "${export_status}"
    fi
  fi
fi

APP_SRC="${EXPORT_DIR}/ClassicAFP.app"
if [[ ! -d "${APP_SRC}" ]]; then
  APP_SRC="$(find "${EXPORT_DIR}" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "${APP_SRC}" || ! -d "${APP_SRC}" ]]; then
  echo "error: exported .app not found under ${EXPORT_DIR}" >&2
  exit 1
fi

strip_codesign_xattrs "${APP_SRC}"

marketing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_SRC}/Contents/Info.plist" 2>/dev/null || true)"
build_num="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_SRC}/Contents/Info.plist" 2>/dev/null || true)"
marketing="${marketing:-1.0}"
build_num="${build_num:-0}"

DMG_VERSIONED="${DIST}/ClassicAFP-${marketing}-mac.dmg"
DMG_RW="${WORK}/ClassicAFP-rw.dmg"
DMG_MOUNT="/Volumes/${VOL_NAME}"

echo "==> ClassicAFP macOS DMG (Developer ID)"
echo "    version ${marketing} (build ${build_num})"
echo "    identity: ${SIGN_IDENTITY}"
echo "    bundle:   ${BUNDLE_ID}"

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "${APP_SRC}" || true
codesign -dv --verbose=2 "${APP_SRC}" 2>&1 | grep -E 'Authority|Identifier|TeamIdentifier|Signature' || true

APPEX="${APP_SRC}/Contents/Extensions/AFPFS.appex"
if [[ ! -d "${APPEX}" ]]; then
  echo "warning: AFPFS.appex missing under ${APPEX}" >&2
fi

rm -rf "${STAGE}"
mkdir -p "${STAGE}"

DMG_BG_DIR="${SCRIPT_DIR}/dmg"
DMG_BG="${DMG_BG_DIR}/background.png"

if [[ ! -f "${DMG_BG}" ]]; then
  echo "==> Generating DMG background"
  swift "${DMG_BG_DIR}/generate_background.swift" "${DMG_BG}"
fi

echo "==> Staging DMG contents"
ditto --norsrc --noextattr "${APP_SRC}" "${STAGE}/ClassicAFP.app"
strip_codesign_xattrs "${STAGE}/ClassicAFP.app"
ln -s /Applications "${STAGE}/Applications"

echo "==> Creating writable DMG for Finder layout"
rm -f "${DMG_RW}" "${DMG_VERSIONED}"
if [[ -d "${DMG_MOUNT}" ]]; then
  hdiutil detach "${DMG_MOUNT}" -force >/dev/null 2>&1 || true
fi

hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "${DMG_RW}"
rm -rf "${STAGE}"

echo "==> Mounting and applying drag-and-drop layout"
MOUNT_DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "${DMG_RW}" | awk 'END { print $1 }')"
for _ in $(seq 1 40); do
  [[ -d "${DMG_MOUNT}" ]] && break
  sleep 0.25
done
if [[ ! -d "${DMG_MOUNT}" ]]; then
  echo "error: DMG did not mount at ${DMG_MOUNT}" >&2
  hdiutil detach "${MOUNT_DEVICE}" -force >/dev/null 2>&1 || true
  exit 1
fi

mkdir -p "${DMG_MOUNT}/.background"
cp -f "${DMG_BG}" "${DMG_MOUNT}/.background/background.png"
SetFile -a V "${DMG_MOUNT}/.background" 2>/dev/null \
  || chflags hidden "${DMG_MOUNT}/.background" 2>/dev/null \
  || true

BG_POSIX="${DMG_MOUNT}/.background/background.png"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "${VOL_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    try
      set text size of opts to 12
    end try
    set background picture of opts to POSIX file "${BG_POSIX}"
    set position of item "ClassicAFP.app" of container window to {160, 145}
    set position of item "Applications" of container window to {500, 145}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sleep 1
sync
hdiutil detach "${MOUNT_DEVICE}" || hdiutil detach "${DMG_MOUNT}" -force

echo "==> Compressing ${DMG_VERSIONED}"
rm -f "${DMG_VERSIONED}"
hdiutil convert "${DMG_RW}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "${DMG_VERSIONED}"
rm -f "${DMG_RW}"

echo "==> Codesigning DMG"
codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_VERSIONED}"

if [[ "${SKIP_NOTARIZE}" -eq 0 ]]; then
  if [[ -z "${NOTARY_ISSUER}" ]]; then
    echo "error: NOTARY_ISSUER is not set." >&2
    exit 1
  fi
  if [[ -z "${NOTARY_KEY_PATH}" || ! -f "${NOTARY_KEY_PATH}" ]]; then
    echo "error: NOTARY_KEY_PATH is missing or not a file." >&2
    exit 1
  fi
  if [[ -z "${NOTARY_KEY_ID}" ]]; then
    echo "error: NOTARY_KEY_ID is not set." >&2
    exit 1
  fi

  echo "==> Submitting to Apple notary service"
  xcrun notarytool submit "${DMG_VERSIONED}" \
    --key "${NOTARY_KEY_PATH}" \
    --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER}" \
    --wait

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "${DMG_VERSIONED}"
  xcrun stapler validate "${DMG_VERSIONED}"

  echo "==> Gatekeeper check"
  spctl -a -vv -t install "${DMG_VERSIONED}" || true
fi

echo "==> Done"
echo "    ${DMG_VERSIONED}"
echo "    open ${DMG_VERSIONED}"
