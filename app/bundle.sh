#!/bin/bash
# Turns the compiled binary into "CosmoGrav.app" and zips it. Runs on the macOS build machine.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat app/VERSION)
APP="dist/CosmoGrav.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/.build/apple/Products/Release/CosmoGrav "$APP/Contents/MacOS/"
sed "s/@VERSION@/$VERSION/g" app/Info.plist > "$APP/Contents/Info.plist"

# App icon from assets/icon.png.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size assets/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so Apple Silicon Macs will run it.
codesign --force --deep --sign - "$APP"
(cd dist && ditto -c -k --keepParent "CosmoGrav.app" CosmoGrav.zip)
echo "Built dist/CosmoGrav.zip (version $VERSION)"
