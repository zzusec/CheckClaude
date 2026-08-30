#!/bin/bash
# 打包成可分发 dmg: 用户挂载后把 CheckClaude.app 拖进 Applications 即可。
set -euo pipefail
cd "$(dirname "$0")"

APP="menubar/CheckClaude.app"
VOL="CheckClaude"
DMG="CheckClaude.dmg"
STAGE="$(mktemp -d)"

echo "==> 1/3 构建 App"
bash menubar/build.sh

echo "==> 2/3 准备 dmg 内容"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # 方便拖拽安装
# 顺带附一份说明
cat >"$STAGE/使用说明.txt" <<'TXT'
CheckClaude CheckClaude

安装: 把 CheckClaude.app 拖到 Applications 文件夹。

首次打开: 右键 App → 打开(绕过未签名提示)。
图标出现在屏幕右上角菜单栏(🌐 + 出口时区城市)。

功能:
  • 按 ip111 逻辑检测三路出口 IP(国内/国外/谷歌)是否一致
  • 时区自动设为"谷歌侧出口 IP"对应时区(变更时弹一次系统授权框)
  • 出口 IP 变化或三路不一致时弹桌面告警
  • 每 5 分钟自动检测，点图标可立即检测/查看日志
  • Claude 运行环境体检: 20 项加权信号打分(0-100) + 问题清单 + 修复建议 + 一键修复
    出口 IP 变化时自动重测，也可在菜单里手动「重新体检」

开机自启: 系统设置 → 通用 → 登录项 → 添加 CheckClaude。
建议关闭"系统设置→日期与时间→自动设置时区"，避免冲突。

──────────────────────────────────────────────
作者的产品: 叮叮提醒 — 重要的事，我来帮你记着
吃药/还款/农历生日/纪念日倒数,说一句话就能创建,
到点经微信、邮件、短信或电话送达。三端同步,
微信与邮件提醒终生免费。 https://www.yinso.com
微信小程序搜「叮叮提醒」
TXT

echo "==> 3/3 生成 dmg"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✅ 完成: $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1))"
