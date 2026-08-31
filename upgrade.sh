#!/bin/bash
# upgrade.sh —— 检查并安装 CheckClaude 新版本，数据源是 GitHub Releases。
#
# 用法:
#   ./upgrade.sh --check     # 查最新版本，结果写 update_status，不装
#   ./upgrade.sh --install   # 下载最新 dmg 并替换 /Applications/CheckClaude.app，然后重启 App

set -uo pipefail

REPO="zzusec/CheckClaude"
APP="/Applications/CheckClaude.app"
DATA_DIR="${AUTO_TZ_DIR:-$HOME/Library/Application Support/CheckClaude}"
mkdir -p "$DATA_DIR" 2>/dev/null || true
USTATUS="$DATA_DIR/update_status"
USTATE="$DATA_DIR/upgrade_state"      # 升级进行到哪一步，菜单栏据此显示进度
LOG="$DATA_DIR/auto-timezone.log"
AGENT="com.hx10.checkclaude"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG" 2>/dev/null || true; }
state() { echo "$1" >"$USTATE" 2>/dev/null || true; }
notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

current_version() {
  defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null \
    || defaults read "$(dirname "$0")/../Info.plist" CFBundleShortVersionString 2>/dev/null
}

latest_version() {
  curl -fsS -m 15 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 | sed 's/^[vV]//'
}

# 语义化比较: 有更新才返回 0。sort -V 能正确处理 2.9 < 2.10
has_update() {
  local cur="$1" latest="$2" newest
  [[ -z "$latest" || -z "$cur" || "$cur" == "$latest" ]] && return 1
  newest=$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)
  [[ "$newest" == "$latest" ]]
}

do_check() {
  local cur latest up=0
  cur=$(current_version); latest=$(latest_version)
  if [[ -z "$latest" ]]; then
    # 查不到就别覆盖上一次的结果，网络抖动不该让升级提示忽隐忽现
    log "upgrade: 查询最新版本失败"
    [[ -f "$USTATUS" ]] && exit 0
    latest="?"
  fi
  has_update "$cur" "$latest" && up=1
  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "current=${cur:-?}"
    echo "latest=${latest}"
    echo "hasupdate=${up}"
  } >"$USTATUS" 2>/dev/null
  log "upgrade: 当前 ${cur:-?} 最新 ${latest} 有更新=${up}"
  echo "${up}"
}

do_install() {
  local cur latest tmp mnt
  cur=$(current_version); latest=$(latest_version)
  if ! has_update "$cur" "$latest"; then
    echo "已经是最新版本 ${cur}"; notify "CheckClaude" "已经是最新版本 ${cur}"; exit 0
  fi

  echo "→ 下载 v${latest} ..."
  notify "CheckClaude" "正在下载 v${latest} …"
  state "下载中 0%"
  tmp=$(mktemp -d); mnt="$tmp/mnt"; mkdir -p "$mnt"
  local url="https://github.com/${REPO}/releases/latest/download/CheckClaude.dmg"

  # 后台下载 + 轮询文件大小算百分比 —— 点了升级之后没有任何反馈，
  # 用户不知道是在下载还是卡死了。
  local total cpid cur pct
  total=$(curl -sIL -m 20 "$url" 2>/dev/null | grep -i '^content-length:' | tail -1 | tr -dc '0-9')
  curl -fL -m 180 -o "$tmp/CheckClaude.dmg" "$url" 2>/dev/null &
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
    cur=$(stat -f%z "$tmp/CheckClaude.dmg" 2>/dev/null || echo 0)
    if [[ -n "$total" && "$total" -gt 0 ]]; then
      pct=$(( cur * 100 / total )); [[ $pct -gt 99 ]] && pct=99
      state "下载中 ${pct}%"
    else
      state "下载中 $(( cur / 1024 )) KB"
    fi
    sleep 1
  done
  if ! wait "$cpid"; then
    echo "  ✗ 下载失败"; state "失败：下载不了 dmg"
    notify "升级失败" "下载不了 dmg，检查网络后重试"; rm -rf "$tmp"; exit 1
  fi
  state "下载完成，正在安装"

  if ! hdiutil attach -nobrowse -quiet "$tmp/CheckClaude.dmg" -mountpoint "$mnt" 2>/dev/null; then
    echo "  ✗ 挂载失败"; notify "升级失败" "dmg 挂载失败"; rm -rf "$tmp"; exit 1
  fi
  if [[ ! -d "$mnt/CheckClaude.app" ]]; then
    echo "  ✗ dmg 里没有 CheckClaude.app"; hdiutil detach "$mnt" -quiet 2>/dev/null; rm -rf "$tmp"; exit 1
  fi

  echo "→ 安装到 $APP"
  state "安装中"
  # 先删再拷: 直接覆盖正在运行的 .app 会 Text file busy；删掉后旧进程靠已打开的
  # inode 继续跑到 kickstart 为止，是安全的。
  rm -rf "$APP"
  ditto "$mnt/CheckClaude.app" "$APP"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
  hdiutil detach "$mnt" -quiet 2>/dev/null
  rm -rf "$tmp"

  log "upgrade: ${cur} -> ${latest} 安装完成"
  notify "CheckClaude 已升级" "${cur} → ${latest}，正在重启"
  do_check >/dev/null

  # 状态文件必须在这里清 —— kickstart 会杀掉 App，Swift 侧那个"脚本结束后清理"的
  # 回调根本没机会执行，新 App 起来会读到残留状态一直显示"正在重启"。
  rm -f "$USTATE"

  # 重启自己。kickstart 会杀掉当前 App 进程，本脚本是独立进程能跑完。
  launchctl kickstart -k "gui/$(id -u)/${AGENT}" 2>/dev/null \
    || open -a "$APP" 2>/dev/null
  echo "✅ 已升级到 v${latest}"
}

case "${1:---check}" in
  --check)   do_check ;;
  --install) do_install ;;
  *) echo "用法: $0 [--check|--install]"; exit 1 ;;
esac
