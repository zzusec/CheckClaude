#!/bin/bash
# 卸载守护进程与菜单栏 App
set -uo pipefail
DAEMON="com.hx10.auto-timezone"
AGENT="com.hx10.auto-timezone-menubar"

echo "==> 卸载菜单栏 App"
launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$AGENT.plist"
pkill -x AutoTimezone 2>/dev/null || true

echo "==> 卸载系统守护进程(需要管理员密码)"
sudo launchctl bootout system "/Library/LaunchDaemons/$DAEMON.plist" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$DAEMON.plist"

echo "✅ 已卸载(脚本与日志仍保留在 ~/auto-timezone/)"
