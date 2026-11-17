#!/bin/zsh
# Builds build/BookmarkBridge.app from the Swift package and installs it to
# /Applications (override with INSTALL_DIR=/some/folder; INSTALL_DIR= skips it).
# The app should always run from that one place: Full Disk Access, Launch at Login
# and Chrome's helper registration all point at the app's location.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/BookmarkBridge.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BookmarkBridge" "$BIN/bookmarkbridge-host" "$APP/Contents/MacOS/"
cp -R ChromeExtension "$APP/Contents/Resources/ChromeExtension"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.k-u-knt.BookmarkBridge</string>
    <key>CFBundleName</key><string>BookmarkBridge</string>
    <key>CFBundleDisplayName</key><string>BookmarkBridge</string>
    <key>CFBundleExecutable</key><string>BookmarkBridge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# macOS ties Full Disk Access to the app's signature. Signed with the local
# certificate "BookmarkBridge Local Signing" (a self-signed certificate in the login
# keychain), every build counts as the same app and the grant survives rebuilds.
# Without that certificate the build falls back to an ad-hoc signature, which works
# but needs Full Disk Access granted again after each rebuild.
SIGN_ID="BookmarkBridge Local Signing"
if ! security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    echo "No \"$SIGN_ID\" certificate found: using an ad-hoc signature."
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" --identifier io.github.k-u-knt.BookmarkBridge.host "$APP/Contents/MacOS/bookmarkbridge-host"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP"

INSTALL_DIR="${INSTALL_DIR-/Applications}"
if [[ -n "$INSTALL_DIR" ]]; then
    pkill -x BookmarkBridge 2>/dev/null || true
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/BookmarkBridge.app"
    ditto "$APP" "$INSTALL_DIR/BookmarkBridge.app"
    echo "Installed $INSTALL_DIR/BookmarkBridge.app"
fi
