#!/bin/zsh
# Regenerates Resources/AppIcon.icns and the Chrome extension icons from Scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift Scripts/make-icon.swift "$TMP/app.png"
swift Scripts/make-icon.swift "$TMP/plain.png" plain

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET" Resources ChromeExtension/icons
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/app.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/app.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
for s in 16 32 48 128; do
    sips -z $s $s "$TMP/plain.png" --out "ChromeExtension/icons/icon$s.png" >/dev/null
done
echo "Wrote Resources/AppIcon.icns and ChromeExtension/icons/"
