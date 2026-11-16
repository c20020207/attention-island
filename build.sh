#!/bin/sh
# Builds the island as a background agent app (no Dock icon), installs it and the Claude hook script.
set -e
cd "$(dirname "$0")"
python3 test_hook.py
swift build -c release
app="build/Attention Island.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/AttentionIsland "$app/Contents/MacOS/"
iconset=build/AppIcon.iconset
rm -rf "$iconset" && mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size Icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AttentionIsland</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.jimmy.attentionisland</string>
  <key>CFBundleName</key><string>Attention Island</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$app"
mkdir -p ~/.attention-island
cp hook.py ~/.attention-island/hook.py
python3 install-hooks.py
pkill -x AttentionIsland || true
rm -rf "/Applications/Attention Island.app"
cp -R "$app" /Applications/
open "/Applications/Attention Island.app"
echo "installed /Applications/Attention Island.app"
