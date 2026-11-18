#!/bin/sh
# Build TowerApp in release mode, wrap it in an ad-hoc signed .app bundle, and install it
# to ~/Applications so Spotlight and Launchpad find it.
# Usage: scripts/bundle-app.sh [dest.app [bundle-id]]   → dest.app, default ~/Applications/ControlTower.app (staged in
# .build/ControlTower.app); a dest that does not end in .app (empty, a folder, a trailing /) stops before anything is removed.
# bundle-id defaults to local.control-tower; the test instance takes its own, e.g.
#   scripts/bundle-app.sh .build/ControlTowerTest.app local.control-tower.test   (T96, scripts/test-instance.sh)
# For a my-team worker (OMC_TEAM_WORKER=<team>/<worker>) local.control-tower.test becomes
# local.control-tower.test-<worker>: test instances of two workers that share an id empty and overwrite each other's
# settings (T173). Any other id is used as given.
set -eu
cd "$(dirname "$0")/.."
bundle_id="${2-local.control-tower}"
worker="${OMC_TEAM_WORKER-}"
worker="${worker##*/}"
if [ "$bundle_id" = local.control-tower.test ] && [ -n "$worker" ]; then
    bundle_id="$bundle_id-$(printf %s "$worker" | LC_ALL=C tr -c 'A-Za-z0-9.-' '-')"
    echo "bundle-app.sh: worker '$worker': bundle id $bundle_id" >&2
fi
case "$bundle_id" in
    ''|*[!A-Za-z0-9.-]*) echo "bundle-app.sh: bundle id must be letters, digits, . and -: '$bundle_id'" >&2; exit 1 ;;
esac
swift build -c release --product TowerApp
app=.build/ControlTower.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/TowerApp" "$app/Contents/MacOS/TowerApp"
# highlight.js, its BSD-3 license and NOTICE; Syntax.swift reads the script from Contents/Resources.
mkdir -p "$app/Contents/Resources"
cp Sources/TowerCore/Resources/* "$app/Contents/Resources/"
# The app icon, from the square 1024 original: macOS rounds its corners (T82 report).
iconset=.build/AppIcon.iconset
rm -rf "$iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon/icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) AppIcon/icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TowerApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>Control Tower</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>세션으로 이동할 때 그 세션의 Ghostty 탭을 찾아 앞으로 가져옵니다.</string>
    <!-- the task board's own drag of a panel or a line (T153, R17 S1): UTType(exportedAs:) in TaskBoardPanels.swift -->
    <key>UTExportedTypeDeclarations</key>
    <array><dict>
        <key>UTTypeIdentifier</key><string>local.control-tower.board-item</string>
        <key>UTTypeDescription</key><string>Control Tower task board item</string>
        <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
dest="${1-$HOME/Applications/ControlTower.app}"
# rm -rf below: only ever an .app bundle, never the folder it sits in
case "$dest" in
    *.app) ;;
    *) echo "bundle-app.sh: dest must end in .app: '$dest'" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
ditto "$app" "$dest"
echo "$dest"
