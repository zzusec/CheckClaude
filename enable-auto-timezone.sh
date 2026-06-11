#!/bin/bash
# 启用「免密自动改时区」: 仅给当前用户对 `systemsetup -settimezone` 开 NOPASSWD。
# 之后 App 检测到出口时区变化会静默改系统时区，不再弹授权框。
# 用法: sudo bash enable-auto-timezone.sh
set -e

if [[ $EUID -ne 0 ]]; then
  echo "请用 sudo 运行: sudo bash $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-$(whoami)}"
F=/etc/sudoers.d/auto-timezone

echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/sbin/systemsetup -settimezone *" > "$F"
chmod 440 "$F"
visudo -cf "$F"   # 语法校验，失败会非零退出

echo "✅ 已启用免密自动改时区(用户: $TARGET_USER)"
echo "   以后切换 VPN/代理出口，系统时区会自动跟随，不再弹授权框。"
echo "   撤销: sudo rm $F"
