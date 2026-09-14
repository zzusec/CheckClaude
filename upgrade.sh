#!/bin/bash
# upgrade.sh —— 检查并安装 CheckClaude 新版本，数据源是 GitHub Releases。
#
# 用法:
#   ./upgrade.sh --check     # 查最新版本，结果写 update_status，不装
#   ./upgrade.sh --install   # 下载最新 dmg，原子替换当前 App，然后重启

set -uo pipefail

REPO="zzusec/CheckClaude"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLED_APP="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || true)"
if [[ -n "${CHECKCLAUDE_APP:-}" ]]; then
  APP="$CHECKCLAUDE_APP"
elif [[ -f "$BUNDLED_APP/Contents/Info.plist" ]]; then
  # 和北京时间万年历一样，升级实际正在运行的 bundle，不写死安装目录。
  APP="$BUNDLED_APP"
else
  APP="/Applications/CheckClaude.app"
fi
DATA_DIR="${AUTO_TZ_DIR:-$HOME/Library/Application Support/CheckClaude}"
mkdir -p "$DATA_DIR" 2>/dev/null || true
USTATUS="$DATA_DIR/update_status"
USTATE="$DATA_DIR/upgrade_state"      # 升级进行到哪一步，菜单栏据此显示进度
LOG="$DATA_DIR/auto-timezone.log"
AGENT="com.example.checkclaude"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG" 2>/dev/null || true; }
state() { echo "$1" >"$USTATE" 2>/dev/null || true; }
notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }
fail() {
  local message="$1"
  echo "  ✗ $message" >&2
  state "失败：${message}"
  log "upgrade: 失败：${message}"
  notify "升级失败" "$message"
  exit 1
}

plist_version() {
  defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

current_version() {
  plist_version "$APP" \
    || defaults read "$SCRIPT_DIR/../Info.plist" CFBundleShortVersionString 2>/dev/null
}

# 一次请求同时取得 tag 和这个 Release 里真实的 DMG 地址，避免检查和下载
# 被 releases/latest/download 分别指向不同 Release。做法与
# beijing-time-calendar 的 Updater.fetchLatest 相同。
latest_release() {
  local json tag version url
  json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -A 'CheckClaude-Updater' \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null) || return 1
  tag=$(printf '%s\n' "$json" \
    | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | cut -d'"' -f4)
  version=$(printf '%s' "$tag" | sed 's/^[vV]//')
  url=$(printf '%s\n' "$json" \
    | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*CheckClaude\.dmg"' \
    | head -1 | cut -d'"' -f4)
  [[ -n "$version" && -n "$url" ]] || return 1
  printf '%s\t%s\n' "$version" "$url"
}

status_value() {
  local key="$1"
  [[ -f "$USTATUS" ]] || return 1
  sed -n "s/^${key}=//p" "$USTATUS" | head -1
}

# 语义化比较: 有更新才返回 0。sort -V 能正确处理 2.9 < 2.10
has_update() {
  local cur="$1" latest="$2" newest
  [[ -z "$latest" || -z "$cur" || "$cur" == "$latest" ]] && return 1
  newest=$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)
  [[ "$newest" == "$latest" ]]
}

do_check() {
  local cur latest url info up=0
  cur=$(current_version)
  info=$(latest_release || true)
  latest=${info%%$'\t'*}
  if [[ "$info" == *$'\t'* ]]; then url=${info#*$'\t'}; else url=""; fi
  if [[ -z "$latest" || -z "$url" ]]; then
    # 查不到就别覆盖上一次的结果，网络抖动不该让升级提示忽隐忽现。
    log "upgrade: 查询最新版本或 DMG 资产失败"
    [[ -f "$USTATUS" ]] && exit 0
    latest="?"; url=""
  fi
  has_update "$cur" "$latest" && up=1
  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "current=${cur:-?}"
    echo "latest=${latest}"
    echo "hasupdate=${up}"
    echo "url=${url}"
  } >"$USTATUS" 2>/dev/null
  log "upgrade: 当前 ${cur:-?} 最新 ${latest} 有更新=${up}"
  echo "${up}"
}

do_install() {
  local cur latest url info tmp mnt total cpid bytes pct
  local package_version parent staged backup installed_version
  cur=$(current_version)
  info=$(latest_release || true)
  latest=${info%%$'\t'*}
  if [[ "$info" == *$'\t'* ]]; then url=${info#*$'\t'}; else url=""; fi

  # 点升级时 GitHub API 如果短暂失败，沿用刚才 --check 缓存的同一 Release 地址。
  if [[ -z "$latest" || -z "$url" ]]; then
    latest=$(status_value latest || true)
    url=$(status_value url || true)
  fi
  if ! has_update "$cur" "$latest"; then
    echo "已经是最新版本 ${cur}"
    notify "CheckClaude" "已经是最新版本 ${cur}"
    exit 0
  fi
  case "$url" in
    "https://github.com/${REPO}/releases/download/"*"/CheckClaude.dmg") ;;
    *) fail "Release 中没有可信的 CheckClaude.dmg 下载地址" ;;
  esac

  echo "→ 下载 v${latest} ..."
  notify "CheckClaude" "正在下载 v${latest} …"
  state "下载中 0%"
  tmp=$(mktemp -d); mnt="$tmp/mnt"; mkdir -p "$mnt"
  parent=$(dirname "$APP")
  staged="$parent/.CheckClaude-update-${$}.app"
  backup="$parent/.CheckClaude-backup-${$}.app"

  cleanup() {
    hdiutil detach "$mnt" -quiet 2>/dev/null || true
    rm -rf "$tmp" "$staged" 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM

  # 后台下载 + 轮询文件大小显示进度。
  total=$(curl -sIL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null \
    | grep -i '^content-length:' | tail -1 | tr -dc '0-9')
  curl -fL --connect-timeout 15 --max-time 180 -o "$tmp/CheckClaude.dmg" "$url" 2>/dev/null &
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
    bytes=$(stat -f%z "$tmp/CheckClaude.dmg" 2>/dev/null || echo 0)
    if [[ -n "$total" && "$total" -gt 0 ]]; then
      pct=$(( bytes * 100 / total )); [[ $pct -gt 99 ]] && pct=99
      state "下载中 ${pct}%"
    else
      state "下载中 $(( bytes / 1024 )) KB"
    fi
    sleep 1
  done
  wait "$cpid" || fail "下载不了 dmg，请检查网络后重试"
  state "下载完成，正在校验"

  hdiutil attach -nobrowse -readonly -quiet "$tmp/CheckClaude.dmg" -mountpoint "$mnt" 2>/dev/null \
    || fail "dmg 挂载失败"
  [[ -d "$mnt/CheckClaude.app" ]] || fail "dmg 里没有 CheckClaude.app"

  # 关键保护：Release 标签版本与 DMG 内 App 版本必须完全一致。
  # 旧包正是这里不一致，安装后仍显示 4.1 并不断提示升级。
  package_version=$(plist_version "$mnt/CheckClaude.app" || true)
  [[ "$package_version" == "$latest" ]] \
    || fail "安装包版本 ${package_version:-未知} 与发布版本 ${latest} 不一致"

  echo "→ 安装到 $APP"
  state "安装中"
  rm -rf "$staged" "$backup"
  ditto --noqtn "$mnt/CheckClaude.app" "$staged" \
    || fail "复制新版应用失败"
  codesign --force --deep --sign - "$staged" >/dev/null 2>&1 \
    || fail "新版应用签名失败"

  # 参考 beijing-time-calendar：先同卷暂存，再 rename 替换；任何失败都恢复旧版。
  if [[ -e "$APP" ]]; then
    mv "$APP" "$backup" || fail "无法备份当前版本"
  fi
  if ! mv "$staged" "$APP"; then
    [[ -e "$backup" ]] && mv "$backup" "$APP" 2>/dev/null || true
    fail "替换应用失败，已保留当前版本"
  fi
  installed_version=$(plist_version "$APP" || true)
  if [[ "$installed_version" != "$latest" ]]; then
    rm -rf "$APP"
    [[ -e "$backup" ]] && mv "$backup" "$APP" 2>/dev/null || true
    fail "安装后版本校验失败，已恢复当前版本"
  fi
  rm -rf "$backup"
  hdiutil detach "$mnt" -quiet 2>/dev/null || true
  rm -rf "$tmp"
  trap - EXIT INT TERM

  log "upgrade: ${cur} -> ${latest} 安装完成"
  notify "CheckClaude 已升级" "${cur} → ${latest}，正在重启"
  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "current=${latest}"
    echo "latest=${latest}"
    echo "hasupdate=0"
    echo "url=${url}"
  } >"$USTATUS" 2>/dev/null
  rm -f "$USTATE"

  # LaunchAgent 安装和手动双击两种启动方式都覆盖。
  if [[ "${CHECKCLAUDE_NO_RELAUNCH:-0}" != "1" ]]; then
    if ! launchctl kickstart -k "gui/$(id -u)/${AGENT}" 2>/dev/null; then
      pkill -f "$APP/Contents/MacOS/CheckClaude" 2>/dev/null || true
      sleep 1
      # 必须按完整路径打开；open -a 会按名称/Bundle ID 查找，可能误启动仓库构建副本或旧备份。
      open "$APP" 2>/dev/null || true
    fi
  fi
  echo "✅ 已升级到 v${latest}"
}

case "${1:---check}" in
  --check)   do_check ;;
  --install) do_install ;;
  *) echo "用法: $0 [--check|--install]"; exit 1 ;;
esac
