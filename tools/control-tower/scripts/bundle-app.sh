#!/bin/sh
# Build TowerApp in release mode, wrap it in an ad-hoc signed .app bundle, and install it
# to ~/Applications so Spotlight and Launchpad find it.
# Usage: scripts/bundle-app.sh   → ~/Applications/ControlTower.app (staged in .build/ControlTower.app)
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product TowerApp
app=.build/ControlTower.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/TowerApp" "$app/Contents/MacOS/TowerApp"
# highlight.js, its BSD-3 license and NOTICE; Syntax.swift reads the script from Contents/Resources.
mkdir -p "$app/Contents/Resources"
cp Sources/TowerCore/Resources/* "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TowerApp</string>
    <key>CFBundleIdentifier</key><string>local.control-tower</string>
    <key>CFBundleName</key><string>Control Tower</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>세션으로 이동할 때 그 세션의 Ghostty 탭을 찾아 앞으로 가져옵니다.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
dest="$HOME/Applications/ControlTower.app"
mkdir -p "$HOME/Applications"
rm -rf "$dest"
ditto "$app" "$dest"
echo "$dest"
