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

首次打开被拦(未做代码签名),macOS 15 起「右键→打开」已失效,两种办法:
  ① 终端执行: xattr -dr com.apple.quarantine /Applications/CheckClaude.app
  ② 双击一次让它被拦,然后 系统设置 → 隐私与安全性 → 往下滚到"安全性"
     → "已阻止使用 CheckClaude" → 点"仍要打开"
图标出现在屏幕右上角菜单栏(🌐 + 出口时区城市)。

功能:
  • 使用 HTTPS/TCP 检测三路出口 IP(国内/国外/谷歌)是否一致及线路波动/质量
  • 系统时区独立跟随"谷歌侧出口 IP"对应 IANA 时区，发现漂移会自动纠正
  • 出口 IP 变化或三路不一致时弹桌面告警
  • 默认每 1 分钟轻量检测三路出口，可在菜单调整间隔
  • Claude 运行环境体检: 26 项加权评分 + 40+ 原始诊断 + 一致性矩阵 + 修复建议
    出口状态变化时自动重测，也可在菜单里手动「重新体检」
  • 完整体检会打开默认浏览器显示出口 IP、时区、WebRTC、DNS、连通性和浏览器画像
    报告只经带随机令牌的 127.0.0.1 本机接口传递，不上传检测报告，完成后 4 秒自动关闭（可保持打开）

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
