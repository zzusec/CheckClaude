#!/bin/bash
# auto-timezone.sh
# 先按 ip111.cn 的逻辑做“出口 IP 一致性检测”，再根据出口 IP 自动设置 macOS 时区。
#
# 三路视角（分别从不同目的地回显你的来源 IP）：
#   1) 国内视角   —— 访问国内网站时对方看到的 IP
#   2) 国外视角   —— 访问未被封的国外网站时对方看到的 IP
#   3) 被封/谷歌  —— 访问谷歌等被封网站时对方看到的 IP
# 三者一致 => 是干净的真实出口 IP；三者不一致 => 说明可能存在分流/PAC/泄漏。
# 系统时区始终以“被封/谷歌侧”实际出口为权威，和三路一致性检测独立防抖、独立修正。
#
# 用法：
#   ./auto-timezone.sh            # 检测一致性，并按谷歌侧出口自动校正时区
#   ./auto-timezone.sh --check    # 只做三路一致性检测并打印，不改时区
#   ./auto-timezone.sh --dry-run  # 检测 + 显示将要改的时区，但不实际改
#   ./auto-timezone.sh --force    # 兼容旧参数；时区始终按谷歌侧出口校正
#   ./auto-timezone.sh --once     # 同默认，供 launchd 调用

set -uo pipefail

# 数据目录：默认放用户的 Application Support，可用环境变量 AUTO_TZ_DIR 覆盖。
# 这样 App 自包含、可打包分发，不依赖任何硬编码用户路径。
DATA_DIR="${AUTO_TZ_DIR:-$HOME/Library/Application Support/CheckClaude}"
# v2.0 从 AutoTimezone 改名 CheckClaude，把旧数据目录搬过来 ——
# 出口稳定性要读 24h 内的历史日志，不搬会丢。
OLD_DIR="$HOME/Library/Application Support/AutoTimezone"
[[ ! -d "$DATA_DIR" && -d "$OLD_DIR" ]] && mv "$OLD_DIR" "$DATA_DIR" 2>/dev/null
mkdir -p "$DATA_DIR" 2>/dev/null || true
LOG="$DATA_DIR/auto-timezone.log"
# 日志轮转：超过 5MB 就只留最后 2000 行。它会被“出口稳定性”逐行扫，不能让它无限长。
if [[ -f "$LOG" ]] && [[ $(stat -f %z "$LOG" 2>/dev/null || echo 0) -gt 5242880 ]]; then
  tail -2000 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi
STATE="$DATA_DIR/last_state"          # 上次已确认的“出口IP|是否一致”，用于变化告警
STATUS="$DATA_DIR/status"             # 给菜单栏 App 读取的快照（key=value）
PROBE_STATE="$DATA_DIR/probe_state"   # 网络波动计数和待确认候选
HISTORY="$DATA_DIR/network_history"    # 最近 24 小时分路成功状态与耗时
LOCK_DIR="$DATA_DIR/scan.lock"        # mkdir 原子锁，避免多个检测任务并发写状态
CONFIRM_REQUIRED=2
LOCK_TTL=180
HISTORY_WINDOW=86400
UNSUPPORTED_COUNTRIES="CN HK MO RU IR KP CU SY BY VE"

MODE="run"
case "${1:-}" in
  --check)   MODE="check" ;;
  --dry-run) MODE="dryrun" ;;
  --force)   MODE="force" ;;
esac

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >>"$LOG" 2>/dev/null || true
}

# 弹 macOS 桌面通知。root 守护进程需注入到登录用户的图形会话。
notify() {
  local title="$1" msg="$2"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    local u uid
    u=$(stat -f%Su /dev/console 2>/dev/null)
    uid=$(id -u "$u" 2>/dev/null)
    [[ -n "$uid" ]] && launchctl asuser "$uid" sudo -u "$u" \
      osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Submarine\"" >/dev/null 2>&1
  else
    osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Submarine\"" >/dev/null 2>&1
  fi
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# 状态快照必须先完整写到同目录临时文件，再原子替换；菜单栏不会读到半截内容。
write_status() {
  local consistent="$1" cn="$2" intl="$3" gfw="$4" google="$5" gfwtz="$6"
  local network="$7" failures="$8" confirmations="$9" detail="${10}" last_success="${11}"
  local tmp="${STATUS}.tmp.$$" current_tz timezone_synced="?"
  current_tz=$(current_timezone)
  if [[ "$gfwtz" == */* ]]; then
    [[ "$current_tz" == "$gfwtz" ]] && timezone_synced=1 || timezone_synced=0
  fi
  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "consistent=$consistent"
    echo "cn=$cn"
    echo "intl=$intl"
    echo "gfw=$gfw"
    echo "google=$google"
    echo "gfwtz=$gfwtz"
    echo "tz=$current_tz"
    echo "timezone_ip=${TIMEZONE_IP:-}"
    echo "timezone_synced=$timezone_synced"
    echo "network=$network"
    echo "failure_count=$failures"
    echo "confirm_count=$confirmations"
    echo "confirm_required=$CONFIRM_REQUIRED"
    echo "network_detail=$detail"
    echo "timezone_confirm_count=${PENDING_TZ_COUNT:-0}"
    echo "timezone_confirm_required=$CONFIRM_REQUIRED"
    echo "timezone_detail=${TIMEZONE_DETAIL:-}"
    echo "last_success=$last_success"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$STATUS" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

write_probe_state() {
  local tmp="${PROBE_STATE}.tmp.$$"
  {
    echo "stable_ip=$STABLE_IP"
    echo "stable_consistent=$STABLE_CONSISTENT"
    echo "failure_count=$FAILURE_COUNT"
    echo "pending_key=$PENDING_KEY"
    echo "pending_count=$PENDING_COUNT"
    echo "network=$NETWORK_STATE"
    echo "last_success=$LAST_SUCCESS"
    echo "stable_timezone=$STABLE_TIMEZONE"
    echo "timezone_ip=$TIMEZONE_IP"
    echo "pending_timezone_ip=$PENDING_TIMEZONE_IP"
    echo "pending_timezone_ip_count=$PENDING_TIMEZONE_IP_COUNT"
    echo "pending_timezone=$PENDING_TIMEZONE"
    echo "pending_timezone_count=$PENDING_TZ_COUNT"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$PROBE_STATE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

write_confirmed_state() {
  local value="$1" tmp="${STATE}.tmp.$$"
  printf '%s\n' "$value" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$STATE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# 一行一个检测样本。前 13 列兼容旧版；后 16 列为四路 HTTPS/TCP 指标：
# 每路依次追加 TCP connect、TLS、TTFB、HTTP 状态码（耗时单位均为秒）。
# 写入时顺便裁掉 24 小时以前的数据，并限制最多 5000 行，手动频繁检测也不会无限增长。
record_history() {
  local result="$1" ip="$2" changed="$3"
  local now cutoff tmp
  now=$(date +%s); cutoff=$(( now - HISTORY_WINDOW )); tmp="${HISTORY}.tmp.$$"
  {
    if [[ -f "$HISTORY" ]]; then
      awk -F'|' -v cutoff="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= cutoff' "$HISTORY" 2>/dev/null | tail -n 4999
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$now" "$PROBE_SECONDS" "$result" "${ip:-?}" "$changed" \
      "$CN_SECONDS" "$CN_OK" "$INTL_SECONDS" "$INTL_OK" \
      "$GFW_SECONDS" "$GFW_OK" "$GOOGLE_SECONDS" "$GOOGLE_OK" \
      "$CN_CONNECT_SECONDS" "$CN_TLS_SECONDS" "$CN_TTFB_SECONDS" "$CN_HTTP_CODE" \
      "$INTL_CONNECT_SECONDS" "$INTL_TLS_SECONDS" "$INTL_TTFB_SECONDS" "$INTL_HTTP_CODE" \
      "$GFW_CONNECT_SECONDS" "$GFW_TLS_SECONDS" "$GFW_TTFB_SECONDS" "$GFW_HTTP_CODE" \
      "$GOOGLE_CONNECT_SECONDS" "$GOOGLE_TLS_SECONDS" "$GOOGLE_TTFB_SECONDS" "$GOOGLE_HTTP_CODE"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$HISTORY" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# 读取上次菜单快照。网络波动期间沿用这些已确认值，只更新波动状态。
read_snapshot() {
  SNAP_CONSISTENT=""; SNAP_CN=""; SNAP_INTL=""; SNAP_GFW=""; SNAP_GOOGLE=""
  SNAP_GFWTZ=""; SNAP_LAST_SUCCESS=""
  [[ -f "$STATUS" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      consistent) SNAP_CONSISTENT="$v" ;; cn) SNAP_CN="$v" ;; intl) SNAP_INTL="$v" ;;
      gfw) SNAP_GFW="$v" ;; google) SNAP_GOOGLE="$v" ;; gfwtz) SNAP_GFWTZ="$v" ;;
      last_success) SNAP_LAST_SUCCESS="$v" ;;
    esac
  done <"$STATUS"
}

load_probe_state() {
  STABLE_IP=""; STABLE_CONSISTENT=""; FAILURE_COUNT=0; PENDING_KEY=""; PENDING_COUNT=0
  NETWORK_STATE="ok"; LAST_SUCCESS=""; STABLE_TIMEZONE=""; TIMEZONE_IP=""
  PENDING_TIMEZONE_IP=""; PENDING_TIMEZONE_IP_COUNT=0
  PENDING_TIMEZONE=""; PENDING_TZ_COUNT=0; TIMEZONE_DETAIL=""
  local k v
  if [[ -f "$PROBE_STATE" ]]; then
    while IFS='=' read -r k v; do
      case "$k" in
        stable_ip) STABLE_IP="$v" ;; stable_consistent) STABLE_CONSISTENT="$v" ;;
        failure_count) FAILURE_COUNT="$v" ;; pending_key) PENDING_KEY="$v" ;;
        pending_count) PENDING_COUNT="$v" ;; network) NETWORK_STATE="$v" ;;
        last_success) LAST_SUCCESS="$v" ;;
        stable_timezone) STABLE_TIMEZONE="$v" ;; timezone_ip) TIMEZONE_IP="$v" ;;
        pending_timezone_ip) PENDING_TIMEZONE_IP="$v" ;;
        pending_timezone_ip_count) PENDING_TIMEZONE_IP_COUNT="$v" ;;
        pending_timezone) PENDING_TIMEZONE="$v" ;;
        pending_timezone_count) PENDING_TZ_COUNT="$v" ;;
      esac
    done <"$PROBE_STATE"
  fi
  [[ "$FAILURE_COUNT" =~ ^[0-9]+$ ]] || FAILURE_COUNT=0
  [[ "$PENDING_COUNT" =~ ^[0-9]+$ ]] || PENDING_COUNT=0
  [[ "$PENDING_TIMEZONE_IP_COUNT" =~ ^[0-9]+$ ]] || PENDING_TIMEZONE_IP_COUNT=0
  [[ "$PENDING_TZ_COUNT" =~ ^[0-9]+$ ]] || PENDING_TZ_COUNT=0

  # 从旧版本升级时没有 probe_state；用既有 last_state/status 建立有效基线，避免首次失败清空 IP。
  if [[ -z "$STABLE_IP" && -f "$STATE" ]]; then
    local old
    old=$(cat "$STATE" 2>/dev/null)
    local old_ip="${old%%|*}" old_ok="${old##*|}"
    if is_ipv4 "$old_ip"; then
      STABLE_IP="$old_ip"
      STABLE_CONSISTENT="$old_ok"
    fi
  fi
  [[ -n "$LAST_SUCCESS" ]] || LAST_SUCCESS="$SNAP_LAST_SUCCESS"
  [[ -n "$STABLE_CONSISTENT" ]] || STABLE_CONSISTENT="$SNAP_CONSISTENT"
  [[ -n "$STABLE_TIMEZONE" ]] || STABLE_TIMEZONE="$SNAP_GFWTZ"
  # v4.4 以前没有独立的时区权威出口；可从已确认谷歌侧出口平滑迁移。
  if [[ -z "$TIMEZONE_IP" ]]; then
    if is_ipv4 "$SNAP_GFW"; then TIMEZONE_IP="$SNAP_GFW"
    elif is_ipv4 "$STABLE_IP"; then TIMEZONE_IP="$STABLE_IP"
    fi
  fi
}

# 网络暂时失败时保留上次确认的三路 IP；没有历史时才显示本次拿到的部分结果。
write_preserved_status() {
  local network="$1" failures="$2" confirmations="$3" detail="$4"
  local out_consistent="${SNAP_CONSISTENT:-0}"
  local out_cn="${SNAP_CN:-${cn:-?}}"
  local out_intl="${SNAP_INTL:-${intl:-?}}"
  local out_gfw="${SNAP_GFW:-${gfw:-?}}"
  local out_google="${goog:-${SNAP_GOOGLE:-?}}"
  local out_gfwtz="${STABLE_TIMEZONE:-${SNAP_GFWTZ:-?}}"
  write_status "$out_consistent" "$out_cn" "$out_intl" "$out_gfw" "$out_google" \
    "$out_gfwtz" "$network" "$failures" "$confirmations" "$detail" "$LAST_SUCCESS"
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi

  local now mtime age
  now=$(date +%s)
  mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo "$now")
  age=$(( now - mtime ))
  # 正常检测最长小于三分钟；只清理崩溃遗留的空目录，不抢正在运行的任务。
  if [[ $age -gt $LOCK_TTL ]] && rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null; then
    log "清理超过 ${LOCK_TTL} 秒的检测锁"
    return 0
  fi
  log "已有出口检测正在运行，本次跳过"
  return 1
}

release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }

CURL='curl -LfsS --connect-timeout 5 --max-time 9 -A Mozilla/5.0'

is_decimal() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
normal_decimal() { is_decimal "$1" && printf '%s' "$1" || printf '0'; }
sum_decimal() { awk -v a="$(normal_decimal "$1")" -v b="$(normal_decimal "$2")" 'BEGIN { printf "%.6f", a + b }'; }

# 从一组 HTTPS 候选 URL 里取到第一个合法 IPv4，并返回该次 HTTPS/TCP 指标：
# IP|TCP connect|TLS|TTFB|累计 total|HTTP code。失败也返回累计耗时，便于趋势图反映真实波动。
get_first_ip() {
  local url ip body_file metrics connect tls ttfb total code
  local accumulated="0" last_code="000"
  for url in "$@"; do
    body_file=$(mktemp "$DATA_DIR/.https-probe.XXXXXX") || return 1
    metrics=$($CURL -o "$body_file" \
      -w '%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{http_code}' \
      "$url" 2>/dev/null) || true
    IFS='|' read -r connect tls ttfb total code <<<"$metrics"
    connect=$(normal_decimal "$connect"); tls=$(normal_decimal "$tls")
    ttfb=$(normal_decimal "$ttfb"); total=$(normal_decimal "$total")
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    accumulated=$(sum_decimal "$accumulated" "$total")
    last_code="$code"
    ip=$(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$body_file" 2>/dev/null | head -1)
    rm -f "$body_file" 2>/dev/null || true
    if is_ipv4 "$ip" && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
      printf '%s|%s|%s|%s|%s|%s\n' "$ip" "$connect" "$tls" "$ttfb" "$accumulated" "$code"
      return 0
    fi
  done
  printf '?|0|0|0|%s|%s\n' "$accumulated" "$last_code"
  return 1
}

# 四路质量探测都使用 HTTPS over TCP，不再用 ICMP/ping，也不再用明文 HTTP。
ip_china() {
  get_first_ip \
    "https://ip.3322.net" \
    "https://whois.pconline.com.cn/ipJson.jsp?json=true" \
    "https://api.live.bilibili.com/xlive/web-room/v1/index/getIpInfo" \
    "https://myip.ipip.net"
}

ip_intl() {
  get_first_ip \
    "https://api.ipify.org" \
    "https://icanhazip.com" \
    "https://ipinfo.io/ip" \
    "https://ifconfig.me/ip"
}

# 被封/谷歌侧视角：作为 Claude/Google 实际路径与系统时区的权威出口。
ip_gfw() {
  get_first_ip \
    "https://www.cloudflare.com/cdn-cgi/trace" \
    "https://api.ip.sb/ip" \
    "https://api.myip.com"
}

# Google HTTPS 204 同时返回 TCP/TLS/TTFB/total/HTTP code；返回值表示线路是否可用。
google_reachable() {
  local metrics connect tls ttfb total code
  metrics=$($CURL -o /dev/null \
    -w '%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{http_code}' \
    "https://www.google.com/generate_204" 2>/dev/null) || true
  IFS='|' read -r connect tls ttfb total code <<<"$metrics"
  printf '%s|%s|%s|%s|%s\n' \
    "$(normal_decimal "$connect")" "$(normal_decimal "$tls")" \
    "$(normal_decimal "$ttfb")" "$(normal_decimal "$total")" "${code:-000}"
  [[ "$code" == "204" || "$code" == "200" ]]
}

# 解析单路探测结果并写入统一指标变量；测试桩只返回 IP 时也保持兼容。
run_ip_route() {
  local prefix="$1" func="$2" payload="" rc=0 ip connect tls ttfb total code
  payload=$($func) || rc=$?
  if [[ "$payload" == *'|'* ]]; then
    IFS='|' read -r ip connect tls ttfb total code <<<"$payload"
  else
    ip="$payload"; connect=0; tls=0; ttfb=0; total=0; code=0
  fi
  is_ipv4 "$ip" || ip=""
  [[ $rc -eq 0 && -n "$ip" ]] || rc=1
  printf -v ROUTE_IP '%s' "$ip"
  printf -v "${prefix}_CONNECT_SECONDS" '%s' "$(normal_decimal "$connect")"
  printf -v "${prefix}_TLS_SECONDS" '%s' "$(normal_decimal "$tls")"
  printf -v "${prefix}_TTFB_SECONDS" '%s' "$(normal_decimal "$ttfb")"
  printf -v "${prefix}_SECONDS" '%s' "$(normal_decimal "$total")"
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=0
  printf -v "${prefix}_HTTP_CODE" '%s' "$code"
  [[ $rc -eq 0 ]]
}

# 用 IANA 时区库文件校验时区合法（无需 sudo）。
is_valid_timezone() { [[ -f "/usr/share/zoneinfo/$1" ]]; }

# 读当前系统时区：/etc/localtime 软链，无需 sudo。
current_timezone() {
  local tz
  tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
  echo "${tz:-(unknown)}"
}

# 取某个 IP 对应的 IANA 时区。三路情报均使用 HTTPS。
ip_timezone() {
  local ip="$1" tz
  tz=$($CURL "https://ipinfo.io/${ip}/json" 2>/dev/null \
        | grep -Eo '"timezone"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | grep -Eo '[A-Za-z_]+/[A-Za-z_/]+' | head -1)
  [[ "$tz" == */* ]] && { echo "$tz"; return 0; }
  tz=$($CURL "https://ipapi.co/${ip}/timezone" 2>/dev/null)
  [[ "$tz" == */* ]] && { echo "$tz"; return 0; }
  tz=$($CURL "https://ipwho.is/${ip}?fields=timezone" 2>/dev/null \
        | grep -Eo '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | grep -Eo '[A-Za-z_]+/[A-Za-z_/]+' | head -1)
  [[ "$tz" == */* ]] && { echo "$tz"; return 0; }
  return 1
}

# 只用于阻止后台跟随明确不支持的出口修改系统时区。接口不可达时保持原行为，
# 不因单个国家情报源失败而阻断已经确认的时区同步。
ip_country() {
  local ip="$1" cc
  cc=$($CURL "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  [[ "$cc" =~ ^[A-Z]{2}$ ]] && { echo "$cc"; return 0; }
  cc=$($CURL "https://ipwho.is/${ip}?fields=country_code" 2>/dev/null \
    | grep -Eo '"country_code"[[:space:]]*:[[:space:]]*"[A-Za-z]{2}"' \
    | grep -Eo '[A-Za-z]{2}"$' | tr -d '"' | tr '[:lower:]' '[:upper:]')
  [[ "$cc" =~ ^[A-Z]{2}$ ]] && { echo "$cc"; return 0; }
  return 1
}

apply_timezone() {
  local target current
  target="$1"
  current=$(current_timezone)

  if ! is_valid_timezone "$target"; then
    log "目标时区 '$target' 非法，跳过"; return 1
  fi
  if [[ "$target" == "$current" ]]; then
    log "系统时区已是 ${target}，无需修改"; return 0
  fi
  if [[ "$MODE" == "dryrun" ]]; then
    log "[dry-run] 将把系统时区: $current -> $target"; return 0
  fi
  if set_timezone "$target"; then
    log "已切换系统时区: $current -> $target"
  else
    log "需改时区 $current -> $target，但未配置免密。请运行一次: sudo bash enable-auto-timezone.sh"; return 1
  fi
}

# 改时区（需管理员）。root 直接 / 免密 sudo（需先运行 enable-auto-timezone.sh）。
# 不再自动弹 osascript 授权框，避免每分钟反复打扰；没配免密就跳过并在日志提示。
set_timezone() {
  local tz="$1"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    /usr/sbin/systemsetup -settimezone "$tz" >/dev/null 2>&1 && return 0
  fi
  sudo -n /usr/sbin/systemsetup -settimezone "$tz" >/dev/null 2>&1 && return 0
  return 1
}

# 同一个已确认出口 IP 的时区不应在几分钟内跨洲跳变。第三方情报源单次
# 返回不同结果时先沿用上次时区，连续两次相同才接受；确认的新 IP 则立即采用。
confirm_timezone_candidate() {
  local tz_ip="$1" previous_ip="$2" candidate="$3"
  local baseline="$STABLE_TIMEZONE"
  [[ "$baseline" == */* ]] || baseline="$SNAP_GFWTZ"
  CONFIRMED_TIMEZONE="$candidate"
  TIMEZONE_DETAIL=""

  if [[ "$candidate" != */* ]]; then
    if [[ "$tz_ip" == "$previous_ip" && "$baseline" == */* ]]; then
      CONFIRMED_TIMEZONE="$baseline"
    fi
    return 0
  fi

  if [[ "$tz_ip" == "$previous_ip" && "$baseline" == */* && "$candidate" != "$baseline" ]]; then
    if [[ "$PENDING_TIMEZONE" == "$candidate" ]]; then
      PENDING_TZ_COUNT=$(( PENDING_TZ_COUNT + 1 ))
    else
      PENDING_TIMEZONE="$candidate"
      PENDING_TZ_COUNT=1
    fi

    if [[ $PENDING_TZ_COUNT -lt $CONFIRM_REQUIRED ]]; then
      CONFIRMED_TIMEZONE="$baseline"
      TIMEZONE_DETAIL="时区变化复核中：${candidate}（${PENDING_TZ_COUNT}/${CONFIRM_REQUIRED}）"
      log "⏳ 同一出口 IP 的时区变化待确认：${baseline} -> ${candidate}（${PENDING_TZ_COUNT}/${CONFIRM_REQUIRED}），暂不修改系统时区"
      return 1
    fi
  fi

  STABLE_TIMEZONE="$candidate"
  PENDING_TIMEZONE=""
  PENDING_TZ_COUNT=0
  return 0
}


# 谷歌侧出口独立于国内/国外辅助探针确认。这样即使辅助接口波动，只要实际
# Claude/Google 路径连续两次确认，系统时区仍会自动修正并在以后每轮防漂移。
sync_timezone_from_gfw() {
  local candidate_ip="$1" previous_ip="$TIMEZONE_IP" raw_timezone="" target_timezone="" country=""
  is_ipv4 "$candidate_ip" || return 1

  if [[ -n "$previous_ip" && "$candidate_ip" != "$previous_ip" ]]; then
    if [[ "$PENDING_TIMEZONE_IP" == "$candidate_ip" ]]; then
      PENDING_TIMEZONE_IP_COUNT=$(( PENDING_TIMEZONE_IP_COUNT + 1 ))
    else
      PENDING_TIMEZONE_IP="$candidate_ip"
      PENDING_TIMEZONE_IP_COUNT=1
    fi
    if [[ $PENDING_TIMEZONE_IP_COUNT -lt $CONFIRM_REQUIRED ]]; then
      TIMEZONE_DETAIL="时区权威出口变化复核中：${candidate_ip}（${PENDING_TIMEZONE_IP_COUNT}/${CONFIRM_REQUIRED}）"
      log "⏳ 谷歌侧出口变化待确认：${previous_ip} -> ${candidate_ip}（${PENDING_TIMEZONE_IP_COUNT}/${CONFIRM_REQUIRED}），暂不修改系统时区"
      return 1
    fi
  else
    PENDING_TIMEZONE_IP=""
    PENDING_TIMEZONE_IP_COUNT=0
  fi

  raw_timezone=$(ip_timezone "$candidate_ip") || raw_timezone=""
  if [[ "$raw_timezone" != */* ]]; then
    if [[ "$candidate_ip" == "$previous_ip" && "$STABLE_TIMEZONE" == */* ]]; then
      raw_timezone="$STABLE_TIMEZONE"
      log "  IP 时区接口暂时不可达，沿用已确认时区: ${raw_timezone}"
    else
      TIMEZONE_DETAIL="已确认谷歌侧出口 ${candidate_ip}，等待 HTTPS 时区情报"
      log "无法解析谷歌侧出口 IP(${candidate_ip})的时区，保留当前系统时区并等待重试"
      return 1
    fi
  fi

  confirm_timezone_candidate "$candidate_ip" "$previous_ip" "$raw_timezone" || true
  target_timezone="$CONFIRMED_TIMEZONE"
  [[ "$target_timezone" == */* ]] || return 1

  # IP 与 IANA 时区作为一对提交，避免新 IP 已写入但时区情报尚未就绪。
  TIMEZONE_IP="$candidate_ip"
  PENDING_TIMEZONE_IP=""
  PENDING_TIMEZONE_IP_COUNT=0
  log "  时区权威出口 ${TIMEZONE_IP} 对应 IANA 时区: ${target_timezone}"

  country=$(ip_country "$candidate_ip") || country=""
  if [[ -n "$country" ]] && in_list "$country" "$UNSUPPORTED_COUNTRIES"; then
    TIMEZONE_DETAIL="出口国家 ${country} 不支持 Claude，仅展示对应时区 ${target_timezone}，不自动修改"
    log "  出口国家 ${country} 不支持 Claude，跳过系统时区自动修改"
    return 0
  fi

  if [[ "$MODE" != "check" ]]; then
    apply_timezone "$target_timezone" || true
  fi
  return 0
}

handle_incomplete_probe() {
  FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
  PENDING_KEY=""; PENDING_COUNT=0
  local missing=""
  [[ -z "$cn" ]] && missing="${missing}国内/"
  [[ -z "$intl" ]] && missing="${missing}国外/"
  [[ -z "$gfw" ]] && missing="${missing}谷歌侧/"
  missing="${missing%/}"

  if [[ $FAILURE_COUNT -ge $CONFIRM_REQUIRED ]]; then
    NETWORK_STATE="unstable"
  else
    NETWORK_STATE="verifying"
  fi
  local detail="${missing}获取失败；沿用上次有效结果"
  write_probe_state
  write_preserved_status "$NETWORK_STATE" "$FAILURE_COUNT" 0 "$detail"
  record_history "failure" "${gfw:-${intl:-${STABLE_IP:-?}}}" 0
  log "⏳ 出口探测接口波动：${missing}获取失败（连续 ${FAILURE_COUNT} 次），保留出口 ${STABLE_IP:-未知}"
  return 1
}

confirm_or_commit_probe() {
  local tz_ip="$1" consistent="$2"
  local candidate_key="${tz_ip}|${consistent}|${cn}|${intl}|${gfw}"
  local needs_confirmation=0

  if [[ -n "$STABLE_IP" ]] && { [[ "$NETWORK_STATE" != "ok" ]] || [[ "$tz_ip" != "$STABLE_IP" ]] || [[ "$consistent" != "$STABLE_CONSISTENT" ]]; }; then
    needs_confirmation=1
  fi

  if [[ $needs_confirmation -eq 1 ]]; then
    if [[ "$PENDING_KEY" == "$candidate_key" ]]; then
      PENDING_COUNT=$(( PENDING_COUNT + 1 ))
    else
      PENDING_KEY="$candidate_key"
      PENDING_COUNT=1
    fi
    FAILURE_COUNT=0

    if [[ $PENDING_COUNT -lt $CONFIRM_REQUIRED ]]; then
      NETWORK_STATE="verifying"
      local detail="有效结果复核中；沿用上次有效结果"
      write_probe_state
      write_preserved_status "$NETWORK_STATE" 0 "$PENDING_COUNT" "$detail"
      record_history "verifying" "$tz_ip" 0
      log "⏳ 出口结果待确认：${tz_ip}（${PENDING_COUNT}/${CONFIRM_REQUIRED}），暂不替换 ${STABLE_IP}"
      return 1
    fi
  fi

  # 首次有效结果、稳定状态的常规刷新，或候选连续两次确认后，在这里正式提交。
  local previous_stable="$STABLE_IP" confirmed_change=0
  if is_ipv4 "$previous_stable" && [[ "$previous_stable" != "$tz_ip" ]]; then confirmed_change=1; fi
  STABLE_IP="$tz_ip"
  STABLE_CONSISTENT="$consistent"
  FAILURE_COUNT=0; PENDING_KEY=""; PENDING_COUNT=0; NETWORK_STATE="ok"
  LAST_SUCCESS=$(date '+%Y-%m-%d %H:%M:%S')

  local gfwtz="$STABLE_TIMEZONE"
  log "  谷歌侧出口 ${tz_ip}；时区权威出口 ${TIMEZONE_IP:-待确认} 对应时区: ${gfwtz:-解析失败}"

  write_status "$consistent" "$cn" "$intl" "$gfw" "$goog" "${gfwtz:-?}" \
    "ok" 0 0 "三路探测完成" "$LAST_SUCCESS"
  write_probe_state
  if [[ "$consistent" == "1" ]]; then
    record_history "stable" "$tz_ip" "$confirmed_change"
  else
    record_history "inconsistent" "$tz_ip" "$confirmed_change"
  fi

  # 只有已确认的有效 IP/一致性变化才告警；获取失败永远不会写成 none。
  if [[ "$MODE" != "check" ]]; then
    local prev_state=""; [[ -f "$STATE" ]] && prev_state=$(cat "$STATE" 2>/dev/null)
    local cur_state="${tz_ip}|${consistent}"
    if [[ -n "$prev_state" && "$prev_state" != "$cur_state" ]]; then
      local prev_ip="${prev_state%%|*}" prev_ok="${prev_state##*|}"
      # 旧版本可能把获取失败写成 none；升级后的第一次成功只重建基线，不再补发 none -> IP。
      if is_ipv4 "$prev_ip"; then
        if [[ "$prev_ip" != "$tz_ip" ]]; then
          log "🔔 出口 IP 变化: ${prev_ip} -> ${tz_ip}"
          notify "出口 IP 变化" "${prev_ip} → ${tz_ip}"
        fi
        if [[ "$prev_ok" != "$consistent" ]]; then
          if [[ "$consistent" == "1" ]]; then
            notify "出口已恢复正常" "三路 IP 一致: ${tz_ip}"
          else
            notify "⚠️ 出口 IP 异常" "三路不一致（疑似分流/泄漏）"
          fi
        fi
      fi
    fi
    write_confirmed_state "$cur_state"
  fi

  if [[ "$MODE" == "check" ]]; then
    [[ "$consistent" == "1" ]]
    return
  fi

  [[ "$consistent" != "1" ]] && log "注意: 三路 IP 不一致（已确认）；系统时区仍独立跟随谷歌侧权威出口 ${TIMEZONE_IP:-待确认}"
  [[ "$gfwtz" == */* ]]
}

main_locked() {
  log "开始三路出口 IP 一致性检测（HTTPS/TCP）..."
  local google_payload="" google_rc=0 connect tls ttfb total code

  if run_ip_route CN ip_china; then CN_OK=1; else CN_OK=0; fi
  cn="$ROUTE_IP"
  if run_ip_route INTL ip_intl; then INTL_OK=1; else INTL_OK=0; fi
  intl="$ROUTE_IP"
  if run_ip_route GFW ip_gfw; then GFW_OK=1; else GFW_OK=0; fi
  gfw="$ROUTE_IP"

  google_payload=$(google_reachable) || google_rc=$?
  IFS='|' read -r connect tls ttfb total code <<<"$google_payload"
  GOOGLE_CONNECT_SECONDS=$(normal_decimal "$connect")
  GOOGLE_TLS_SECONDS=$(normal_decimal "$tls")
  GOOGLE_TTFB_SECONDS=$(normal_decimal "$ttfb")
  GOOGLE_SECONDS=$(normal_decimal "$total")
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=0
  GOOGLE_HTTP_CODE="$code"
  if [[ $google_rc -eq 0 ]]; then goog="可达"; GOOGLE_OK=1; else goog="不可达"; GOOGLE_OK=0; fi

  PROBE_SECONDS=$(awk -v a="$CN_SECONDS" -v b="$INTL_SECONDS" -v c="$GFW_SECONDS" -v d="$GOOGLE_SECONDS" \
    'BEGIN { printf "%.6f", a + b + c + d }')

  log "  国内视角 : ${cn:-获取失败}（HTTPS total ${CN_SECONDS}s, TCP ${CN_CONNECT_SECONDS}s, TLS ${CN_TLS_SECONDS}s, TTFB ${CN_TTFB_SECONDS}s, HTTP ${CN_HTTP_CODE}）"
  log "  国外视角 : ${intl:-获取失败}（HTTPS total ${INTL_SECONDS}s, TCP ${INTL_CONNECT_SECONDS}s, TLS ${INTL_TLS_SECONDS}s, TTFB ${INTL_TTFB_SECONDS}s, HTTP ${INTL_HTTP_CODE}）"
  log "  被封/谷歌: ${gfw:-获取失败}（HTTPS total ${GFW_SECONDS}s, TCP ${GFW_CONNECT_SECONDS}s, TLS ${GFW_TLS_SECONDS}s, TTFB ${GFW_TTFB_SECONDS}s, HTTP ${GFW_HTTP_CODE}）"
  log "  Google 204: ${goog}（HTTPS total ${GOOGLE_SECONDS}s, TCP ${GOOGLE_CONNECT_SECONDS}s, TLS ${GOOGLE_TLS_SECONDS}s, TTFB ${GOOGLE_TTFB_SECONDS}s, HTTP ${GOOGLE_HTTP_CODE}）"

  # 时区校正只依赖真正访问 Claude/Google 的谷歌侧出口，不再被国内/国外辅助接口阻塞。
  if is_ipv4 "$gfw"; then
    sync_timezone_from_gfw "$gfw" || true
  else
    TIMEZONE_DETAIL="谷歌侧 HTTPS 出口获取失败，保留已确认时区并等待重试"
  fi

  if [[ -z "$cn" || -z "$intl" || -z "$gfw" ]]; then
    handle_incomplete_probe
    return
  fi

  local consistent=0
  if [[ "$cn" == "$intl" && "$intl" == "$gfw" ]]; then
    consistent=1
    log "✅ 三路 IP 一致 (${intl})，是干净的真实出口 IP"
  else
    log "⚠️  三路 IP 不一致 —— 出口 IP 有问题（疑似分流/PAC/DNS泄漏）"
  fi

  confirm_or_commit_probe "$gfw" "$consistent"
}

main() {
  read_snapshot
  load_probe_state
  acquire_lock || return 0
  trap 'release_lock' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  main_locked
  local rc=$?
  release_lock
  trap - EXIT INT TERM
  return $rc
}

# 自测会 source 本文件并覆盖网络函数；正常执行则直接运行。
if [[ "${AUTO_TZ_SELFTEST:-0}" != "1" ]]; then
  main "$@"
fi
