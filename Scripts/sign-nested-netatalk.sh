#!/bin/zsh
# Resign Netatalk dylibs nested in AFPBridge.framework with the current target identity.
# Ad-hoc nested libs cause FSKit extensions to abort at launch (Team ID mismatch / library validation).
set -euo pipefail

FRAMEWORK="${1:-}"
IDENTITY="${2:-${EXPANDED_CODE_SIGN_IDENTITY:-}}"

if [[ -z "$FRAMEWORK" || ! -d "$FRAMEWORK" ]]; then
  echo "usage: sign-nested-netatalk.sh <AFPBridge.framework> [codesign-identity]"
  exit 1
fi

NESTED="${FRAMEWORK}/Versions/A/Frameworks"
BIN="${FRAMEWORK}/Versions/A/AFPBridge"

if [[ ! -d "$NESTED" ]]; then
  echo "No nested Frameworks at $NESTED — nothing to sign"
  exit 0
fi

TEAM="${DEVELOPMENT_TEAM:-}"

# Prefer the identity Xcode chose for this target (must match DEVELOPMENT_TEAM).
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="${CODE_SIGN_IDENTITY:-}"
fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "Sign to Run Locally" ]]; then
  IDENTITY="-"
fi

resolve_team_identity() {
  local kind="$1"
  if [[ -z "$TEAM" ]]; then
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' -v kind="$kind" \
        'index($2, kind) { print $2; exit }'
    return
  fi
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v team="$TEAM" -v kind="$kind" \
      'index($2, kind) && index($2, "(" team ")") { print $2; exit }'
}

# Keep hex hashes from EXPANDED_CODE_SIGN_IDENTITY as-is.
# Resolve generic names, or ad-hoc when a team is set (nested libs must match the appex Team ID).
if [[ "$IDENTITY" == "Developer ID Application" || "$IDENTITY" == "Apple Development" ]]; then
  RESOLVED=$(resolve_team_identity "$IDENTITY")
  if [[ -z "$RESOLVED" ]]; then
    RESOLVED=$(resolve_team_identity "Apple Development")
  fi
  if [[ -z "$RESOLVED" ]]; then
    RESOLVED=$(resolve_team_identity "Developer ID Application")
  fi
  if [[ -n "$RESOLVED" ]]; then
    IDENTITY="$RESOLVED"
  fi
elif [[ "$IDENTITY" == "-" && -n "$TEAM" ]]; then
  RESOLVED=$(resolve_team_identity "Apple Development")
  if [[ -z "$RESOLVED" ]]; then
    RESOLVED=$(resolve_team_identity "Developer ID Application")
  fi
  if [[ -n "$RESOLVED" ]]; then
    IDENTITY="$RESOLVED"
  fi
fi

echo "Signing nested Netatalk libs in $NESTED with identity: $IDENTITY"

# Documents/File Provider injects FinderInfo xattrs; strip them or codesign rejects the bundle.
xattr -cr "$FRAMEWORK" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$FRAMEWORK" 2>/dev/null || true
find "$FRAMEWORK" -print0 2>/dev/null | xargs -0 -I{} xattr -d com.apple.FinderInfo {} 2>/dev/null || true

SIGN_FLAGS=(--force --timestamp=none --strip-disallowed-xattrs)
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_FLAGS+=(--options runtime)
fi

# Stable order: leaves first (intl/gpg-error), then gcrypt, then afpclient, then afpsl.
for lib in libintl.8.dylib libgpg-error.0.dylib libgcrypt.20.dylib libafpclient.1.dylib libafpsl.1.dylib; do
  if [[ -f "$NESTED/$lib" ]]; then
    chmod u+w "$NESTED/$lib" || true
    codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$NESTED/$lib"
  fi
done

if [[ -f "$BIN" ]]; then
  chmod u+w "$BIN" || true
  install_name_tool -add_rpath @loader_path/Frameworks "$BIN" 2>/dev/null || true
  codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$BIN"
fi

# Resign the framework bundle as a whole (deep).
codesign "${SIGN_FLAGS[@]}" --deep --sign "$IDENTITY" "$FRAMEWORK"

echo "Nested Netatalk signing complete"
codesign -dv --verbose=2 "$NESTED/libafpsl.1.dylib" 2>&1 | rg 'Authority|TeamIdentifier|Signature=' || true
