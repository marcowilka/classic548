#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/netatalk-client"
PREFIX="$ROOT/Vendor/netatalk-prefix"
DESTDIR="$ROOT/Vendor/netatalk-destdir"
HELPERS="$ROOT/Helpers"
PATCHES="$ROOT/Vendor/patches/netatalk-client"

if [[ ! -d "$SRC/.git" && ! -f "$SRC/.git" ]]; then
  echo "error: Vendor/netatalk-client submodule missing." >&2
  echo "  Run: git submodule update --init --recursive" >&2
  exit 1
fi

# Ensure submodule matches the pinned commit, then apply ClassicAFP patches.
git -C "$ROOT" submodule update --init --recursive
git -C "$SRC" reset --hard HEAD
git -C "$SRC" clean -fd
if [[ -d "$PATCHES" ]]; then
  for patch in "$PATCHES"/*.patch(N); do
    echo "==> Applying $(basename "$patch")"
    git -C "$SRC" apply --check "$patch"
    git -C "$SRC" apply "$patch"
  done
fi

command -v meson >/dev/null || { echo "error: meson not found (brew install meson ninja)" >&2; exit 1; }
command -v ninja >/dev/null || { echo "error: ninja not found (brew install ninja)" >&2; exit 1; }
command -v pkg-config >/dev/null || { echo "error: pkg-config not found" >&2; exit 1; }
[[ -d /opt/homebrew/opt/libgcrypt/lib ]] || { echo "error: libgcrypt not found (brew install libgcrypt)" >&2; exit 1; }

# Match the active macOS SDK (fatal_warnings treats min-version skew as error).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.2}"
export CFLAGS="${CFLAGS:-} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export LDFLAGS="${LDFLAGS:-} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"

meson setup "$SRC/build" "$SRC" \
  -Dbuildtype=release \
  -Denable-fuse=false \
  -Denable-docs=false \
  -Dprefix="$PREFIX" \
  --reconfigure || meson setup "$SRC/build" "$SRC" \
  -Dbuildtype=release \
  -Denable-fuse=false \
  -Denable-docs=false \
  -Dprefix="$PREFIX"

meson compile -C "$SRC/build"
rm -rf "$DESTDIR"
meson install -C "$SRC/build" --destdir "$DESTDIR"

STAGE="$DESTDIR$PREFIX"
mkdir -p "$HELPERS"
cp -L "$STAGE/bin/afpsld" "$HELPERS/"
cp -L "$STAGE/lib/libafpsl.1.dylib" "$HELPERS/"
cp -L "$STAGE/lib/libafpclient.1.dylib" "$HELPERS/"
cp -L /opt/homebrew/opt/libgcrypt/lib/libgcrypt.20.dylib "$HELPERS/"
cp -L /opt/homebrew/opt/libgpg-error/lib/libgpg-error.0.dylib "$HELPERS/"
cp -L /opt/homebrew/opt/gettext/lib/libintl.8.dylib "$HELPERS/"
mkdir -p "$ROOT/AFPBridge/include/netatalk-client"
cp "$STAGE/include/netatalk-client/"*.h "$ROOT/AFPBridge/include/netatalk-client/"

# Keep ClassicAFP helper entitlements if present.
[[ -f "$HELPERS/afpsld.entitlements" ]] || cat > "$HELPERS/afpsld.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
EOF

chmod u+w "$HELPERS"/*

install_name_tool -id @rpath/libafpclient.1.dylib "$HELPERS/libafpclient.1.dylib"
install_name_tool -id @rpath/libafpsl.1.dylib "$HELPERS/libafpsl.1.dylib"
install_name_tool -id @rpath/libgcrypt.20.dylib "$HELPERS/libgcrypt.20.dylib"
install_name_tool -id @rpath/libgpg-error.0.dylib "$HELPERS/libgpg-error.0.dylib"
install_name_tool -id @rpath/libintl.8.dylib "$HELPERS/libintl.8.dylib"

install_name_tool -change "$PREFIX/lib/libafpclient.1.dylib" @rpath/libafpclient.1.dylib "$HELPERS/afpsld" || true
install_name_tool -change "$PREFIX/lib/libafpclient.1.dylib" @rpath/libafpclient.1.dylib "$HELPERS/libafpsl.1.dylib" || true
install_name_tool -change /opt/homebrew/opt/libgcrypt/lib/libgcrypt.20.dylib @rpath/libgcrypt.20.dylib "$HELPERS/libafpclient.1.dylib" || true
install_name_tool -change /opt/homebrew/opt/libgpg-error/lib/libgpg-error.0.dylib @rpath/libgpg-error.0.dylib "$HELPERS/libgcrypt.20.dylib" || true
install_name_tool -change /opt/homebrew/opt/gettext/lib/libintl.8.dylib @rpath/libintl.8.dylib "$HELPERS/libgpg-error.0.dylib" || true
install_name_tool -add_rpath @executable_path "$HELPERS/afpsld" || true

# Rewrite any leftover absolute Homebrew/Cellar deps to @rpath.
HELPERS="$HELPERS" python3 - <<'PY'
import os, subprocess
helpers = os.environ["HELPERS"]
mapping = {
    "libgcrypt.20.dylib": "@rpath/libgcrypt.20.dylib",
    "libgpg-error.0.dylib": "@rpath/libgpg-error.0.dylib",
    "libintl.8.dylib": "@rpath/libintl.8.dylib",
    "libafpclient.1.dylib": "@rpath/libafpclient.1.dylib",
}
for name in ["afpsld", "libafpsl.1.dylib", "libafpclient.1.dylib", "libgcrypt.20.dylib", "libgpg-error.0.dylib"]:
    path = os.path.join(helpers, name)
    if not os.path.exists(path):
        continue
    out = subprocess.check_output(["otool", "-L", path], text=True)
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" ", 1)[0]
        base = os.path.basename(dep)
        if base in mapping and not dep.startswith("@") and not dep.startswith("/usr/lib"):
            subprocess.check_call(["install_name_tool", "-change", dep, mapping[base], path])
PY

codesign -f -s - "$HELPERS"/* || true
echo "Staged helpers in $HELPERS"
