#!/bin/bash
# claude-check.sh
# Claude / Claude Code 运行环境体检: 多信号加权打分 + 问题清单 + 修复建议 + 自动修复。
#
# 评分模型参考 https://github.com/yacuo/check-cc (MIT)，但那边是浏览器端检测(WebRTC /
# Client Hints / Emoji 渲染 / 字体探测靠 JS 拿)，这里是 macOS 本地实现: 凡是 shell 能测的
# 信号全部覆盖(出口/质量/画像/DNS/稳定 共 16 项)，浏览器独有的 4 项(WebRTC 泄漏、浏览器
# 时区语言、渲染环境)由菜单栏 App 的浏览器桥接采集后写文件，这里读取，合计 26 项。
#
# 用法:
#   ./claude-check.sh              # 体检并打印报告
#   ./claude-check.sh --fix        # 体检 + 自动修可安全修复项(时区)，再重新打分
#   ./claude-check.sh --fix-locale # 额外把系统"区域"改成出口国家(会影响日期格式显示)
#   ./claude-check.sh --quiet      # 只写状态文件，不打印

set -uo pipefail

DATA_DIR="${AUTO_TZ_DIR:-$HOME/Library/Application Support/CheckClaude}"
# v2.0 从 AutoTimezone 改名 CheckClaude，把旧数据目录搬过来 ——
# 出口稳定性要读 24h 内的历史日志，不搬会丢。
OLD_DIR="$HOME/Library/Application Support/AutoTimezone"
[[ ! -d "$DATA_DIR" && -d "$OLD_DIR" ]] && mv "$OLD_DIR" "$DATA_DIR" 2>/dev/null
mkdir -p "$DATA_DIR" 2>/dev/null || true
STATUS="$DATA_DIR/status"                # auto-timezone.sh 写的三路出口快照
CSTATUS="$DATA_DIR/claude_status"        # 本脚本写的体检快照(菜单栏 App 读)
LOG="$DATA_DIR/auto-timezone.log"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TZ_SCRIPT="$SELF_DIR/auto-timezone.sh"
TMP="${TMPDIR:-/tmp}/cc.$$"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

MODE="report"; DO_FIX=0; FIX_LOCALE=0
case "${1:-}" in
  --fix)        DO_FIX=1 ;;
  --fix-locale) DO_FIX=1; FIX_LOCALE=1 ;;
  --quiet)      MODE="quiet" ;;
esac

CURL='curl -fsS --max-time 9 -A Mozilla/5.0'
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG" 2>/dev/null || true; }

# Anthropic 明确不提供服务的地区
UNSUPPORTED="CN HK MO RU IR KP CU SY BY VE"
SUPPORTED="US CA GB IE DE FR NL SE NO DK FI IT ES PT PL CZ AT CH BE LU JP KR SG TW AU NZ IL AE MX BR IN PH TH MY ID VN ZA TR SA AR CL"
# 常见国内公共 DNS，直接用它解析 = DNS 请求泄漏到国内
CN_DNS="114.114.114.114 114.114.115.115 223.5.5.5 223.6.6.6 119.29.29.29 182.254.116.116 180.76.76.76 117.50.10.10 1.2.4.8 210.2.4.8"

# 重点地区的具体情况，比笼统一句"不在服务范围"有用
region_note() {
  case "$1" in
    CN)          echo "中国大陆：Anthropic 未在此开放服务，登录、订阅与 API 申请均会被拒" ;;
    HK|MO)       echo "港澳：不在 Anthropic 支持地区列表内，与大陆同样不可用" ;;
    RU|BY)       echo "俄罗斯/白俄罗斯：受制裁限制，服务与订阅不可用" ;;
    IR|KP|CU|SY) echo "受美国制裁地区，Anthropic 服务完全不可用" ;;
    VE)          echo "委内瑞拉：不在支持地区列表内" ;;
    *)           echo "该地区不在 Anthropic 支持列表内" ;;
  esac
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── 信号表 ──────────────────────────────────────────────────────
# 加一项检测 = 调一次 sig。字段用 ~ 分隔(| 留给 issues/fixes 的多条分隔)
# sig <分组> <标签> <权重> <达成率0-100> <展示值> [问题] [建议]
SIGNALS=(); SCORE=0; ISSUES=""; FIXES=""
add_issue() { ISSUES+="${ISSUES:+|}$1"; }
add_fix()   { FIXES+="${FIXES:+|}$1"; }
sig() {
  local pts=$(( $3 * $4 / 100 ))
  SCORE=$((SCORE + pts))
  SIGNALS+=("$1~$2~$3~$pts~$5")
  [[ -n "${6:-}" ]] && add_issue "$6"
  [[ -n "${7:-}" ]] && add_fix "$7"
  return 0
}

# ── 采集: 三路出口快照(复用 auto-timezone.sh 的结果) ─────────────
read_status() {
  CONSISTENT=""; GFW_IP=""; INTL_IP=""; CN_IP=""; SYS_TZ=""; GFW_TZ=""; GOOGLE=""
  [[ -f "$STATUS" ]] || return 1
  while IFS='=' read -r k v; do
    case "$k" in
      consistent) CONSISTENT="$v" ;; gfw) GFW_IP="$v" ;; intl) INTL_IP="$v" ;;
      cn) CN_IP="$v" ;; tz) SYS_TZ="$v" ;; gfwtz) GFW_TZ="$v" ;; google) GOOGLE="$v" ;;
    esac
  done <"$STATUS"
  [[ -n "$CONSISTENT" ]]
}
refresh_base() {
  local age=999999
  [[ -f "$STATUS" ]] && age=$(( $(date +%s) - $(stat -f %m "$STATUS" 2>/dev/null || echo 0) ))
  if [[ $age -gt 300 && -f "$TZ_SCRIPT" ]]; then
    AUTO_TZ_DIR="$DATA_DIR" bash "$TZ_SCRIPT" --check >/dev/null 2>&1
  fi
  read_status || true
  : "${INTL_IP:=?}" "${GFW_IP:=?}" "${CN_IP:=?}" "${SYS_TZ:=?}" "${GFW_TZ:=}" "${CONSISTENT:=0}"
  PROBE_IP="$GFW_IP"; [[ "$PROBE_IP" == "?" ]] && PROBE_IP="$INTL_IP"
}

# ── 采集: 并行发网络请求(串行会拖到 60 秒以上) ──────────────────
fetch_all() {
  local ip="$PROBE_IP"
  ( [[ "$ip" != "?" ]] && $CURL "http://ip-api.com/json/${ip}?fields=status,country,countryCode,region,city,isp,org,as,asname,proxy,hosting" >"$TMP/ipapi" 2>/dev/null ) &
  ( [[ "$ip" != "?" ]] && $CURL "https://ipinfo.io/${ip}/json" >"$TMP/ipinfo" 2>/dev/null ) &
  ( $CURL "https://www.cloudflare.com/cdn-cgi/trace" >"$TMP/cftrace" 2>/dev/null ) &
  ( curl -s -m 10 -o "$TMP/apibody" -w '%{http_code}' -H 'content-type: application/json' \
      https://api.anthropic.com/v1/messages -d '{}' >"$TMP/apicode" 2>/dev/null ) &
  # 测 robots.txt 而不是主页: 主页对裸 curl 一律返 403(Cloudflare bot 挑战)，带浏览器 UA 也一样，
  # 那是反爬不是地区拦截，拿它判可达性会稳定误报。静态资源不触发挑战，能真实反映地区可达。
  ( curl -s -m 10 -o /dev/null -w '%{http_code}' https://claude.ai/robots.txt >"$TMP/webcode" 2>/dev/null ) &
  ( curl -s -m 10 -o /dev/null -w '%{http_code}' https://www.anthropic.com/robots.txt >"$TMP/sitecode" 2>/dev/null ) &
  ( ip_v6 >"$TMP/ipv6" 2>/dev/null ) &
  wait
}

jget() { grep -Eo "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null | head -1 | cut -d'"' -f4; }

parse_net() {
  COUNTRY=""; COUNTRY_NAME=""; CITY=""; ISP=""; ASN=""; HOSTING=-1; PROXY=0
  if [[ -s "$TMP/ipapi" ]] && grep -q '"status":"success"' "$TMP/ipapi"; then
    COUNTRY=$(jget "$TMP/ipapi" countryCode); COUNTRY_NAME=$(jget "$TMP/ipapi" country)
    CITY=$(jget "$TMP/ipapi" city); ISP=$(jget "$TMP/ipapi" isp); ASN=$(jget "$TMP/ipapi" as)
    HOSTING=0; grep -q '"hosting":true' "$TMP/ipapi" && HOSTING=1
    grep -q '"proxy":true' "$TMP/ipapi" && PROXY=1
  fi
  # 第二家情报源，用于交叉验证(不同厂商对同一 IP 判定不一致 = 该 IP 情报混乱)
  COUNTRY2=$(jget "$TMP/ipinfo" country)
  ISP2=$(jget "$TMP/ipinfo" org)
  if [[ -z "$COUNTRY" && -n "$COUNTRY2" ]]; then
    COUNTRY="$COUNTRY2"; COUNTRY_NAME="$COUNTRY2"; ISP="$ISP2"
  fi
  # Cloudflare 边缘: 你实际落到哪个机房，反映真实网络位置(比 IP 库更难伪造)
  CF_COLO=""; CF_LOC=""; CF_IP=""; CF_WARP=""
  if [[ -s "$TMP/cftrace" ]]; then
    CF_COLO=$(grep '^colo=' "$TMP/cftrace" | cut -d= -f2)
    CF_LOC=$(grep '^loc='  "$TMP/cftrace" | cut -d= -f2)
    CF_IP=$(grep '^ip='    "$TMP/cftrace" | cut -d= -f2)
    CF_WARP=$(grep '^warp=' "$TMP/cftrace" | cut -d= -f2)
  fi
  API_CODE=$(cat "$TMP/apicode" 2>/dev/null); API_CODE="${API_CODE:-000}"
  WEB_CODE=$(cat "$TMP/webcode" 2>/dev/null); WEB_CODE="${WEB_CODE:-000}"
  SITE_CODE=$(cat "$TMP/sitecode" 2>/dev/null); SITE_CODE="${SITE_CODE:-000}"
  IPV6=$(cat "$TMP/ipv6" 2>/dev/null | tr -d '[:space:]')
  IPV6_CC=""
  [[ -n "$IPV6" ]] && IPV6_CC=$(jget <($CURL "http://ip-api.com/json/${IPV6}?fields=status,countryCode") countryCode 2>/dev/null)
  API_REGION_BLOCK=0
  grep -qi 'unsupported_country\|not available in your' "$TMP/apibody" 2>/dev/null && API_REGION_BLOCK=1
}

# ── 采集: DNS ───────────────────────────────────────────────────
parse_dns() {
  DNS_SERVERS=$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u | head -3 | tr '\n' ' ')
  DNS_SCOPE="未知"
  local s first_public=""
  for s in $DNS_SERVERS; do
    case "$s" in
      127.*|::1|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|198.18.*|100.64.*) : ;;
      *) [[ -z "$first_public" ]] && first_public="$s" ;;
    esac
  done
  if [[ -z "$first_public" ]]; then
    DNS_SCOPE="本地/代理接管"
  elif in_list "$first_public" "$CN_DNS"; then
    DNS_SCOPE="国内公共DNS($first_public)"
  else
    DNS_SCOPE="境外/自定义($first_public)"
  fi
  # 解析 claude.ai，看是被代理接管(fake-ip)、正常拿到 Cloudflare IP，还是被污染
  DNS_RESULT=$(dscacheutil -q host -a name claude.ai 2>/dev/null | awk '/^ip_address:/{print $2}' | head -1)
  DNS_VERDICT="失败"
  case "${DNS_RESULT:-}" in
    "")                       DNS_VERDICT="解析失败" ;;
    198.18.*|198.19.*|240.*)  DNS_VERDICT="代理接管(fake-ip)" ;;
    0.0.0.0|127.*|10.*|192.168.*) DNS_VERDICT="被污染(指向私有地址)" ;;
    # 160.79.104.0/23 是 Anthropic 自有段(AS399358)，claude.ai 已从纯 Cloudflare 迁过来
    160.79.10[45].*)          DNS_VERDICT="正常(Anthropic)" ;;
    104.*|172.6[4-9].*|172.7[0-1].*|162.15[89].*|188.114.*|141.101.*) DNS_VERDICT="正常(Cloudflare)" ;;
    *)                        DNS_VERDICT="可疑(${DNS_RESULT})" ;;
  esac
}

# ── 采集: 系统画像 ──────────────────────────────────────────────
parse_system() {
  OS_VER="macOS $(sw_vers -productVersion 2>/dev/null)"
  SYS_LOCALE=$(defaults read -g AppleLocale 2>/dev/null || echo "")
  SYS_LANGS=$(defaults read -g AppleLanguages 2>/dev/null | grep -Eo '"[a-zA-Z-]+"' | tr -d '"' | tr '\n' ',' | sed 's/,$//')
  SYS_LANG="${SYS_LANGS%%,*}"
  LOCALE_CC="${SYS_LOCALE##*_}"; [[ "$LOCALE_CC" == "$SYS_LOCALE" ]] && LOCALE_CC=""
  TZ_OFFSET=$(date +%z)                       # 如 -0700
  TZ_ABBR=$(date +%Z)                         # 如 PDT
  # 时区偏移与时区名是否自洽(手动改过偏移 / TZ 环境变量覆盖会露馅)
  local expect
  expect=$(TZ="$SYS_TZ" date +%z 2>/dev/null)
  TZ_SELF_CONSISTENT=$([[ "$expect" == "$TZ_OFFSET" ]] && echo 1 || echo 0)
  # 代理形态: TUN 接管(默认路由走 utun) / 系统 HTTP 代理 / PAC 自动配置
  PROXY_MODE="直连"
  local dev pac http_p
  # TUN 类代理(FlClash/Clash/Surge)靠 0.0.0.0/1 + 128.0.0.0/1 抢公网流量，**不动 default 路由**，
  # 所以查 default 只会看到物理网卡，误判成"直连"。要看去公网的地址实际走哪个接口。
  dev=$(route -n get 93.184.216.34 2>/dev/null | awk '/interface:/{print $2}')
  [[ -z "$dev" ]] && dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [[ "$dev" == utun* ]] && PROXY_MODE="TUN 全局"
  http_p=$(scutil --proxy 2>/dev/null | awk '/HTTPEnable/{print $3}')
  pac=$(scutil --proxy 2>/dev/null | awk '/ProxyAutoConfigEnable/{print $3}')
  [[ "$PROXY_MODE" == "直连" && "$http_p" == "1" ]] && PROXY_MODE="系统 HTTP 代理"
  [[ "$pac" == "1" ]] && PROXY_MODE="$PROXY_MODE + PAC 分流"
  PAC_ON=$([[ "$pac" == "1" ]] && echo 1 || echo 0)
}

# ── 采集: 环境稳定性 / 运行容器 ─────────────────────────────────
# 账号画像里"设备连续性"这一项，网页端做不了(没有历史)，但我们有本地日志。
parse_stability() {
  IP_CHANGES=0
  if [[ -f "$LOG" ]]; then
    local since
    since=$(date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    IP_CHANGES=$(awk -v s="[$since]" '$0 >= s && /出口 IP 变化/' "$LOG" 2>/dev/null | wc -l | tr -d ' ')
  fi
  # 虚拟机里跑 = 设备指纹异常，是风控关注的信号
  VM_HOST="物理机"
  local hv model
  hv=$(sysctl -n kern.hv_vmm_present 2>/dev/null)
  model=$(sysctl -n hw.model 2>/dev/null)
  [[ "$hv" == "1" ]] && VM_HOST="虚拟机"
  case "$model" in VMware*|Parallels*|VirtualBox*|Virtual*) VM_HOST="虚拟机($model)" ;; esac
}

# ── 采集: 浏览器信号(菜单栏 App 的隐藏 WKWebView 写的) ──────────
parse_browser() {
  BR_OK=0; BR_TZ=""; BR_LANGS=""; BR_LOCALE=""; BR_RTC=""; BR_RTC_HOST=""
  BR_SOURCE=""; BR_UA=""; BR_CH_PLAT=""; BR_ACCEPT=""; BR_UAD_PLAT=""
  BR_FONTS=""; BR_WEBGL=""; BR_CANVAS=""; BR_AGE=999999
  local f="$DATA_DIR/browser_signals"
  [[ -f "$f" ]] || return 1
  BR_AGE=$(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || echo 0) ))
  while IFS='=' read -r k v; do
    case "$k" in
      tz) BR_TZ="$v" ;; languages) BR_LANGS="$v" ;; locale) BR_LOCALE="$v" ;;
      source) BR_SOURCE="$v" ;; ua) BR_UA="$v" ;; ch_platform) BR_CH_PLAT="$v" ;;
      accept_lang) BR_ACCEPT="$v" ;; uad_platform) BR_UAD_PLAT="$v" ;;
      rtc_srflx) BR_RTC="$v" ;; rtc_host) BR_RTC_HOST="$v" ;; fonts) BR_FONTS="$v" ;;
      webgl) BR_WEBGL="$v" ;; canvas) BR_CANVAS="$v" ;;
    esac
  done <"$f"
  # 1 小时内、且拿到了时区，才认为这次采集有效
  [[ $BR_AGE -lt 3600 && -n "$BR_TZ" ]] && BR_OK=1
  return 0
}

# ── 采集: Claude Code 本地环境(信息项) ──────────────────────────
parse_claude() {
  CLAUDE_VER=""; CLAUDE_BASE=""
  local bin
  # App 启动的进程 PATH 很干净，命中不了 shell 里的安装位置，显式扫常见路径
  bin=$(command -v claude 2>/dev/null) \
    || bin=$(ls "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "$HOME/.bun/bin/claude" \
               /usr/local/bin/claude /opt/homebrew/bin/claude 2>/dev/null | head -1)
  [[ -n "$bin" ]] && CLAUDE_VER=$("$bin" --version 2>/dev/null | head -1)
  CLAUDE_BASE="${ANTHROPIC_BASE_URL:-}"
  [[ -z "$CLAUDE_BASE" && -f "$HOME/.claude/settings.json" ]] && \
    CLAUDE_BASE=$(jget "$HOME/.claude/settings.json" ANTHROPIC_BASE_URL)
  [[ -z "$CLAUDE_BASE" && -f "$HOME/.zshrc" ]] && \
    CLAUDE_BASE=$(grep -E '^[[:space:]]*export[[:space:]]+ANTHROPIC_BASE_URL' "$HOME/.zshrc" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')
}

# ── 打分: 26 项加权信号，合计 100 ───────────────────────────────
compute_score() {
  SIGNALS=(); SCORE=0; ISSUES=""; FIXES=""; FIXABLE_TZ=""; FIXABLE_LOCALE=""
  local relay=0
  [[ -n "$CLAUDE_BASE" && "$CLAUDE_BASE" != *"api.anthropic.com"* ]] && relay=1

  # ── A. 出口地区与服务可用 (35) ──
  if [[ -z "$COUNTRY" ]]; then
    sig 出口 "出口国家" 14 50 "未知" "出口 IP 归属地未知(IP 情报接口不可达)" "检查网络后重新体检"
  elif in_list "$COUNTRY" "$UNSUPPORTED"; then
    sig 出口 "出口国家" 14 0 "$COUNTRY 不支持" \
      "出口国家 ${COUNTRY} 不在 Anthropic 服务范围，登录/订阅/API 均有封号风险" \
      "切到美国/日本/新加坡等支持地区节点，并长期固定，不要频繁换国家"
  elif in_list "$COUNTRY" "$SUPPORTED"; then
    sig 出口 "出口国家" 14 100 "$COUNTRY ${CITY:-}"
  else
    sig 出口 "出口国家" 14 66 "$COUNTRY 支持未知" "出口国家 ${COUNTRY} 支持情况未知" "建议改用 US/JP/SG 等已知支持地区节点"
  fi

  if [[ "$API_CODE" == "401" || "$API_CODE" == "400" ]]; then
    sig 出口 "Anthropic API 可达" 10 100 "HTTP $API_CODE"
  elif [[ "$API_CODE" == "403" || "$API_REGION_BLOCK" == "1" ]]; then
    sig 出口 "Anthropic API 可达" 10 0 "HTTP 403 地区拦截" \
      "api.anthropic.com 返回 403，当前出口被地区拦截" "更换支持地区节点；确认代理为全局而非 PAC 分流"
  elif [[ "$API_CODE" == "000" && $relay -eq 1 ]]; then
    sig 出口 "Anthropic API 可达" 10 50 "直连不通(已配中转)" \
      "api.anthropic.com 直连不通，但你已配置中转 ${CLAUDE_BASE}" "只用中转可忽略；需直连官方则开全局代理"
  elif [[ "$API_CODE" == "000" ]]; then
    sig 出口 "Anthropic API 可达" 10 0 "连不上" \
      "api.anthropic.com 连不上(超时/DNS 污染)" "开启全局代理；检查 DNS 是否被污染"
  else
    sig 出口 "Anthropic API 可达" 10 50 "HTTP $API_CODE" "api.anthropic.com 返回异常状态 ${API_CODE}" "稍后重试；持续异常则换节点"
  fi

  case "$WEB_CODE" in
    200|301|302|307) sig 出口 "claude.ai 可达" 2 100 "HTTP $WEB_CODE" ;;
    403)             sig 出口 "claude.ai 可达" 2 20 "HTTP 403 被拦" \
                       "claude.ai 返回 403(Cloudflare 地区拦截或风控挑战)" "换支持地区的干净节点，网页端登录前先确认能打开" ;;
    000)             sig 出口 "claude.ai 可达" 2 0 "连不上" "claude.ai 连不上" "开启全局代理" ;;
    *)               sig 出口 "claude.ai 可达" 2 60 "HTTP $WEB_CODE" ;;
  esac

  # anthropic.com 与 claude.ai 走的是不同的前端，分开测才能区分"整体被拦"和"单点异常"
  case "$SITE_CODE" in
    200|301|302|307) sig 出口 "anthropic.com 可达" 2 100 "HTTP $SITE_CODE" ;;
    403)             sig 出口 "anthropic.com 可达" 2 20 "HTTP 403 被拦" \
                       "anthropic.com 返回 403，官网侧也被拦" "换支持地区的干净节点" ;;
    000)             sig 出口 "anthropic.com 可达" 2 0 "连不上" "anthropic.com 连不上" "开启全局代理" ;;
    *)               sig 出口 "anthropic.com 可达" 2 60 "HTTP $SITE_CODE" ;;
  esac

  # 两家 IP 情报库对同一 IP 的判定是否一致
  if [[ -n "$COUNTRY" && -n "$COUNTRY2" ]]; then
    if [[ "$COUNTRY" == "$COUNTRY2" ]]; then
      sig 出口 "多源情报一致" 3 100 "$COUNTRY = $COUNTRY2"
    else
      sig 出口 "多源情报一致" 3 0 "$COUNTRY ≠ $COUNTRY2" \
        "两家 IP 情报库对该出口判定不一致(${COUNTRY} vs ${COUNTRY2})，属于画像混乱的 IP" "换一个情报干净、归属明确的节点"
    fi
  else
    sig 出口 "多源情报一致" 3 50 "数据不足"
  fi

  # IPv6 出口: 没有最省心，有就必须和 IPv4 出口同地区，否则等于开了个后门
  if [[ -z "$IPV6" ]]; then
    sig 出口 "IPv6 出口" 3 100 "无 IPv6(无泄漏面)"
  elif [[ -z "$IPV6_CC" ]]; then
    sig 出口 "IPv6 出口" 3 60 "${IPV6:0:20}… 归属未知" "IPv6 出口存在但查不到归属"
  elif [[ "$IPV6_CC" == "$COUNTRY" ]]; then
    sig 出口 "IPv6 出口" 3 100 "$IPV6_CC 与 IPv4 一致"
  else
    sig 出口 "IPv6 出口" 3 0 "$IPV6_CC ≠ $COUNTRY" \
      "IPv6 出口在 ${IPV6_CC}，与 IPv4 出口 ${COUNTRY} 不一致 —— 代理没接管 IPv6，真实地区被暴露" \
      "在代理里开启 IPv6 接管，或在系统网络设置里关掉 IPv6"
  fi

  # ── B. 出口质量 (12) ──
  if [[ "$PROXY" == "1" ]]; then
    sig 质量 "IP 类型" 4 25 "公开代理/VPN" "出口 IP 被标记为公开代理/VPN 出口，属高风控段" "换独享节点或住宅 IP，避免与大量用户共用出口"
  elif [[ "$HOSTING" == "1" ]]; then
    sig 质量 "IP 类型" 4 50 "机房 IDC" "出口是机房(IDC) IP: ${ISP}，风控强度高于住宅" "有条件换住宅/家宽节点；至少保证独享且长期不变"
  elif [[ "$HOSTING" == "0" ]]; then
    sig 质量 "IP 类型" 4 100 "住宅"
  else
    sig 质量 "IP 类型" 4 70 "未知"
  fi

  # Cloudflare 边缘机房国家 vs IP 库国家: 不一致说明 IP 归属被"改过"或链路绕路
  if [[ -n "$CF_LOC" && -n "$COUNTRY" ]]; then
    if [[ "$CF_LOC" == "$COUNTRY" ]]; then
      sig 质量 "边缘机房匹配" 3 100 "${CF_COLO} (${CF_LOC})"
    else
      sig 质量 "边缘机房匹配" 3 25 "${CF_COLO}(${CF_LOC}) ≠ ${COUNTRY}" \
        "Cloudflare 边缘落在 ${CF_LOC}，与 IP 库归属 ${COUNTRY} 不一致" "该 IP 的地理归属可能是伪造的，换归属真实的节点"
    fi
  else
    sig 质量 "边缘机房匹配" 3 50 "${CF_COLO:-未知}"
  fi

  # Cloudflare 看到的来源 IP 应与三路检测拿到的一致，否则中间还有一层出口
  if [[ -n "$CF_IP" && "$PROBE_IP" != "?" ]]; then
    if [[ "$CF_IP" == "$PROBE_IP" ]]; then
      sig 质量 "出口链路单一" 3 100 "$CF_IP"
    else
      sig 质量 "出口链路单一" 3 0 "$CF_IP ≠ $PROBE_IP" \
        "Cloudflare 看到的来源 ${CF_IP} 与检测到的出口 ${PROBE_IP} 不同，链路上还有一层代理" "统一走同一出口，避免多层嵌套代理"
    fi
  else
    sig 质量 "出口链路单一" 3 50 "数据不足"
  fi

  # ── C. 地区画像一致性 (18) ──
  if [[ "$CONSISTENT" == "1" ]]; then
    sig 画像 "三路出口一致" 6 100 "$PROBE_IP"
  else
    sig 画像 "三路出口一致" 6 30 "不一致" \
      "三路出口 IP 不一致(分流/PAC/DNS 泄漏)，账号画像会在多地区间跳变" "代理切全局模式，让国内/国外/谷歌三路走同一出口"
  fi

  if [[ -n "$GFW_TZ" && "$GFW_TZ" == "$SYS_TZ" ]]; then
    sig 画像 "系统时区匹配出口" 5 100 "$SYS_TZ"
  elif [[ -z "$GFW_TZ" || "$GFW_TZ" == "?" ]]; then
    sig 画像 "系统时区匹配出口" 5 50 "出口时区未知" "无法解析出口 IP 对应时区"
  else
    sig 画像 "系统时区匹配出口" 5 0 "$SYS_TZ ≠ $GFW_TZ" \
      "系统时区 ${SYS_TZ} 与出口时区 ${GFW_TZ} 不一致，是典型的环境矛盾信号" "可一键修复: 把系统时区改为 ${GFW_TZ}"
    FIXABLE_TZ="$GFW_TZ"
  fi

  if [[ "$TZ_SELF_CONSISTENT" == "1" ]]; then
    sig 画像 "时区偏移自洽" 2 100 "UTC${TZ_OFFSET:0:3} ${TZ_ABBR}"
  else
    sig 画像 "时区偏移自洽" 2 0 "偏移与时区名冲突" \
      "当前 UTC 偏移 ${TZ_OFFSET} 与时区 ${SYS_TZ} 不符(可能被 TZ 环境变量覆盖)" "清掉 shell 里的 TZ 环境变量"
  fi

  if [[ -z "$COUNTRY" || -z "$SYS_LOCALE" ]]; then
    sig 画像 "系统区域匹配出口" 4 50 "数据不足"
  elif [[ "$LOCALE_CC" == "$COUNTRY" ]]; then
    sig 画像 "系统区域匹配出口" 4 100 "$SYS_LOCALE"
  elif [[ "$SYS_LANG" == zh* ]]; then
    sig 画像 "系统区域匹配出口" 4 50 "$SYS_LOCALE vs $COUNTRY" \
      "系统语言中文 + 区域 ${LOCALE_CC:-?} 与出口 ${COUNTRY} 不一致(网页端登录会暴露矛盾)" \
      "仅用 Claude Code(CLI) 可忽略；常用网页端可把系统区域改成 ${COUNTRY}(不用改显示语言)"
    FIXABLE_LOCALE="$COUNTRY"
  else
    sig 画像 "系统区域匹配出口" 4 70 "$SYS_LOCALE vs $COUNTRY" "系统区域 ${LOCALE_CC:-?} 与出口 ${COUNTRY} 不一致"
    FIXABLE_LOCALE="$COUNTRY"
  fi

  # ── D. DNS (10) ──
  case "$DNS_VERDICT" in
    正常*|代理接管*) sig DNS "claude.ai 解析" 6 100 "$DNS_VERDICT" ;;
    被污染*)        sig DNS "claude.ai 解析" 6 0 "$DNS_VERDICT" \
                      "claude.ai 的 DNS 解析被污染(${DNS_RESULT})" "换 DoH/加密 DNS，或让代理接管 DNS(fake-ip 模式)" ;;
    解析失败)       sig DNS "claude.ai 解析" 6 20 "失败" "claude.ai 无法解析" "检查 DNS 设置，建议让代理接管 DNS" ;;
    *)              sig DNS "claude.ai 解析" 6 40 "$DNS_VERDICT" \
                      "claude.ai 解析到非 Cloudflare 地址(${DNS_RESULT})，可能被劫持" "换 DoH/加密 DNS 或由代理接管 DNS" ;;
  esac

  # TUN 全局下 DNS 查询本身就走隧道出去，不会泄漏到国内网络，判定要跟着代理形态走
  local tun=0; [[ "$PROXY_MODE" == "TUN 全局"* ]] && tun=1
  case "$DNS_SCOPE" in
    本地/代理接管*) sig DNS "DNS 出口" 4 100 "$DNS_SCOPE" ;;
    国内公共DNS*)
      if [[ $tun -eq 1 ]]; then
        sig DNS "DNS 出口" 4 70 "$DNS_SCOPE (走隧道)" \
          "用的是国内公共 DNS，虽然 TUN 下查询走隧道不算泄漏，但没必要绕这一圈" "换成 1.1.1.1 / 8.8.8.8"
      else
        sig DNS "DNS 出口" 4 0 "$DNS_SCOPE" \
          "正在用${DNS_SCOPE}，DNS 查询泄漏到国内，与国外出口矛盾" \
          "改用 1.1.1.1 / 8.8.8.8 或让代理接管 DNS"
      fi ;;
    *)
      if [[ $tun -eq 1 ]]; then
        sig DNS "DNS 出口" 4 100 "$DNS_SCOPE (走隧道)"
      else
        sig DNS "DNS 出口" 4 80 "$DNS_SCOPE"
      fi ;;
  esac

  # ── E. 环境稳定性 / 运行容器 (10) ──
  # 简体/繁体与出口地区的对应关系: 繁体主要用于 TW/HK/MO，简体用于 CN/SG
  # 系统用繁体却从美国出口，或用简体却从台湾出口，都是地区画像里的矛盾信号
  local variant=""
  case "$SYS_LANGS" in
    *zh-Hant*|*zh-TW*|*zh-HK*|*zh-MO*) variant="繁体" ;;
    *zh-Hans*|*zh-CN*|*zh-SG*|zh*)     variant="简体" ;;
  esac
  if [[ -z "$variant" || -z "$COUNTRY" ]]; then
    sig 画像 "语言变体一致" 2 100 "${variant:-非中文}"
  elif [[ "$variant" == "繁体" ]] && in_list "$COUNTRY" "TW HK MO"; then
    sig 画像 "语言变体一致" 2 100 "繁体 · $COUNTRY"
  elif [[ "$variant" == "简体" ]] && in_list "$COUNTRY" "CN SG MY"; then
    sig 画像 "语言变体一致" 2 100 "简体 · $COUNTRY"
  else
    sig 画像 "语言变体一致" 2 50 "$variant vs $COUNTRY" \
      "系统用${variant}中文但出口在 ${COUNTRY}，语言变体与地区画像不对应" \
      "仅用 CLI 可忽略；网页端登录前可把首选语言调成 en-US"
  fi

  if [[ "$PAC_ON" == "1" ]]; then
    sig 稳定 "代理形态" 3 20 "$PROXY_MODE" \
      "启用了 PAC 自动分流，不同网站会走不同出口，账号画像不稳定" "关掉 PAC，改用 TUN 全局模式"
  elif [[ "$PROXY_MODE" == "TUN 全局" ]]; then
    sig 稳定 "代理形态" 3 100 "$PROXY_MODE"
  else
    sig 稳定 "代理形态" 3 70 "$PROXY_MODE"
  fi

  if   [[ $IP_CHANGES -le 1 ]]; then sig 稳定 "出口稳定性" 4 100 "24h 内 ${IP_CHANGES} 次跳变"
  elif [[ $IP_CHANGES -le 5 ]]; then
    sig 稳定 "出口稳定性" 4 50 "24h 内 ${IP_CHANGES} 次跳变" \
      "24 小时内出口 IP 变了 ${IP_CHANGES} 次，设备连续性差" "固定一个节点用，别让代理自动切换线路"
  else
    sig 稳定 "出口稳定性" 4 0 "24h 内 ${IP_CHANGES} 次跳变" \
      "24 小时内出口 IP 变了 ${IP_CHANGES} 次，账号画像极不稳定" "关掉代理的自动切换/负载均衡，固定单一落地节点"
  fi

  if [[ "$VM_HOST" == "物理机" ]]; then
    sig 稳定 "运行容器" 3 100 "物理机"
  else
    sig 稳定 "运行容器" 3 30 "$VM_HOST" \
      "运行在${VM_HOST}中，设备指纹异常是风控关注的信号" "尽量在物理机上登录和使用 Claude"
  fi

  # ── F. 浏览器画像 (17) —— 由菜单栏 App 的真实浏览器桥接采集 ──
  if [[ "$BR_OK" != "1" ]]; then
    # 没采集到就按中性计分(70%)，不能因为"没测"判环境有问题，也不能白送满分。
    # 命令行单跑时没有 WebView，分数会比菜单栏里低几分，属预期。
    sig 浏览器 "WebRTC 出口" 6 70 "未采集"
    sig 浏览器 "浏览器时区" 3 70 "未采集"
    sig 浏览器 "浏览器语言" 2 70 "未采集"
    # 1 分的项不值得因为"没测"就扣成 0/1，那看起来像 bug
    sig 浏览器 "Intl 区域设置" 1 100 "未采集"
    sig 浏览器 "Client Hints" 2 70 "未采集"
    sig 浏览器 "HTTP 语言首标" 1 100 "未采集"
    sig 浏览器 "渲染环境" 2 70 "未采集"
  else
    # WebRTC 走 UDP，不经过 HTTP 代理，能暴露代理没兜住的真实出口
    if [[ -z "$BR_RTC" ]]; then
      sig 浏览器 "WebRTC 出口" 6 100 "无泄漏(未拿到公网候选)"
    elif [[ "$BR_RTC" == *"$PROBE_IP"* ]]; then
      sig 浏览器 "WebRTC 出口" 6 100 "$BR_RTC = 出口"
    else
      # 泄漏出来的 IP 属于哪个地区，决定这次泄漏有多要命
      local leak_n leak_cc
      leak_n=$(echo "$BR_RTC" | awk -F, '{print NF}')
      leak_cc=$(jget <($CURL "http://ip-api.com/json/${BR_RTC%%,*}?fields=countryCode") countryCode 2>/dev/null)
      sig 浏览器 "WebRTC 出口" 6 0 "${leak_n} 个泄漏 · ${leak_cc:-?} ≠ $COUNTRY" \
        "WebRTC 暴露了 ${leak_n} 个非代理出口(首个 ${BR_RTC%%,*}${leak_cc:+，归属 $leak_cc})，UDP 绕过了代理" \
        "代理开 TUN 全局(接管 UDP)，或在浏览器里禁用 WebRTC"
    fi

    if [[ "$BR_TZ" == "$SYS_TZ" ]]; then
      sig 浏览器 "浏览器时区" 3 100 "$BR_TZ$([[ "$BR_SOURCE" == browser ]] && echo " (真实浏览器)")"
    else
      sig 浏览器 "浏览器时区" 3 25 "$BR_TZ ≠ $SYS_TZ" \
        "浏览器时区 ${BR_TZ} 与系统时区 ${SYS_TZ} 不一致" "重启浏览器让它重新读系统时区"
    fi

    # 浏览器语言是网页端最直接的地区信号: 中文 + 国外出口是最常见的矛盾组合
    if [[ -n "$COUNTRY" && "$BR_LANGS" == zh* && ! " $UNSUPPORTED " == *" $COUNTRY "* ]]; then
      sig 浏览器 "浏览器语言" 2 40 "$BR_LANGS vs $COUNTRY" \
        "浏览器语言 ${BR_LANGS} 与出口地区 ${COUNTRY} 矛盾(网页端登录时直接可见)" \
        "网页端登录前把浏览器首选语言调成 en-US"
    else
      sig 浏览器 "浏览器语言" 2 100 "${BR_LANGS:-?}"
    fi

    # Intl 区域设置: 浏览器国际化配置与出口地区是否对应
    if [[ -z "$BR_LOCALE" || -z "$COUNTRY" ]]; then
      sig 浏览器 "Intl 区域设置" 1 100 "${BR_LOCALE:-?}"
    elif [[ "$BR_LOCALE" == *"-$COUNTRY" ]]; then
      sig 浏览器 "Intl 区域设置" 1 100 "$BR_LOCALE"
    else
      sig 浏览器 "Intl 区域设置" 1 50 "$BR_LOCALE vs $COUNTRY" \
        "浏览器 Intl 区域 ${BR_LOCALE} 与出口 ${COUNTRY} 不对应"
    fi

    # Client Hints(Chromium 独有): 平台标识要和真实系统对得上，对不上说明 UA 被改过或在异常容器里
    local ch_plat="${BR_CH_PLAT:-$BR_UAD_PLAT}" os_kind="macOS"
    [[ "$OS_VER" == Windows* ]] && os_kind="Windows"
    if [[ "$BR_SOURCE" != "browser" ]]; then
      sig 浏览器 "Client Hints" 2 70 "内置引擎未采集"
    elif [[ -z "$ch_plat" ]]; then
      sig 浏览器 "Client Hints" 2 100 "Safari/Firefox 不提供"
    elif [[ "$ch_plat" == *"$os_kind"* ]]; then
      sig 浏览器 "Client Hints" 2 100 "$ch_plat"
    else
      sig 浏览器 "Client Hints" 2 0 "$ch_plat ≠ $os_kind" \
        "浏览器上报的平台 ${ch_plat} 与真实系统 ${os_kind} 不符，UA 被改过或运行在异常容器中" \
        "关掉浏览器里改 UA 的插件，用原生浏览器登录"
    fi

    # HTTP Accept-Language 首标: 服务端第一眼看到的语言偏好，比 JS 里的 navigator 更早暴露
    if [[ "$BR_SOURCE" != "browser" || -z "$BR_ACCEPT" ]]; then
      sig 浏览器 "HTTP 语言首标" 1 100 "${BR_ACCEPT:-未采集}"
    elif [[ -n "$COUNTRY" && "$BR_ACCEPT" == zh* ]] && ! in_list "$COUNTRY" "CN HK TW MO SG"; then
      sig 浏览器 "HTTP 语言首标" 1 0 "$BR_ACCEPT vs $COUNTRY" \
        "请求头 Accept-Language: ${BR_ACCEPT} 与出口 ${COUNTRY} 矛盾，服务端第一眼就能看到" \
        "浏览器设置里把首选语言调成 English (United States)"
    else
      sig 浏览器 "HTTP 语言首标" 1 100 "${BR_ACCEPT:0:24}"
    fi

    # 渲染环境: WebGL 渲染器 + 中文字体探测。字体是"国产终端弱信号"——
    # 装着一堆中文字体本身不是问题(macOS 自带 PingFang)，只在拿不到 GPU 信息时才扣分
    local render_desc="${BR_WEBGL:0:24}"
    [[ -n "$BR_FONTS" ]] && render_desc+=" · $(echo "$BR_FONTS" | awk -F, '{print NF}') 中文字体"
    if [[ -n "$BR_WEBGL" ]]; then
      sig 浏览器 "渲染环境" 2 100 "$render_desc"
    else
      sig 浏览器 "渲染环境" 2 50 "未取到 GPU 信息"
    fi
  fi

  # 出口落在不服务地区是硬性阻断: 国内直连的画像其实很自洽(中文+国内IP+国内时区全一致)，
  # 不能让这些一致性得分把它抬进"基本可用"
  if [[ -n "$COUNTRY" ]] && in_list "$COUNTRY" "$UNSUPPORTED"; then
    GRADE="高风险"; VERDICT="$(region_note "$COUNTRY")"
  elif [[ $SCORE -ge 85 ]]; then GRADE="优秀"; VERDICT="环境适合运行 Claude"
  elif [[ $SCORE -ge 70 ]]; then GRADE="良好"; VERDICT="基本可用，建议修复下列项"
  elif [[ $SCORE -ge 50 ]]; then GRADE="风险"; VERDICT="存在明显矛盾信号，有封号风险"
  else                           GRADE="高风险"; VERDICT="不建议在当前环境登录或使用 Claude"
  fi
}


# 每项没拿满分时，具体做什么能把分补回来。issues/fixes 说的是"有什么问题"，
# 这里说的是"下一步动手做什么"，菜单里按差值从大到小排给用户看。
gain_hint() {
  case "$1" in
    "出口国家")          echo "换到 US / JP / SG 等支持地区的节点" ;;
    "Anthropic API 可达") echo "开全局代理，确认能直连 api.anthropic.com" ;;
    "claude.ai 可达")     echo "换干净节点，确认浏览器能打开 claude.ai" ;;
    "多源情报一致")      echo "换一个归属明确、情报干净的节点" ;;
    "IP 类型")           echo "换住宅 / 家宽节点，别用机房 IP" ;;
    "边缘机房匹配")      echo "换地理归属真实的节点" ;;
    "出口链路单一")      echo "别叠多层代理，统一走同一个出口" ;;
    "三路出口一致")      echo "代理切全局模式，三路走同一出口" ;;
    "系统时区匹配出口")  echo "点「一键修复」即可自动改" ;;
    "时区偏移自洽")      echo "清掉 shell 里的 TZ 环境变量后重开终端" ;;
    "系统区域匹配出口")  echo "菜单里点「把系统区域改为 XX」" ;;
    "代理形态")          echo "代理开 TUN / 虚拟网卡模式，关掉 PAC 分流" ;;
    "出口稳定性")        echo "固定一个节点，24 小时内别切线路(到点自动回满)" ;;
    "运行容器")          echo "在物理机上登录和使用，别在虚拟机里" ;;
    "claude.ai 解析")     echo "换 DNS 或让代理接管 DNS" ;;
    "DNS 出口")          echo "点「一键修复」自动换成验证过的境外 DNS" ;;
    "WebRTC 出口")       echo "代理开 TUN 模式接管 UDP，或浏览器禁用 WebRTC" ;;
    "浏览器时区")        echo "重启浏览器，让它重新读系统时区" ;;
    "浏览器语言")        echo "把浏览器首选语言调成 en-US" ;;
    "渲染环境")          echo "从菜单栏 App 体检(命令行单跑拿不到浏览器信号)" ;;
    "anthropic.com 可达") echo "开全局代理后重试；持续 403 说明该节点被 Anthropic 拦" ;;
    "IPv6 出口")         echo "代理设置里开启 IPv6 接管；或 系统设置 → 网络 → 详细信息 → TCP/IP → 配置 IPv6 选「关闭」" ;;
    "语言变体一致")      echo "仅用 Claude Code 可忽略；常用网页端就在 系统设置 → 通用 → 语言与地区 把首选语言拖成 English" ;;
    "Intl 区域设置")     echo "浏览器设置里把语言/区域调成与出口地区一致（Chrome: 设置 → 语言）" ;;
    "Client Hints")      echo "关掉浏览器里改 UA 的插件，用原生浏览器打开 claude.ai" ;;
    "HTTP 语言首标")     echo "浏览器设置 → 语言，把 English (United States) 拖到第一位" ;;
    *)                   echo "重新体检" ;;
  esac
}

# 未满分项 -> "标签~差值~动作"，按差值降序。菜单和报告都用它。
build_gains() {
  GAINS=""
  local row g l w p v diff hint
  local sorted
  sorted=$(for row in "${SIGNALS[@]}"; do
    IFS='~' read -r g l w p v <<<"$row"
    diff=$((w - p)); [[ $diff -le 0 ]] && continue
    echo "$diff~$l~$v"
  done | sort -rn -t'~' -k1)
  while IFS='~' read -r diff l v; do
    [[ -z "$diff" ]] && continue
    if [[ "$v" == *未采集* ]]; then
      hint="从菜单栏 App 点「重新体检」(命令行单跑没有浏览器信号)"
    else
      hint=$(gain_hint "$l")
    fi
    GAINS+="${GAINS:+|}${l}~${diff}~${hint}"
  done <<<"$sorted"
}

# ── 自动修复 ────────────────────────────────────────────────────
notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

# 当前活跃的网络服务名(Wi-Fi / Ethernet / ...)，networksetup 要用它定位
active_service() {
  local dev svc
  dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [[ -z "$dev" ]] && return 1
  # "Hardware Port: Wi-Fi" / "Device: en0" 成对出现，找到 dev 对应的那个 port
  networksetup -listallhardwareports 2>/dev/null | awk -v d="$dev" '
    /^Hardware Port:/{p=substr($0,16)} /^Device:/{if($2==d){print p; exit}}'
}

# 解析 claude.ai 看某台 DNS 是否可信(能拿到 Anthropic/Cloudflare 真实地址 = 没被投毒)
dns_trusted() {
  local srv="$1" ip
  ip=$(dig +short +time=3 +tries=1 claude.ai "@$srv" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
  [[ -z "$ip" ]] && ip=$(nslookup claude.ai "$srv" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)
  case "$ip" in
    160.79.10[45].*|104.*|172.6[4-9].*|162.15[89].*|188.114.*|141.101.*) echo "$ip"; return 0 ;;
    *) return 1 ;;
  esac
}

# DNS 泄漏修复: 换成境外公共 DNS。
# 先验证候选 DNS 能不能正确解析 claude.ai —— 在国内明文 DNS 可能被投毒，
# 盲目改过去会把能用的环境改坏，所以验证通过才动手。
fix_dns_servers() {
  local svc="$1" srv ok="" ips=""
  for srv in 1.1.1.1 8.8.8.8 9.9.9.9; do
    if ip=$(dns_trusted "$srv"); then
      echo "  ✓ $srv 解析 claude.ai → $ip (可信)"
      ok="$ok $srv"
    else
      echo "  ✗ $srv 解析异常，跳过"
    fi
  done
  ok="${ok# }"
  if [[ -z "$ok" ]]; then
    echo "  ⚠️  候选 DNS 全部解析异常(可能被投毒)，改用加密 DNS 方案"
    fix_dns_doh
    return 1
  fi
  # 备份原设置，方便撤销
  local bak="$DATA_DIR/dns_backup"
  networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ' >"$bak"
  if sudo -n /usr/sbin/networksetup -setdnsservers "$svc" $ok >/dev/null 2>&1; then
    dscacheutil -flushcache 2>/dev/null
    echo "  ✅ 已把 $svc 的 DNS 改为: $ok"
    echo "     撤销: sudo networksetup -setdnsservers \"$svc\" empty   (原值见 $bak)"
    log "fix: DNS $svc -> $ok"
    return 0
  fi
  echo "  ⚠️  改 DNS 需要授权，先运行一次: sudo bash enable-auto-timezone.sh"
  NEED_SUDO=1
  return 1
}

# 备选方案: 加密 DNS(DoH) 描述文件。
# 注意 macOS 把 DNS Settings 实现成 Network Extension，机器上跑着 VPN/TUN 类代理
# (FlClash / Surge / Clash Verge 等)时安装会失败，报 "The VPN service could not be created"。
# 所以它只作为公共 DNS 全被投毒时的兜底，不再当作首选。
fix_dns_doh() {
  local f="$DATA_DIR/Cloudflare-DoH.mobileconfig"
  local u1 u2; u1=$(uuidgen); u2=$(uuidgen)
  cat >"$f" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>PayloadContent</key><array><dict>
    <key>PayloadType</key><string>com.apple.dnsSettings.managed</string>
    <key>PayloadIdentifier</key><string>com.hx10.checkclaude-daemon.doh</string>
    <key>PayloadUUID</key><string>$u1</string>
    <key>PayloadVersion</key><integer>1</integer>
    <key>PayloadDisplayName</key><string>加密 DNS (Cloudflare DoH)</string>
    <key>DNSSettings</key><dict>
      <key>DNSProtocol</key><string>HTTPS</string>
      <key>ServerURL</key><string>https://cloudflare-dns.com/dns-query</string>
    </dict>
  </dict></array>
  <key>PayloadDisplayName</key><string>CheckClaude 加密 DNS</string>
  <key>PayloadIdentifier</key><string>com.hx10.checkclaude-daemon.doh.profile</string>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>$u2</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadRemovalDisallowed</key><false/>
</dict></plist>
PLIST
  echo "  📄 已生成 DoH 描述文件: $f"
  echo "     需到 系统设置 → 通用 → 设备管理 双击安装(macOS 不允许程序自动安装)"
  echo "     若报 'VPN service could not be created'，是代理 App 的网络扩展占用，先退出代理再装"
  open "$f" 2>/dev/null
}

apply_fixes() {
  local done_any=0 svc
  svc=$(active_service)

  # 1. 时区(无副作用，靠已配的免密 sudo)
  if [[ -n "${FIXABLE_TZ:-}" && -f "$TZ_SCRIPT" ]]; then
    echo "→ 修复时区: $SYS_TZ -> $FIXABLE_TZ"
    AUTO_TZ_DIR="$DATA_DIR" bash "$TZ_SCRIPT" >/dev/null 2>&1
    SYS_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
    TZ_OFFSET=$(date +%z); TZ_ABBR=$(date +%Z)
    if [[ "$SYS_TZ" == "$FIXABLE_TZ" ]]; then
      echo "  ✅ 已改为 $SYS_TZ"; log "fix: 时区 -> $SYS_TZ"; done_any=1
    else
      echo "  ⚠️  失败，需先运行一次: sudo bash enable-auto-timezone.sh"; NEED_SUDO=1
    fi
  fi

  # 2. 关掉 PAC 分流(分流会让账号画像在多地区跳变)
  if [[ "${PAC_ON:-0}" == "1" && -n "$svc" ]]; then
    echo "→ 关闭 PAC 自动分流 ($svc)"
    if sudo -n /usr/sbin/networksetup -setautoproxystate "$svc" off >/dev/null 2>&1; then
      echo "  ✅ 已关闭(撤销: networksetup -setautoproxystate \"$svc\" on)"
      log "fix: 关闭 PAC ($svc)"; PAC_ON=0; PROXY_MODE="${PROXY_MODE% + PAC 分流}"; done_any=1
    else
      echo "  ⚠️  需要授权，先运行一次: sudo bash enable-auto-timezone.sh"; NEED_SUDO=1
    fi
  fi

  # 3. DNS 泄漏 -> 换成验证过的境外 DNS(投毒时才退回 DoH)
  if [[ "$DNS_SCOPE" == 国内公共DNS* || "$DNS_VERDICT" == 被污染* ]]; then
    echo "→ 修复 DNS 泄漏 (当前 $DNS_SCOPE)"
    if [[ -n "$svc" ]]; then fix_dns_servers "$svc"; else echo "  ⚠️  找不到活跃网络服务"; fi
    done_any=1
  fi

  # 4. 系统区域(会影响日期格式显示，需显式 --fix-locale)
  if [[ $FIX_LOCALE -eq 1 && -n "${FIXABLE_LOCALE:-}" ]]; then
    local lang="${SYS_LOCALE%%_*}"
    echo "→ 修复系统区域: $SYS_LOCALE -> ${lang}_${FIXABLE_LOCALE}"
    defaults write -g AppleLocale "${lang}_${FIXABLE_LOCALE}" 2>/dev/null \
      && { echo "  ✅ 已改(重开 App 生效，撤销: defaults write -g AppleLocale $SYS_LOCALE)"; done_any=1; }
    SYS_LOCALE="${lang}_${FIXABLE_LOCALE}"; LOCALE_CC="$FIXABLE_LOCALE"
  elif [[ -n "${FIXABLE_LOCALE:-}" ]]; then
    echo "→ 系统区域与出口不一致，改它会影响日期格式显示，需显式确认: ./claude-check.sh --fix-locale"
  fi

  if [[ $done_any -eq 0 ]]; then
    echo "没有可自动修复的项"
  fi
  show_manual_guide "$done_any"
  return 0
}

# 需要用户自己动手的项(换节点、改浏览器语言、关 IPv6 …)，给出可照做的步骤
show_manual_guide() {
  local auto_done="$1" nl=$'\n' body="" l d h n=0
  build_gains
  while IFS='~' read -r l d h; do
    [[ -z "$l" ]] && continue
    # 这三项刚才已经自动处理过，不再重复要求用户做
    case "$l" in 系统时区匹配出口|"DNS 出口"|代理形态) continue ;; esac
    n=$((n+1))
    body+="${n}. ${l}（+${d} 分）${nl}   ${h}${nl}"
  done <<<"$(echo "$GAINS" | tr '|' '\n')"

  if [[ $n -eq 0 ]]; then
    [[ $auto_done -eq 1 ]] && notify "修复完成" "没有需要你手动处理的项"
    return 0
  fi
  echo ""
  echo "  下面 ${n} 项需要你自己操作:"
  echo "$body" | sed 's/^/  /'

  local tail_note="${nl}（这些步骤随时可以在菜单栏 →「📋 手动处理步骤」里翻到，不用记）"
  local head="已自动修复的部分完成。还有 ${n} 项需要你手动处理："
  [[ $auto_done -eq 0 ]] && head="有 ${n} 项需要你手动处理（这些无法自动完成）："
  osascript -e "display dialog \"${head}${nl}${nl}${body}${tail_note}\" buttons {\"知道了\"} default button 1 with title \"CheckClaude 修复指引\" with icon note" >/dev/null 2>&1 &
}

# 有哪些项能自动修 —— 菜单栏据此决定是否亮"一键修复"
fixable_list() {
  local l=""
  [[ -n "${FIXABLE_TZ:-}" ]] && l+="${l:+、}时区"
  [[ "${PAC_ON:-0}" == "1" ]] && l+="${l:+、}关PAC分流"
  [[ "$DNS_SCOPE" == 国内公共DNS* || "$DNS_VERDICT" == 被污染* ]] && l+="${l:+、}DNS加密"
  echo "$l"
}

write_cstatus() {
  local iptype
  iptype=$( [[ "$PROXY" == 1 ]] && echo 代理/VPN || { [[ "$HOSTING" == 1 ]] && echo 机房IDC || { [[ "$HOSTING" == -1 ]] && echo 未知 || echo 住宅; }; } )
  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "score=$SCORE"; echo "grade=$GRADE"; echo "verdict=$VERDICT"
    echo "ip=${PROBE_IP}"; echo "country=${COUNTRY:-?}"; echo "countryname=${COUNTRY_NAME:-?}"
    echo "city=${CITY:-?}"; echo "isp=${ISP:-?}"; echo "asn=${ASN:-?}"; echo "iptype=$iptype"
    echo "colo=${CF_COLO:-?}"; echo "api=${API_CODE}"; echo "web=${WEB_CODE}"
    echo "consistent=${CONSISTENT}"; echo "systz=${SYS_TZ}"; echo "iptz=${GFW_TZ:-?}"
    echo "tzoffset=${TZ_OFFSET} ${TZ_ABBR}"; echo "locale=${SYS_LOCALE:-?}"; echo "langs=${SYS_LANGS:-?}"
    echo "os=${OS_VER}"; echo "proxymode=${PROXY_MODE}"
    echo "vmhost=${VM_HOST}"; echo "ipchanges=${IP_CHANGES}"
    echo "brtz=${BR_TZ:-未采集}"; echo "brlangs=${BR_LANGS:-未采集}"
    echo "brrtc=${BR_RTC:-无}"; echo "brfonts=${BR_FONTS:-?}"; echo "brwebgl=${BR_WEBGL:-?}"
    echo "dns=${DNS_SCOPE}"; echo "dnsresult=${DNS_VERDICT}"
    echo "claudever=${CLAUDE_VER:-未安装}"; echo "base=${CLAUDE_BASE:-官方}"
    echo "fixable=$( [[ -n "$(fixable_list)" ]] && echo 1 || echo 0 )"
    echo "fixlist=$(fixable_list)"
    echo "needsudo=${NEED_SUDO:-0}"
    echo "signals=$(IFS=';'; echo "${SIGNALS[*]}")"
    echo "gains=$GAINS"
    echo "issues=$ISSUES"; echo "fixes=$FIXES"
  } >"$CSTATUS" 2>/dev/null || true
}

print_report() {
  local bar i
  bar=""; for ((i=0;i<20;i++)); do [[ $((i*5)) -lt $SCORE ]] && bar+="█" || bar+="░"; done
  echo ""
  echo "  Claude 运行环境体检"
  echo "  ──────────────────────────────────────────────────────"
  echo "  得分  $bar  ${SCORE}/100  【${GRADE}】"
  echo "  结论  ${VERDICT}"
  echo ""
  local group="" g l w p v
  for row in "${SIGNALS[@]}"; do
    IFS='~' read -r g l w p v <<<"$row"
    [[ "$g" != "$group" ]] && { group="$g"; echo "  ── $g ──"; }
    printf "  %-6s %-18s %-26s %2d/%-2d\n" "$([[ $p -eq $w ]] && echo ✓ || echo ⚠)" "$l" "$v" "$p" "$w"
  done
  echo ""
  echo "  出口 ${PROBE_IP} · ${COUNTRY_NAME:-?} ${CITY:-} · ${ISP:-?} · ${ASN:-?}"
  echo "  系统 ${OS_VER} · ${SYS_LOCALE:-?} · ${SYS_TZ} · ${PROXY_MODE} · ${VM_HOST}"
  echo "  DNS  ${DNS_SCOPE} · claude.ai → ${DNS_VERDICT}"
  echo "  CLI  ${CLAUDE_VER:-未检测到} · 接口 ${CLAUDE_BASE:-官方}"
  if [[ "$BR_OK" == "1" ]]; then
    echo "  浏览 ${BR_TZ} · ${BR_LANGS} · WebRTC ${BR_RTC:-无泄漏} · ${BR_FONTS:-无中文字体}"
  else
    echo "  浏览 未采集(浏览器信号由菜单栏 App 的隐藏 WebView 提供，命令行单跑时没有)"
  fi
  if [[ -n "$GAINS" ]]; then
    echo ""
    echo "  还能提 $((100 - SCORE)) 分"
    echo "$GAINS" | tr '|' '\n' | while IFS='~' read -r l d h; do
      [[ -z "$l" ]] && continue
      printf "    +%-3s %-18s %s\n" "$d" "$l" "$h"
    done
  fi
  if [[ -n "$ISSUES" ]]; then
    echo ""; echo "  发现的问题"
    echo "$ISSUES" | tr '|' '\n' | sed 's/^/    • /'
    echo ""; echo "  修复建议"
    echo "$FIXES" | tr '|' '\n' | grep -v '^$' | sed 's/^/    → /'
    [[ -n "${FIXABLE_TZ:-}" ]] && { echo ""; echo "    可自动修复: ./claude-check.sh --fix"; }
  else
    echo ""; echo "  ✅ 未发现环境矛盾信号"
  fi
  echo ""
}

main() {
  refresh_base
  fetch_all
  parse_net
  parse_dns
  parse_system
  parse_stability
  parse_browser
  parse_claude
  compute_score
  if [[ $DO_FIX -eq 1 ]]; then
    local before=$SCORE
    apply_fixes
    parse_dns              # DNS 改动后重新采集
    parse_system           # 代理形态可能也变了
    compute_score          # 修完重新打分
    if [[ "${NEED_SUDO:-0}" == "1" ]]; then
      notify "修复需要授权" "先运行一次 sudo bash enable-auto-timezone.sh"
    elif [[ $SCORE -gt $before ]]; then
      notify "Claude 环境已修复" "${before} → ${SCORE} 分"
    else
      # 分数没变不代表没干活(DoH 要用户自己点安装)，也得给个回音，
      # 否则从菜单点"一键修复"看着像什么都没发生。
      notify "体检完成" "${SCORE} 分$( [[ -n "$(fixable_list)" ]] && echo "，剩余待处理: $(fixable_list)" )"
    fi
  fi
  build_gains
  write_cstatus
  [[ "$MODE" != "quiet" ]] && print_report
  log "claude-check: ${SCORE}/100 ${GRADE} country=${COUNTRY:-?} api=${API_CODE} dns=${DNS_VERDICT}"
  exit 0
}

# ponytail: CC_SELFTEST=1 时只加载函数不执行，供 test-claude-check.sh 直接测评分逻辑
[[ -n "${CC_SELFTEST:-}" ]] || main "$@"
