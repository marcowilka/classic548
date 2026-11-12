#!/usr/bin/env bash
# Build macOS AppIcon.appiconset + AppIcon.icns from repo-root appicon.png.
# Applies rounded corners (radius 22% of side).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/appicon.png}"
ASSETS="$ROOT/Resources/Assets.xcassets"
OUT="$ASSETS/AppIcon.appiconset"
ICNS="$ROOT/Resources/AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
  # Accept AppIcon.png as alternate source name.
  if [[ -f "$ROOT/AppIcon.png" ]]; then
    SRC="$ROOT/AppIcon.png"
  else
    echo "Missing source icon: $ROOT/appicon.png" >&2
    exit 1
  fi
fi

mkdir -p "$OUT"
MASTER="$OUT/icon_512x512@2x.png"
swift "${ROOT}/Scripts/generate-app-icon.swift" "$SRC" "$MASTER"

declare -a SPECS=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
)

for spec in "${SPECS[@]}"; do
  size="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$size" "$size" "$MASTER" --out "$OUT/$name" >/dev/null
done

cat > "$OUT/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

cat > "$ASSETS/Contents.json" <<'EOF'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$OUT/icon_16x16.png" "$ICONSET/icon_16x16.png"
cp "$OUT/icon_16x16@2x.png" "$ICONSET/icon_16x16@2x.png"
cp "$OUT/icon_32x32.png" "$ICONSET/icon_32x32.png"
cp "$OUT/icon_32x32@2x.png" "$ICONSET/icon_32x32@2x.png"
cp "$OUT/icon_128x128.png" "$ICONSET/icon_128x128.png"
cp "$OUT/icon_128x128@2x.png" "$ICONSET/icon_128x128@2x.png"
cp "$OUT/icon_256x256.png" "$ICONSET/icon_256x256.png"
cp "$OUT/icon_256x256@2x.png" "$ICONSET/icon_256x256@2x.png"
cp "$OUT/icon_512x512.png" "$ICONSET/icon_512x512.png"
cp "$OUT/icon_512x512@2x.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$(dirname "$ICONSET")"

xattr -cr "$ASSETS" 2>/dev/null || true
xattr -cr "$ICNS" 2>/dev/null || true

echo "Wrote AppIcon.appiconset → $OUT"
echo "Wrote AppIcon.icns ($(wc -c < "$ICNS" | tr -d ' ') bytes) → $ICNS"
