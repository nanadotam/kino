#!/bin/bash
# Builds dist/Kino.app (universal: Apple Silicon + Intel) and dist/Kino.dmg.
# Usage: ./scripts/build-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Kino
VERSION=$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)
DIST=dist
BUNDLE="$DIST/$APP.app"

echo "==> Building release binaries"
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
export MACOSX_DEPLOYMENT_TARGET=10.15
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

echo "==> Assembling $BUNDLE"
rm -rf "$DIST" && mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
lipo -create -output "$BUNDLE/Contents/MacOS/$APP" \
  target/aarch64-apple-darwin/release/kino \
  target/x86_64-apple-darwin/release/kino
cp icons/icon.icns "$BUNDLE/Contents/Resources/$APP.icns"
cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>app.kino.cleaner</string>
  <key>CFBundleIconFile</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Kino uses Finder to empty your Trash.</string>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing (required for Apple Silicon; not a Developer ID signature)"
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

echo "==> Creating DMG"
STAGE=$(mktemp -d)
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/If Kino won't open.txt" <<'EOF'
Kino isn't signed with an Apple Developer ID yet, so macOS blocks it the first time.

1. Drag Kino into the Applications folder.
2. Open Terminal (Cmd+Space, type "Terminal", press Enter) and paste:

   xattr -dr com.apple.quarantine /Applications/Kino.app

3. Press Enter, then open Kino normally.

No Terminal? Try to open Kino once, then go to
System Settings > Privacy & Security, scroll down and click "Open Anyway".
EOF
rm -f "$DIST/$APP.dmg"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -ov "$DIST/$APP.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "Done:"
du -sh "$BUNDLE" "$DIST/$APP.dmg"
lipo -archs "$BUNDLE/Contents/MacOS/$APP"
