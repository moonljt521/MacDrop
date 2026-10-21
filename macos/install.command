#!/bin/bash
# MoonDrop 安装 / 升级脚本
#
# 用法：把本脚本和 MoonDrop.app 放在同一个文件夹里，双击运行（或 bash install.command）。
# 会做的事：
#   1. 退出正在运行的旧版 MoonDrop（不需要手动退出）
#   2. 覆盖安装到 /Applications/MoonDrop.app
#   3. 清除隔离属性（避免「已损坏，无法打开」）
#   4. 启动新版

set -e
cd "$(dirname "$0")"

APP_SRC="$(pwd)/MoonDrop.app"
DEST="/Applications/MoonDrop.app"

if [ ! -d "$APP_SRC" ]; then
    echo "✗ 没找到 MoonDrop.app。请确认本脚本和 MoonDrop.app 在同一个文件夹里。"
    read -r -p "按回车退出..." _
    exit 1
fi

echo "==> [1/4] 退出正在运行的 MoonDrop（含旧的 MacDrop 版本）"
pkill -x MoonDrop 2>/dev/null || true
pkill -x MacDrop 2>/dev/null || true
for _ in $(seq 1 10); do
    pgrep -x MoonDrop >/dev/null 2>&1 || break
    sleep 0.3
done
pkill -9 -x MoonDrop 2>/dev/null || true
echo "    ✓ 完成"

echo "==> [2/4] 安装到 $DEST"
rm -rf "/Applications/MacDrop.app"
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"
echo "    ✓ 完成"

echo "==> [3/4] 清除隔离属性并校验签名"
xattr -cr "$DEST"
if codesign --verify --deep --strict "$DEST" 2>/dev/null; then
    echo "    ✓ 签名校验通过"
else
    echo "    ! 签名校验未通过（通常仍可运行；若提示已损坏，执行 xattr -cr 后重试）"
fi

echo "==> [4/4] 启动 MoonDrop"
open "$DEST"
echo
echo "✓ 安装完成，菜单栏会出现 MoonDrop 图标。"
echo "  首次启动若弹「本地网络」「自动化（Finder）」权限框，点「好」。"
read -r -p "按回车关闭本窗口..." _
exit 0
