#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'This build currently supports Apple Silicon only.'; exit 1; }
VERSION="$(<VERSION)"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid VERSION.'; exit 1; }
SIGN_IDENTITY="${DISKBRIDGE_SIGN_IDENTITY:--}"
mkdir -p .build dist
STAGE_DIR="$(mktemp -d "$PROJECT_DIR/.build/app-XXXXXXXX")"
APP_DIR="$STAGE_DIR/盘桥.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swift build -c release --product DiskBridge -debug-info-format none \
  -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=."
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/DiskBridge" "$APP_DIR/Contents/MacOS/DiskBridge"
chmod 755 "$APP_DIR/Contents/MacOS/DiskBridge"
[[ "$(lipo -archs "$APP_DIR/Contents/MacOS/DiskBridge")" == arm64 ]] || { print -u2 'Expected an arm64 executable.'; exit 1; }
swift Tools/Icon.swift "$STAGE_DIR/DiskBridge.iconset"
iconutil -c icns "$STAGE_DIR/DiskBridge.iconset" -o "$APP_DIR/Contents/Resources/DiskBridge.icns"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DiskBridge</string>
<key>CFBundleIdentifier</key><string>com.local.diskbridge</string>
<key>CFBundleName</key><string>盘桥</string>
<key>CFBundleDisplayName</key><string>盘桥</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>DiskBridge</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
if [[ -e dist/盘桥.app ]]; then mv dist/盘桥.app "$STAGE_DIR/previous.app"; fi
mv "$APP_DIR" dist/盘桥.app
print "Built: dist/盘桥.app"
if [[ "$SIGN_IDENTITY" == - ]]; then
  print 'Local ad-hoc build. Use a stable signing identity for persistent system permissions.'
fi
