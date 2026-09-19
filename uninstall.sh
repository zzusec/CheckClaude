#!/bin/bash
# 卸载守护进程与菜单栏 App
set -uo pipefail
DAEMON="com.example.checkclaude-daemon"
AGENT="com.example.checkclaude"
LEGACY_AGENT="com.hx10.checkclaude"

echo "==> 断开 Codex 防降智(还原 ~/.codex/config.toml)"
for s in /Applications/CheckClaude.app/Contents/Resources/codex-guard.sh "$(dirname "$0")/codex-guard.sh"; do
  [ -f "$s" ] && bash "$s" --disable >/dev/null 2>&1 && break
done

echo "==> 卸载菜单栏 App"
for id in "$AGENT" "$LEGACY_AGENT"; do
  launchctl bootout "gui/$(id -u)/$id" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$id.plist"
done
pkill -x CheckClaude 2>/dev/null || true

echo "==> 卸载系统守护进程(需要管理员密码)"
sudo launchctl bootout system "/Library/LaunchDaemons/$DAEMON.plist" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$DAEMON.plist"

echo "✅ 已卸载(脚本与日志仍保留在 ~/auto-timezone/)"
