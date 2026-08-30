#!/bin/bash
# claude-check.sh
# Claude / Claude Code 运行环境体检: 多信号加权打分 + 问题清单 + 修复建议 + 自动修复。
#
# 评分模型参考 https://github.com/yacuo/check-cc (MIT)，但那边是浏览器端检测(WebRTC /
# Client Hints / Emoji 渲染 / 字体探测靠 JS 拿)，这里是 macOS 本地实现: 凡是 shell 能测的
# 信号全部覆盖(网络出口 / 服务可达 / 画像一致 / DNS 共 15 项)，浏览器独有的信号测不了，
# 在报告里明确标注为"未覆盖"，不假装有。
#
# 用法:
#   ./claude-check.sh              # 体检并打印报告
#   ./claude-check.sh --fix        # 体检 + 自动修可安全修复项(时区)，再重新打分
#   ./claude-check.sh --fix-locale # 额外把系统"区域"改成出口国家(会影响日期格式显示)
#   ./claude-check.sh --quiet      # 只写状态文件，不打印

set -uo pipefail

DATA_DIR="${AUTO_TZ_DIR:-$HOME/Library/Application Support/AutoTimezone}"
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
  dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [[ "$dev" == utun* ]] && PROXY_MODE="TUN 全局"
  http_p=$(scutil --proxy 2>/dev/null | awk '/HTTPEnable/{print $3}')
  pac=$(scutil --proxy 2>/dev/null | awk '/ProxyAutoConfigEnable/{print $3}')
  [[ "$PROXY_MODE" == "直连" && "$http_p" == "1" ]] && PROXY_MODE="系统 HTTP 代理"
  [[ "$pac" == "1" ]] && PROXY_MODE="$PROXY_MODE + PAC 分流"
  PAC_ON=$([[ "$pac" == "1" ]] && echo 1 || echo 0)
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

# ── 打分: 15 项加权信号，合计 100 ───────────────────────────────
compute_score() {
  SIGNALS=(); SCORE=0; ISSUES=""; FIXES=""; FIXABLE_TZ=""; FIXABLE_LOCALE=""
  local relay=0
  [[ -n "$CLAUDE_BASE" && "$CLAUDE_BASE" != *"api.anthropic.com"* ]] && relay=1

  # ── A. 出口地区与服务可用 (45) ──
  if [[ -z "$COUNTRY" ]]; then
    sig 出口 "出口国家" 22 50 "未知" "出口 IP 归属地未知(IP 情报接口不可达)" "检查网络后重新体检"
  elif in_list "$COUNTRY" "$UNSUPPORTED"; then
    sig 出口 "出口国家" 22 0 "$COUNTRY 不支持" \
      "出口国家 ${COUNTRY} 不在 Anthropic 服务范围，登录/订阅/API 均有封号风险" \
      "切到美国/日本/新加坡等支持地区节点，并长期固定，不要频繁换国家"
  elif in_list "$COUNTRY" "$SUPPORTED"; then
    sig 出口 "出口国家" 22 100 "$COUNTRY ${CITY:-}"
  else
    sig 出口 "出口国家" 22 66 "$COUNTRY 支持未知" "出口国家 ${COUNTRY} 支持情况未知" "建议改用 US/JP/SG 等已知支持地区节点"
  fi

  if [[ "$API_CODE" == "401" || "$API_CODE" == "400" ]]; then
    sig 出口 "Anthropic API 可达" 13 100 "HTTP $API_CODE"
  elif [[ "$API_CODE" == "403" || "$API_REGION_BLOCK" == "1" ]]; then
    sig 出口 "Anthropic API 可达" 13 0 "HTTP 403 地区拦截" \
      "api.anthropic.com 返回 403，当前出口被地区拦截" "更换支持地区节点；确认代理为全局而非 PAC 分流"
  elif [[ "$API_CODE" == "000" && $relay -eq 1 ]]; then
    sig 出口 "Anthropic API 可达" 13 50 "直连不通(已配中转)" \
      "api.anthropic.com 直连不通，但你已配置中转 ${CLAUDE_BASE}" "只用中转可忽略；需直连官方则开全局代理"
  elif [[ "$API_CODE" == "000" ]]; then
    sig 出口 "Anthropic API 可达" 13 0 "连不上" \
      "api.anthropic.com 连不上(超时/DNS 污染)" "开启全局代理；检查 DNS 是否被污染"
  else
    sig 出口 "Anthropic API 可达" 13 50 "HTTP $API_CODE" "api.anthropic.com 返回异常状态 ${API_CODE}" "稍后重试；持续异常则换节点"
  fi

  case "$WEB_CODE" in
    200|301|302|307) sig 出口 "claude.ai 可达" 7 100 "HTTP $WEB_CODE" ;;
    403)             sig 出口 "claude.ai 可达" 7 20 "HTTP 403 被拦" \
                       "claude.ai 返回 403(Cloudflare 地区拦截或风控挑战)" "换支持地区的干净节点，网页端登录前先确认能打开" ;;
    000)             sig 出口 "claude.ai 可达" 7 0 "连不上" "claude.ai 连不上" "开启全局代理" ;;
    *)               sig 出口 "claude.ai 可达" 7 60 "HTTP $WEB_CODE" ;;
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

  # ── B. 出口质量 (15) ──
  if [[ "$PROXY" == "1" ]]; then
    sig 质量 "IP 类型" 8 25 "公开代理/VPN" "出口 IP 被标记为公开代理/VPN 出口，属高风控段" "换独享节点或住宅 IP，避免与大量用户共用出口"
  elif [[ "$HOSTING" == "1" ]]; then
    sig 质量 "IP 类型" 8 50 "机房 IDC" "出口是机房(IDC) IP: ${ISP}，风控强度高于住宅" "有条件换住宅/家宽节点；至少保证独享且长期不变"
  elif [[ "$HOSTING" == "0" ]]; then
    sig 质量 "IP 类型" 8 100 "住宅"
  else
    sig 质量 "IP 类型" 8 70 "未知"
  fi

  # Cloudflare 边缘机房国家 vs IP 库国家: 不一致说明 IP 归属被"改过"或链路绕路
  if [[ -n "$CF_LOC" && -n "$COUNTRY" ]]; then
    if [[ "$CF_LOC" == "$COUNTRY" ]]; then
      sig 质量 "边缘机房匹配" 4 100 "${CF_COLO} (${CF_LOC})"
    else
      sig 质量 "边缘机房匹配" 4 25 "${CF_COLO}(${CF_LOC}) ≠ ${COUNTRY}" \
        "Cloudflare 边缘落在 ${CF_LOC}，与 IP 库归属 ${COUNTRY} 不一致" "该 IP 的地理归属可能是伪造的，换归属真实的节点"
    fi
  else
    sig 质量 "边缘机房匹配" 4 50 "${CF_COLO:-未知}"
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

  # ── C. 画像一致性 (25) ──
  if [[ "$CONSISTENT" == "1" ]]; then
    sig 画像 "三路出口一致" 8 100 "$PROBE_IP"
  else
    sig 画像 "三路出口一致" 8 30 "不一致" \
      "三路出口 IP 不一致(分流/PAC/DNS 泄漏)，账号画像会在多地区间跳变" "代理切全局模式，让国内/国外/谷歌三路走同一出口"
  fi

  if [[ -n "$GFW_TZ" && "$GFW_TZ" == "$SYS_TZ" ]]; then
    sig 画像 "系统时区匹配出口" 7 100 "$SYS_TZ"
  elif [[ -z "$GFW_TZ" || "$GFW_TZ" == "?" ]]; then
    sig 画像 "系统时区匹配出口" 7 50 "出口时区未知" "无法解析出口 IP 对应时区"
  else
    sig 画像 "系统时区匹配出口" 7 0 "$SYS_TZ ≠ $GFW_TZ" \
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
    sig 画像 "系统区域匹配出口" 5 50 "数据不足"
  elif [[ "$LOCALE_CC" == "$COUNTRY" ]]; then
    sig 画像 "系统区域匹配出口" 5 100 "$SYS_LOCALE"
  elif [[ "$SYS_LANG" == zh* ]]; then
    sig 画像 "系统区域匹配出口" 5 50 "$SYS_LOCALE vs $COUNTRY" \
      "系统语言中文 + 区域 ${LOCALE_CC:-?} 与出口 ${COUNTRY} 不一致(网页端登录会暴露矛盾)" \
      "仅用 Claude Code(CLI) 可忽略；常用网页端可把系统区域改成 ${COUNTRY}(不用改显示语言)"
    FIXABLE_LOCALE="$COUNTRY"
  else
    sig 画像 "系统区域匹配出口" 5 70 "$SYS_LOCALE vs $COUNTRY" "系统区域 ${LOCALE_CC:-?} 与出口 ${COUNTRY} 不一致"
    FIXABLE_LOCALE="$COUNTRY"
  fi

  if [[ "$PAC_ON" == "1" ]]; then
    sig 画像 "代理形态" 3 20 "$PROXY_MODE" \
      "启用了 PAC 自动分流，不同网站会走不同出口，账号画像不稳定" "关掉 PAC，改用 TUN 全局模式"
  elif [[ "$PROXY_MODE" == "TUN 全局" ]]; then
    sig 画像 "代理形态" 3 100 "$PROXY_MODE"
  else
    sig 画像 "代理形态" 3 70 "$PROXY_MODE"
  fi

  # ── D. DNS (15) ──
  case "$DNS_VERDICT" in
    正常*|代理接管*) sig DNS "claude.ai 解析" 9 100 "$DNS_VERDICT" ;;
    被污染*)        sig DNS "claude.ai 解析" 9 0 "$DNS_VERDICT" \
                      "claude.ai 的 DNS 解析被污染(${DNS_RESULT})" "换 DoH/加密 DNS，或让代理接管 DNS(fake-ip 模式)" ;;
    解析失败)       sig DNS "claude.ai 解析" 9 20 "失败" "claude.ai 无法解析" "检查 DNS 设置，建议让代理接管 DNS" ;;
    *)              sig DNS "claude.ai 解析" 9 40 "$DNS_VERDICT" \
                      "claude.ai 解析到非 Cloudflare 地址(${DNS_RESULT})，可能被劫持" "换 DoH/加密 DNS 或由代理接管 DNS" ;;
  esac

  case "$DNS_SCOPE" in
    本地/代理接管*) sig DNS "DNS 出口" 6 100 "$DNS_SCOPE" ;;
    国内公共DNS*)   sig DNS "DNS 出口" 6 0 "$DNS_SCOPE" \
                      "正在用${DNS_SCOPE}，DNS 查询泄漏到国内，与国外出口矛盾" \
                      "改用 1.1.1.1 / 8.8.8.8 或让代理接管 DNS" ;;
    *)              sig DNS "DNS 出口" 6 80 "$DNS_SCOPE" ;;
  esac

  if   [[ $SCORE -ge 85 ]]; then GRADE="优秀"; VERDICT="环境适合运行 Claude"
  elif [[ $SCORE -ge 70 ]]; then GRADE="良好"; VERDICT="基本可用，建议修复下列项"
  elif [[ $SCORE -ge 50 ]]; then GRADE="风险"; VERDICT="存在明显矛盾信号，有封号风险"
  else                           GRADE="高风险"; VERDICT="不建议在当前环境登录或使用 Claude"
  fi
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

# 生成并打开 DoH 描述文件。在国内直接把 DNS 改成 1.1.1.1 会被投毒污染，
# 明文 DNS 换谁都一样，只有加密 DNS(DoH) 才真正解决泄漏，所以修复走 mobileconfig。
fix_dns_doh() {
  local f="$DATA_DIR/Cloudflare-DoH.mobileconfig"
  local u1 u2; u1=$(uuidgen); u2=$(uuidgen)
  cat >"$f" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>PayloadContent</key><array><dict>
    <key>PayloadType</key><string>com.apple.dnsSettings.managed</string>
    <key>PayloadIdentifier</key><string>com.hx10.auto-timezone.doh</string>
    <key>PayloadUUID</key><string>$u1</string>
    <key>PayloadVersion</key><integer>1</integer>
    <key>PayloadDisplayName</key><string>加密 DNS (Cloudflare DoH)</string>
    <key>DNSSettings</key><dict>
      <key>DNSProtocol</key><string>HTTPS</string>
      <key>ServerURL</key><string>https://cloudflare-dns.com/dns-query</string>
    </dict>
  </dict></array>
  <key>PayloadDisplayName</key><string>AutoTimezone 加密 DNS</string>
  <key>PayloadIdentifier</key><string>com.hx10.auto-timezone.doh.profile</string>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>$u2</string>
  <key>PayloadVersion</key><integer>1</integer>
</dict></plist>
PLIST
  open "$f" 2>/dev/null
  open "x-apple.systempreferences:com.apple.preference.security?Profiles" 2>/dev/null
  echo "  📄 已生成 DoH 描述文件并打开系统设置，点「安装」即可(撤销=在描述文件里删除)"
  echo "     $f"
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

  # 3. DNS 泄漏 -> 上加密 DNS
  if [[ "$DNS_SCOPE" == 国内公共DNS* || "$DNS_VERDICT" == 被污染* ]]; then
    echo "→ 修复 DNS 泄漏 (当前 $DNS_SCOPE)"
    fix_dns_doh; done_any=1
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
    echo "没有可自动修复的项(剩下的是换节点/换住宅 IP，只能手动)"
  fi
  return 0
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
    echo "dns=${DNS_SCOPE}"; echo "dnsresult=${DNS_VERDICT}"
    echo "claudever=${CLAUDE_VER:-未安装}"; echo "base=${CLAUDE_BASE:-官方}"
    echo "fixable=$( [[ -n "$(fixable_list)" ]] && echo 1 || echo 0 )"
    echo "fixlist=$(fixable_list)"
    echo "needsudo=${NEED_SUDO:-0}"
    echo "signals=$(IFS=';'; echo "${SIGNALS[*]}")"
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
  echo "  系统 ${OS_VER} · ${SYS_LOCALE:-?} · ${SYS_TZ} · ${PROXY_MODE}"
  echo "  DNS  ${DNS_SCOPE} · claude.ai → ${DNS_VERDICT}"
  echo "  CLI  ${CLAUDE_VER:-未检测到} · 接口 ${CLAUDE_BASE:-官方}"
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
  parse_claude
  compute_score
  if [[ $DO_FIX -eq 1 ]]; then
    local before=$SCORE
    apply_fixes
    parse_dns              # DNS 改动后重新采集
    compute_score          # 修完重新打分
    if [[ "${NEED_SUDO:-0}" == "1" ]]; then
      notify "修复需要授权" "先运行一次 sudo bash enable-auto-timezone.sh"
    elif [[ $SCORE -gt $before ]]; then
      notify "Claude 环境已修复" "${before} → ${SCORE} 分"
    fi
  fi
  write_cstatus
  [[ "$MODE" != "quiet" ]] && print_report
  log "claude-check: ${SCORE}/100 ${GRADE} country=${COUNTRY:-?} api=${API_CODE} dns=${DNS_VERDICT}"
  exit 0
}

# ponytail: CC_SELFTEST=1 时只加载函数不执行，供 test-claude-check.sh 直接测评分逻辑
[[ -n "${CC_SELFTEST:-}" ]] || main "$@"
