#!/bin/bash
# 构建 MacDrop.app
#
# 「已损坏」的真正原因（已修复）：
#   1. SPM 产物的二进制只有 linker-signed，整个 app 包没有签名
#      → codesign --verify 直接报：
#        "code has no resources but signature indicates they must be present"
#   2. Info.plist 没被绑定进签名（Info.plist=not bound）
#      → 用 --sign 显式绑定整个 bundle，资源一并封装
#   3. 拷贝到别的 Mac 会带上 quarantine 属性
#      → xattr -cr 彻底清除
set -e
cd "$(dirname "$0")"

APP_NAME="MacDrop"
BUILD_DIR=".build/release"
APP_DIR="dist/$APP_NAME.app"

echo "==> [1/5] 编译"
swift build -c release --disable-sandbox

echo "==> [2/5] 组装 .app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>MacDrop</string>
    <key>CFBundleDisplayName</key>           <string>MacDrop</string>
    <key>CFBundleIdentifier</key>            <string>com.macdrop.app</string>
    <key>CFBundleVersion</key>               <string>6</string>
    <key>CFBundleShortVersionString</key>    <string>1.4</string>
    <key>CFBundleExecutable</key>            <string>MacDrop</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>LSUIElement</key>                   <true/>
    <key>NSHumanReadableCopyright</key>      <string>Local tool</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>MacDrop 需要读取 Finder 中当前选中的文件，以便一键发送到另一台 Mac。</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MacDrop 需要访问局域网，用于在两台 Mac 之间直接传输文件。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_macdrop._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "==> [3/5] ad-hoc 签名（封进 bundle，资源一并绑定）"
# 用 "-" 作 identity 做本地 ad-hoc 签名，能过 Gatekeeper 的完整性校验
codesign --force --sign - --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/    /'
# 二进制单独再签一次，确保 Mach-O 自身也有完整签名
codesign --force --sign - --timestamp=none "$APP_DIR/Contents/MacOS/$APP_NAME" 2>&1 | sed 's/^/    /'

echo "==> [4/5] 清除隔离属性并校验"
xattr -cr "$APP_DIR" 2>/dev/null || true

echo
echo "--- 签名信息 ---"
codesign -dv "$APP_DIR" 2>&1 | grep -E "Identifier|Signature|Sealed|TeamIdentifier" | sed 's/^/    /'
echo "--- 完整性校验 ---"
if codesign --verify --deep --strict "$APP_DIR" 2>&1 | sed 's/^/    /'; then
    echo "    ✓ 校验通过"
else
    echo "    ✗ 校验失败"
    exit 1
fi
echo "--- 隔离属性 ---"
if xattr "$APP_DIR" 2>/dev/null | grep -q quarantine; then
    echo "    ✗ 仍带 quarantine"
else
    echo "    ✓ 无 quarantine"
fi

echo "==> [5/5] 打包安装包（MacDrop.app + install.command → dist/MacDrop.zip）"
if [ ! -f install.command ]; then
    echo "    ✗ 缺少 install.command，无法打包"
    exit 1
fi
cp install.command dist/install.command
chmod +x dist/install.command
rm -f dist/MacDrop.zip
(cd dist && zip -r -q -X MacDrop.zip MacDrop.app install.command \
    -x "*.DS_Store" "*/._*" "._*")
echo "    ✓ dist/MacDrop.zip"
shasum -a 256 dist/MacDrop.zip | sed 's/^/    /'

echo
echo "✓ 完成:"
echo "    app: $APP_DIR"
echo "    zip: dist/MacDrop.zip  ← 拷到另一台 Mac，解压后双击 install.command 安装"
echo
echo "  安装脚本会自动退出正在运行的旧版本，无需手动关闭。"
echo "  若那台机器仍提示损坏，手动执行一次：xattr -cr /Applications/MacDrop.app"