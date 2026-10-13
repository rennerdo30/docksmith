#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-release}"
version="${2:-0.1.0}"
build_number="${3:-1}"
destination="${4:-dist}"

[[ "$configuration" == "release" || "$configuration" == "debug" ]]
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$build_number" =~ ^[0-9]+$ ]]

binary=".build/$configuration/DocksmithApp"
test -x "$binary"

app="$destination/Docksmith.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/DocksmithApp"
cp LICENSE "$app/Contents/Resources/LICENSE"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.renner.Docksmith</string>
  <key>CFBundleName</key><string>Docksmith</string>
  <key>CFBundleDisplayName</key><string>Docksmith</string>
  <key>CFBundleExecutable</key><string>DocksmithApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>CFBundleIconFile</key><string>Docksmith.icns</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Docksmith uses the local network to connect to the paired Apple devices you select over Wi-Fi.</string>
</dict></plist>
PLIST

iconset="$destination/Docksmith.iconset"
mkdir -p "$iconset"
swift scripts/generate-app-icon.swift "$destination/Docksmith-master.png"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$destination/Docksmith-master.png" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -s format png -z "$retina" "$retina" "$destination/Docksmith-master.png" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Docksmith.icns"
plutil -lint "$app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "dev.renner.Docksmith"
