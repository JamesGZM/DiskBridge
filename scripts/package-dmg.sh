#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
APP_DIR="$PROJECT_DIR/dist/盘桥.app"
[[ -d "$APP_DIR" ]] || { print -u2 'Run scripts/build-app.sh first.'; exit 1; }
codesign --verify --deep --strict "$APP_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ARCH_NAME="$(lipo -archs "$APP_DIR/Contents/MacOS/DiskBridge")"
[[ "$ARCH_NAME" == arm64 ]] || { print -u2 'Only Apple Silicon packages are supported.'; exit 1; }
[[ "$VERSION" == "$(<VERSION)" ]] || { print -u2 'Rebuild the app after changing VERSION.'; exit 1; }
STAGE_DIR="$(mktemp -d "$PROJECT_DIR/.build/dmg-XXXXXXXX")"
mkdir "$STAGE_DIR/payload"
ditto "$APP_DIR" "$STAGE_DIR/payload/盘桥.app"
ln -s /Applications "$STAGE_DIR/payload/Applications"
cp LICENSE "$STAGE_DIR/payload/LICENSE.txt"
cat > "$STAGE_DIR/payload/安装说明.txt" <<'TEXT'
将盘桥拖入 Applications 后，从应用程序中打开。
更新前退出盘桥，保留应用数据目录与现有迁移记录。
启动时会检查所需权限，缺少权限时显示系统授权引导。
配置与运行记录保存在当前用户的 Library/Application Support/DiskBridge。
此镜像不包含用户数据。是否已经公证由构建/发布者另行说明。
GitHub 发布的版本不使用开发者证书签名，不做 Apple 公证。应用保留 Apple Silicon 运行所需的本地 ad-hoc 签名。
TEXT
OUTPUT="$PROJECT_DIR/dist/DiskBridge-$VERSION-macos-arm64.dmg"
hdiutil create -quiet -volname '盘桥安装' -fs HFS+ -format UDZO \
  -srcfolder "$STAGE_DIR/payload" "$STAGE_DIR/installer.dmg"
if [[ -n "${DISKBRIDGE_SIGN_IDENTITY:-}" && "$DISKBRIDGE_SIGN_IDENTITY" != - ]]; then
  codesign --sign "$DISKBRIDGE_SIGN_IDENTITY" --identifier com.local.diskbridge.installer \
    --timestamp=none "$STAGE_DIR/installer.dmg"
fi
hdiutil verify -quiet "$STAGE_DIR/installer.dmg"
mv "$STAGE_DIR/installer.dmg" "$OUTPUT"
(cd dist && shasum -a 256 "${OUTPUT:t}" > "${OUTPUT:t}.sha256")
print "Packaged: dist/${OUTPUT:t}"
