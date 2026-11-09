#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Depthline.app"
cd "$ROOT"
test -f remastered-assets/depthline-icon.png
python3 tools/generate_depthline_assets.py
test -f original-assets/audio/manifest.json
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/swift-cache"
# Compile a consistent source snapshot; a failed build must leave the
# previously runnable binary intact, even during iterative visual reviews.
STAGE="$(mktemp -d "$ROOT/build/depthline-compile.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp native/*.swift "$STAGE/"
mv "$STAGE/MacGame.swift" "$STAGE/main.swift"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -target arm64-apple-macosx13.0 -module-cache-path "$ROOT/build/swift-cache" \
    -framework AppKit -framework SceneKit -framework QuartzCore "$STAGE/"*.swift -o "$STAGE/Depthline"
mv -f "$STAGE/Depthline" "$APP/Contents/MacOS/Depthline"
# An explicit fresh allowlist prevents obsolete extracted assets surviving ditto.
python3 tools/package_depthline.py
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Depthline</string>
<key>CFBundleDisplayName</key><string>纵深防线</string>
<key>CFBundleIdentifier</key><string>local.depthline.defense</string>
<key>CFBundleVersion</key><string>0.8.5</string>
<key>CFBundleShortVersionString</key><string>0.8.5</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array>
<string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>ko</string><string>ja</string>
<string>fr</string><string>es</string><string>pt</string><string>ru</string><string>id</string>
<string>vi</string><string>th</string></array>
<key>CFBundleExecutable</key><string>Depthline</string>
<key>CFBundleIconFile</key><string>Depthline.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
