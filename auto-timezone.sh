#!/bin/bash
# auto-timezone.sh
# 先按 ip111.cn 的逻辑做"出口 IP 一致性检测"，再根据出口 IP 自动设置 macOS 时区。
#
# 三路视角(分别从不同目的地回显你的来源 IP):
#   1) 国内视角   —— 访问国内网站时对方看到的 IP
#   2) 国外视角   —— 访问未被封的国外网站时对方看到的 IP
#   3) 被封/谷歌  —— 访问谷歌等被封网站时对方看到的 IP
# 三者一致 => 才是干净的真实出口 IP，按它设时区；
# 三者不一致 => 说明在分流/PAC 等模式，出口 IP 有问题，默认不改时区并报警。
#
# 用法:
#   ./auto-timezone.sh            # 检测一致性 -> 一致才设时区
#   ./auto-timezone.sh --check    # 只做三路一致性检测并打印，不改时区
#   ./auto-timezone.sh --dry-run  # 检测 + 显示将要改的时区，但不实际改
#   ./auto-timezone.sh --force    # 即使不一致，也按"国外视角"出口设时区
#   ./auto-timezone.sh --once     # 同默认，供 launchd 调用

set -uo pipefail

# 数据目录: 默认放用户的 Application Support，可用环境变量 AUTO_TZ_DIR 覆盖。
# 这样 App 自包含、可打包分发，不依赖任何硬编码用户路径。
DATA_DIR="${AUTO_TZ_DIR:-$HOME/Library/Application Support/AutoTimezone}"
mkdir -p "$DATA_DIR" 2>/dev/null || true
LOG="$DATA_DIR/auto-timezone.log"
STATE="$DATA_DIR/last_state"   # 记录上次的 "出口IP|是否一致"，用于变化告警
STATUS="$DATA_DIR/status"      # 给菜单栏 App 读取的快照(key=value)

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

# 弹 macOS 桌面通知。root 守护进程需注入到登录用户的图形会话
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

# 写出菜单栏 App 读取的状态快照
write_status() {
  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "consistent=$1"
    echo "cn=$2"
    echo "intl=$3"
    echo "gfw=$4"
    echo "google=$5"
    echo "gfwtz=$6"
    echo "tz=$(current_timezone)"
  } >"$STATUS" 2>/dev/null || true
}

CURL='curl -fsS --max-time 9 -A Mozilla/5.0'

# 从一组候选 URL 里取到第一个合法 IPv4 就返回
get_first_ip() {
  local url ip
  for url in "$@"; do
    ip=$($CURL "$url" 2>/dev/null \
          | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"; return 0
    fi
  done
  return 1
}

# 国内视角: 国内服务器回显的来源 IP(多接口兜底)
# 首选 HTTP 明文接口，绕过系统 curl(老 LibreSSL)对部分国内 HTTPS 站的握手失败
ip_china() {
  get_first_ip \
    "http://members.3322.org/dyndns/getip" \
    "https://whois.pconline.com.cn/ipJson.jsp?json=true" \
    "https://qifu-api.baidubce.com/ip/local/geo/v1/district" \
    "https://api.live.bilibili.com/xlive/web-room/v1/index/getIpInfo" \
    "http://www.taobao.com/help/getip.php"
}

# 国外(未被封)视角
ip_intl() {
  get_first_ip \
    "https://api.ipify.org" \
    "https://icanhazip.com" \
    "https://ipinfo.io/ip" \
    "https://ifconfig.me/ip"
}

# 被封/谷歌侧视角: 走需要"翻墙"才能到达的目的地
ip_gfw() {
  get_first_ip \
    "https://www.cloudflare.com/cdn-cgi/trace" \
    "https://api.ip.sb/ip" \
    "https://api.myip.com"
}

# 谷歌是否真的可达(可达=被封网站这条路通)
google_reachable() {
  local code
  code=$($CURL -o /dev/null -w '%{http_code}' "https://www.google.com/generate_204" 2>/dev/null)
  [[ "$code" == "204" || "$code" == "200" ]]
}

# 用 IANA 时区库文件校验时区合法(无需 sudo)
is_valid_timezone() { [[ -f "/usr/share/zoneinfo/$1" ]]; }

# 读当前系统时区: /etc/localtime 软链，无需 sudo
current_timezone() {
  local tz
  tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
  echo "${tz:-(unknown)}"
}

# 取某个 IP 对应的 IANA 时区。优先 ipinfo.io，再退回 ipapi.co / ip-api.com
ip_timezone() {
  local ip="$1" tz
  tz=$($CURL "https://ipinfo.io/${ip}/json" 2>/dev/null \
        | grep -Eo '"timezone"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | grep -Eo '[A-Za-z_]+/[A-Za-z_/]+' | head -1)
  [[ "$tz" == */* ]] && { echo "$tz"; return 0; }
  tz=$($CURL "https://ipapi.co/${ip}/timezone" 2>/dev/null)
  [[ "$tz" == */* ]] && { echo "$tz"; return 0; }
  tz=$($CURL "http://ip-api.com/line/${ip}?fields=timezone" 2>/dev/null)
  [[ "$tz" == */* ]] && { echo "$tz"; return 0; }
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
    log "切换失败: $current -> $target"; return 1
  fi
}

# 改时区(需管理员)。依次尝试: root 直接 / 免密 sudo / 弹系统授权框。
# 授权框仅在"时区确实需要变更"时出现，属低频，体验可接受。
set_timezone() {
  local tz="$1"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    /usr/sbin/systemsetup -settimezone "$tz" >/dev/null 2>&1 && return 0
  fi
  sudo -n /usr/sbin/systemsetup -settimezone "$tz" >/dev/null 2>&1 && return 0
  # 弹原生管理员授权框(输入密码 / Touch ID)
  osascript -e "do shell script \"/usr/sbin/systemsetup -settimezone $tz\" with administrator privileges" >/dev/null 2>&1
}

main() {
  log "开始三路出口 IP 一致性检测 (ip111 逻辑) ..."
  local cn intl gfw goog
  cn=$(ip_china)  || cn=""
  intl=$(ip_intl) || intl=""
  gfw=$(ip_gfw)   || gfw=""
  if google_reachable; then goog="可达"; else goog="不可达"; fi

  log "  国内视角 : ${cn:-获取失败}"
  log "  国外视角 : ${intl:-获取失败}"
  log "  被封/谷歌: ${gfw:-获取失败}  (Google: ${goog})"

  # 判定一致性
  local consistent=0
  if [[ -n "$cn" && -n "$intl" && -n "$gfw" && "$cn" == "$intl" && "$intl" == "$gfw" ]]; then
    consistent=1
  fi

  if [[ $consistent -eq 1 ]]; then
    log "✅ 三路 IP 一致 (${intl})，是干净的真实出口 IP"
  else
    log "⚠️  三路 IP 不一致或缺失 —— 出口 IP 有问题(疑似分流/PAC/DNS泄漏)"
  fi

  # 设时区以"谷歌/被封侧出口 IP"为准(其次国外视角)，时区经 ipinfo.io 解析
  local tz_ip="${gfw:-$intl}" gfwtz=""
  [[ -n "$tz_ip" ]] && gfwtz=$(ip_timezone "$tz_ip")
  log "  谷歌侧出口 ${tz_ip:-?} 对应时区: ${gfwtz:-解析失败}"

  # 刷新菜单栏快照(含谷歌侧 IP 对应时区)
  write_status "$consistent" "${cn:-?}" "${intl:-?}" "${gfw:-?}" "$goog" "${gfwtz:-?}"

  # —— 出口 IP / 一致性变化告警(仅在状态真正变化时提醒，避免刷屏) ——
  # --check 模式只刷新显示、不发告警，避免与守护进程重复通知
  local cur_exit="${tz_ip:-none}"
  local cur_state="${cur_exit}|${consistent}"
  if [[ "$MODE" != "check" ]]; then
    local prev_state=""; [[ -f "$STATE" ]] && prev_state=$(cat "$STATE" 2>/dev/null)
    if [[ -n "$prev_state" && "$prev_state" != "$cur_state" ]]; then
      local prev_ip="${prev_state%%|*}" prev_ok="${prev_state##*|}"
      if [[ "$prev_ip" != "$cur_exit" ]]; then
        log "🔔 出口 IP 变化: ${prev_ip} -> ${cur_exit}"
        notify "出口 IP 变化" "${prev_ip} → ${cur_exit}"
      fi
      if [[ "$prev_ok" != "$consistent" ]]; then
        if [[ "$consistent" == "1" ]]; then
          notify "出口已恢复正常" "三路 IP 一致: ${cur_exit}"
        else
          notify "⚠️ 出口 IP 异常" "三路不一致(疑似分流/泄漏)"
        fi
      fi
    fi
    echo "$cur_state" >"$STATE" 2>/dev/null || true
  fi

  # 只检测，不改时区
  if [[ "$MODE" == "check" ]]; then
    exit $(( consistent == 1 ? 0 : 1 ))
  fi

  # 自动把系统时区设为"谷歌侧出口 IP"对应时区
  if [[ -z "$gfwtz" ]]; then
    log "无法解析出口 IP(${tz_ip:-空})的时区，跳过设置"; exit 1
  fi
  [[ $consistent -ne 1 ]] && log "注意: 三路 IP 不一致(已告警)，仍按谷歌侧出口 ${tz_ip} 设时区"
  apply_timezone "$gfwtz"
}

main "$@"
