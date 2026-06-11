#!/bin/bash
# 编译菜单栏监控 App 为 AutoTimezone.app (LSUIElement 后台代理，不进 Dock)
set -euo pipefail
cd "$(dirname "$0")"

APP="AutoTimezone.app"
BIN="AutoTimezone"

echo "编译 Swift ..."
swiftc StatusApp.swift -o "$BIN" -framework Cocoa -O

echo "组装 .app 包 ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

# 把检测脚本打包进 App，实现自包含可分发
cp ../auto-timezone.sh "$APP/Contents/Resources/auto-timezone.sh"
chmod +x "$APP/Contents/Resources/auto-timezone.sh"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>AutoTimezone</string>
    <key>CFBundleDisplayName</key>     <string>出口IP时区监控</string>
    <key>CFBundleIdentifier</key>      <string>com.hx10.auto-timezone-menubar</string>
    <key>CFBundleExecutable</key>      <string>AutoTimezone</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>LSUIElement</key>             <true/>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
</dict>
</plist>
PLIST

# 本地临时签名，避免 Gatekeeper 拦截
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "完成: $(pwd)/$APP"
