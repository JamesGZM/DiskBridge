#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
VERSION="$(<VERSION)"
APP_DIR="$PROJECT_DIR/dist/盘桥.app"
DMG_NAME="DiskBridge-$VERSION-macos-arm64.dmg"
DMG_PATH="$PROJECT_DIR/dist/$DMG_NAME"
[[ "$(lipo -archs "$APP_DIR/Contents/MacOS/DiskBridge")" == arm64 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")" == "$VERSION" ]]
codesign --verify --deep --strict "$APP_DIR"
SIGNATURE="$(codesign --display --verbose=4 "$APP_DIR" 2>&1)"
[[ "$SIGNATURE" == *'Signature=adhoc'* && "$SIGNATURE" == *'TeamIdentifier=not set'* && "$SIGNATURE" != *'Authority='* ]] || {
  print -u2 'Release app must use identity-free ad-hoc signing.'; exit 1
}
if /usr/libexec/PlistBuddy -c 'Print DiskBridgeRoot' "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1; then
  print -u2 'Release app must not embed a machine-specific data root.'; exit 1
fi
if codesign --display "$DMG_PATH" >/dev/null 2>&1; then
  print -u2 'Release DMG must be unsigned.'; exit 1
fi
hdiutil verify -quiet "$DMG_PATH"
(cd dist && shasum -a 256 -c "$DMG_NAME.sha256")

CHECK_DIR="$(mktemp -d "$PROJECT_DIR/.build/release-check-XXXXXXXX")"
mkdir "$CHECK_DIR/mount"
ATTACH_STARTED=0
cleanup() {
  if (( ATTACH_STARTED )); then hdiutil detach "$CHECK_DIR/mount" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
ATTACH_STARTED=1
if diskutil image attach --help >/dev/null 2>&1; then
  diskutil image attach --plist --readOnly --nobrowse --mountPoint "$CHECK_DIR/mount" "$DMG_PATH" > "$CHECK_DIR/attach.plist"
else
  hdiutil attach -plist -readonly -nobrowse -noautoopen -mountpoint "$CHECK_DIR/mount" "$DMG_PATH" > "$CHECK_DIR/attach.plist"
fi
codesign --verify --deep --strict "$CHECK_DIR/mount/盘桥.app"
diff -rq "$APP_DIR" "$CHECK_DIR/mount/盘桥.app"
[[ "$(readlink "$CHECK_DIR/mount/Applications")" == /Applications ]]
cmp LICENSE "$CHECK_DIR/mount/LICENSE.txt"
[[ -f "$CHECK_DIR/mount/安装说明.txt" ]]
for item in "$CHECK_DIR/mount"/*(N); do
  case "${item:t}" in
    盘桥.app|Applications|LICENSE.txt|安装说明.txt) ;;
    *) print -u2 'Unexpected file in release image.'; exit 1 ;;
  esac
done
print 'Verified arm64 app, identity-free signature, unsigned DMG, contents and checksum.'
