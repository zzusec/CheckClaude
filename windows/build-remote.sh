#!/bin/bash
# 在 Mac 上一条命令出 Windows 产物: 传源码到构建机 win-ding，远程 csc 编译，拉回 exe + zip。
# 坑(别改回去):
#   1) .ps1 必须 UTF-8 with BOM —— PowerShell 默认按 GBK 解无 BOM 文件，中文全乱
#   2) 一律 scp 脚本过去用 -File 执行，别用 ssh win-ding 'powershell -Command "..."'，多层转义必错
#   3) scp 拉回来的文件权限是 700，要 chmod 644 否则传上服务器 Caddy 读不到会 403
set -euo pipefail
cd "$(dirname "$0")"
HOST="${WIN_HOST:-win-ding}"
VER="${1:-3.1}"
REMOTE="C:/Users/hx10/checkclaude-build"

echo "==> 版本 ${VER}，同步源码到 $HOST"
ssh "$HOST" "if not exist \"$REMOTE\" mkdir \"$REMOTE\"" >/dev/null 2>&1 || true
scp -q Program.cs BrowserBridge.cs build.ps1 "$HOST:$REMOTE/"

echo "==> 远程编译"
ssh "$HOST" "powershell -ExecutionPolicy Bypass -File $REMOTE/build.ps1 -Version $VER"

echo "==> 拉回产物"
scp -q "$HOST:$REMOTE/CheckClaude.exe" "$HOST:$REMOTE/CheckClaude-win.zip" .
chmod 644 CheckClaude.exe CheckClaude-win.zip
ls -lh CheckClaude.exe CheckClaude-win.zip | awk '{print "   ", $9, $5}'
echo "✅ 完成"
