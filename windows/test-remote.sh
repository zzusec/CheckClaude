#!/bin/bash
# 在 Windows 构建机上编译并运行 BrowserBridge 自动测试。
set -euo pipefail
cd "$(dirname "$0")"
HOST="${WIN_HOST:-win-ding}"
REMOTE="C:/Users/hx10/checkclaude-build"

ssh "$HOST" "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force '$REMOTE' | Out-Null\""
scp Program.cs BrowserBridge.cs BrowserBridgeTests.cs test-remote.ps1 "$HOST:$REMOTE/"
ssh "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File $REMOTE/test-remote.ps1"
