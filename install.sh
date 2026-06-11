#!/bin/bash
# 安装: 构建菜单栏 App → 装到 /Applications → 设开机自启。无需 sudo。
# 用法: bash install.sh   (在仓库目录下运行)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="com.hx10.auto-timezone-menubar"

echo "==> 1/3 构建 App"
bash "$DIR/menubar/build.sh"

echo "==> 2/3 安装到 /Applications"
launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
pkill -x AutoTimezone 2>/dev/null || true
ditto "$DIR/menubar/AutoTimezone.app" /Applications/AutoTimezone.app
codesign --force --deep --sign - /Applications/AutoTimezone.app 2>/dev/null || true

echo "==> 3/3 设为开机自启(当前用户)"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$DIR/menubar/$AGENT.plist" "$HOME/Library/LaunchAgents/$AGENT.plist"
launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$AGENT.plist"

echo
echo "✅ 安装完成。菜单栏右上角出现 🌐 图标(✓绿=三路一致 / ✗红=异常)。"
echo "   建议: 系统设置→日期与时间，关闭“自动设置时区”，避免与本工具冲突。"
echo "   改时区时会弹一次系统授权框(输入密码/Touch ID)，属正常。"
