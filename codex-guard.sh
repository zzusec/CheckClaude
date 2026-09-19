#!/bin/bash
# CheckClaude · Codex 防降智：把 codex 的 ChatGPT 流量接到本机反代上
#
# 反代（menubar/CodexGuard.swift）负责采集并跨会话复用 x-codex-turn-state，
# 思路来自 https://github.com/tzf1003/csss，但不需要 Surge、不装证书、不碰系统代理。
#
# 用法: codex-guard.sh --status | --enable | --disable | --restart
set -uo pipefail

DATA_DIR="${AUTO_TZ_DIR:-$HOME/Library/Application Support/CheckClaude}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"
BACKUP="$CONFIG.checkclaude-backup"
PORT="${CODEX_GUARD_PORT:-8788}"
BASE_URL="http://127.0.0.1:$PORT/backend-api/"
LABEL="com.example.checkclaude.codexguard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BEGIN="# >>> CheckClaude codex-guard >>>"
END="# <<< CheckClaude codex-guard <<<"
PARKED="#CheckClaude-parked# "     # 原有的同名键先停用，避免 TOML 重复键让 codex 起不来

HERE="$(cd "$(dirname "$0")" && pwd)"
# App 内: Resources/codex-guard.sh 与 MacOS/codex-guard；源码目录: 与 menubar/ 同级
GUARD_BIN=""
for c in "$HERE/../MacOS/codex-guard" "$HERE/menubar/codex-guard" "$HERE/../menubar/codex-guard"; do
    [ -x "$c" ] && GUARD_BIN="$c" && break
done

mkdir -p "$DATA_DIR"

codex_bin() {
    for c in "$(command -v codex 2>/dev/null)" "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
        [ -n "$c" ] && [ -x "$c" ] && echo "$c" && return
    done
}

# 走第三方中转(model_provider 指向自定义 provider)时，292 state 对上游没意义，不接入
provider_mode() {
    local p
    p=$(grep -E '^[[:space:]]*model_provider[[:space:]]*=' "$CONFIG" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [ -z "$p" ] || [ "$p" = "openai" ]; then echo "chatgpt"; else echo "custom:$p"; fi
}

linked() { grep -qF "$BEGIN" "$CONFIG" 2>/dev/null; }
# 探端口而不是 pgrep: 本脚本自己的命令行里也有 codex-guard，会被 pgrep -f 误当成反代
running() { nc -z -G 1 127.0.0.1 "$PORT" >/dev/null 2>&1; }

load_agent() {
    mkdir -p "$(dirname "$PLIST")"
    cat >"$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$GUARD_BIN</string></array>
    <key>EnvironmentVariables</key><dict>
        <key>AUTO_TZ_DIR</key><string>$DATA_DIR</string>
        <key>CODEX_GUARD_PORT</key><string>$PORT</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardErrorPath</key><string>$DATA_DIR/codex-guard.log</string>
</dict>
</plist>
PL
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1
    launchctl bootstrap "gui/$UID" "$PLIST" >/dev/null 2>&1
}

unload_agent() {
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1
    rm -f "$PLIST"
}

link_config() {
    cp "$CONFIG" "$BACKUP" 2>/dev/null
    local tmp
    tmp=$(mktemp)
    # 顶层键必须排在任何 [table] 之前，所以插到文件最开头
    {
        echo "$BEGIN"
        echo "chatgpt_base_url = \"$BASE_URL\""
        echo "$END"
        sed -E "s|^([[:space:]]*chatgpt_base_url[[:space:]]*=)|$PARKED\1|" "$CONFIG" 2>/dev/null
    } >"$tmp"
    mv "$tmp" "$CONFIG"
}

unlink_config() {
    [ -f "$CONFIG" ] || return 0
    local tmp
    tmp=$(mktemp)
    awk -v b="$BEGIN" -v e="$END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip
    ' "$CONFIG" | sed -E "s|^${PARKED}([[:space:]]*chatgpt_base_url)|\1|" >"$tmp"
    mv "$tmp" "$CONFIG"
}

do_enable() {
    local bin mode
    bin=$(codex_bin)
    [ -z "$bin" ] && { echo "未安装 codex，无需接入"; return 2; }
    mode=$(provider_mode)
    [ "$mode" != "chatgpt" ] && { echo "codex 当前走 $mode，不是官方 ChatGPT 链路，已跳过接入"; return 3; }
    [ -z "$GUARD_BIN" ] && { echo "找不到 codex-guard 可执行文件"; return 4; }
    [ -f "$CONFIG" ] || { mkdir -p "$CODEX_HOME"; : >"$CONFIG"; }
    linked || link_config
    load_agent
    sleep 1
    if running; then
        do_status >/dev/null
        echo "已接入，反代监听 127.0.0.1:$PORT"
    else
        echo "反代未起来，已回滚"; do_disable; return 5
    fi
}

do_disable() {
    unload_agent
    unlink_config
    do_status >/dev/null
    echo "已断开，codex 恢复直连"
}

do_status() {
    local bin
    bin=$(codex_bin)
    {
        echo "codex=$([ -n "$bin" ] && echo 1 || echo 0)"
        echo "codex_path=${bin:--}"
        echo "provider=$(provider_mode)"
        echo "linked=$(linked && echo 1 || echo 0)"
        echo "running=$(running && echo 1 || echo 0)"
        echo "port=$PORT"
    } | tee "$DATA_DIR/codex_guard_link"   # 菜单栏 App 直接读这个文件
}

case "${1:---status}" in
    --enable)  do_enable ;;
    --disable) do_disable ;;
    --restart) unload_agent; load_agent ;;
    --status)  do_status ;;
    *) echo "用法: $0 --status | --enable | --disable | --restart"; exit 1 ;;
esac
