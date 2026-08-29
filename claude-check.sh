#!/bin/bash
# claude-check.sh
# Claude / Claude Code 运行环境体检: 打分 + 问题清单 + 修复建议 + 自动修复。
#
# 评分思路参考 https://github.com/yacuo/check-cc (MIT) 的"多信号加权聚合"模型，
# 但那边是浏览器端指纹检测，这里改成 macOS 本地实现，直接复用 auto-timezone.sh
# 已经拿到的三路出口 IP 数据，不重复请求。
#
# 分数含义: 越高越适合跑 Claude(0-100)。它只反映环境画像冲突，不代表官方判定。
#
# 用法:
#   ./claude-check.sh              # 体检并打印报告
#   ./claude-check.sh --fix        # 体检 + 自动修可安全修复项(目前=时区)，再重新打分
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

MODE="report"; DO_FIX=0; FIX_LOCALE=0
case "${1:-}" in
  --fix)        DO_FIX=1 ;;
  --fix-locale) DO_FIX=1; FIX_LOCALE=1 ;;
  --quiet)      MODE="quiet" ;;
esac

CURL='curl -fsS --max-time 9 -A Mozilla/5.0'
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG" 2>/dev/null || true; }

# ── 权重(合计 100) ──────────────────────────────────────────────
W_COUNTRY=30   # 出口国家是否在 Anthropic 支持范围
W_API=25       # api.anthropic.com 是否可达/未被地区拦截
W_CONSIST=15   # 三路出口 IP 是否一致(画像稳定性)
W_TZ=10        # 系统时区与出口 IP 时区是否一致
W_LOCALE=10    # 系统语言/区域与出口地区是否矛盾
W_IPQ=10       # 出口 IP 质量(机房/代理 IP 风控更严)

# Anthropic 明确不提供服务的地区
UNSUPPORTED="CN HK MO RU IR KP CU SY BY VE"
# 常见明确支持地区(不在此列也不一定不支持，按"可能支持"给部分分)
SUPPORTED="US CA GB IE DE FR NL SE NO DK FI IT ES PT PL CZ AT CH BE LU JP KR SG TW AU NZ IL AE MX BR IN PH TH MY ID VN ZA TR SA AR CL"

ISSUES=""; FIXES=""
add_issue() { ISSUES+="${ISSUES:+|}$1"; }
add_fix()   { FIXES+="${FIXES:+|}$1"; }
in_list()   { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── 1. 复用/刷新三路出口快照 ────────────────────────────────────
read_status() {
  CONSISTENT=""; GFW_IP=""; INTL_IP=""; SYS_TZ=""; GFW_TZ=""; GOOGLE=""
  [[ -f "$STATUS" ]] || return 1
  while IFS='=' read -r k v; do
    case "$k" in
      consistent) CONSISTENT="$v" ;;
      gfw)        GFW_IP="$v" ;;
      intl)       INTL_IP="$v" ;;
      tz)         SYS_TZ="$v" ;;
      gfwtz)      GFW_TZ="$v" ;;
      google)     GOOGLE="$v" ;;
    esac
  done <"$STATUS"
  [[ -n "$CONSISTENT" ]]
}

# 快照超过 5 分钟就先跑一次三路检测(--check 不改时区)
refresh_base() {
  local age=999999
  [[ -f "$STATUS" ]] && age=$(( $(date +%s) - $(stat -f %m "$STATUS" 2>/dev/null || echo 0) ))
  if [[ $age -gt 300 && -x "$TZ_SCRIPT" ]] || [[ ! -f "$STATUS" && -f "$TZ_SCRIPT" ]]; then
    AUTO_TZ_DIR="$DATA_DIR" bash "$TZ_SCRIPT" --check >/dev/null 2>&1
  fi
  read_status || true
  INTL_IP="${INTL_IP:-?}"
}

# ── 2. 出口 IP 画像: 国家 / ISP / 是否机房或代理 ────────────────
# ip-api.com 一次请求拿全所需字段(免费版仅 HTTP)，ipinfo.io 作兜底
probe_ip() {
  COUNTRY=""; COUNTRY_NAME=""; ISP=""; HOSTING=0; PROXY=0
  local ip="$GFW_IP" json
  [[ "$ip" == "?" || -z "$ip" ]] && ip="$INTL_IP"
  [[ "$ip" == "?" || -z "$ip" ]] && return 1
  PROBE_IP="$ip"

  json=$($CURL "http://ip-api.com/json/${ip}?fields=status,country,countryCode,isp,org,proxy,hosting" 2>/dev/null)
  if [[ "$json" == *'"status":"success"'* ]]; then
    COUNTRY=$(echo "$json"      | grep -Eo '"countryCode":"[^"]*"' | cut -d'"' -f4)
    COUNTRY_NAME=$(echo "$json" | grep -Eo '"country":"[^"]*"'     | cut -d'"' -f4)
    ISP=$(echo "$json"          | grep -Eo '"isp":"[^"]*"'         | cut -d'"' -f4)
    [[ "$json" == *'"hosting":true'* ]] && HOSTING=1
    [[ "$json" == *'"proxy":true'*   ]] && PROXY=1
    return 0
  fi
  # 兜底: ipinfo 只有国家和 org，拿不到 hosting/proxy 标记
  json=$($CURL "https://ipinfo.io/${ip}/json" 2>/dev/null)
  COUNTRY=$(echo "$json" | grep -Eo '"country":[[:space:]]*"[^"]*"' | cut -d'"' -f4)
  ISP=$(echo "$json"     | grep -Eo '"org":[[:space:]]*"[^"]*"'     | cut -d'"' -f4)
  COUNTRY_NAME="$COUNTRY"
  HOSTING=-1   # 未知
  [[ -n "$COUNTRY" ]]
}

# ── 3. Anthropic API 可达性 ─────────────────────────────────────
# 不带 key 请求应返回 401(通)；403 + unsupported_country = 该出口被地区拦截
probe_api() {
  local out code
  out=$(curl -s -m 10 -o /tmp/.cc_api_body -w '%{http_code}' \
        -H 'content-type: application/json' \
        https://api.anthropic.com/v1/messages -d '{}' 2>/dev/null)
  code="${out:-000}"
  API_CODE="$code"
  API_BLOCKED=0
  if [[ "$code" == "403" ]] || grep -qi 'unsupported_country\|not available in your\|region' /tmp/.cc_api_body 2>/dev/null; then
    [[ "$code" == "403" ]] && API_BLOCKED=1
  fi
  rm -f /tmp/.cc_api_body
}

# ── 4. 系统语言/区域 ────────────────────────────────────────────
probe_locale() {
  SYS_LOCALE=$(defaults read -g AppleLocale 2>/dev/null || echo "")
  SYS_LANG=$(defaults read -g AppleLanguages 2>/dev/null | grep -Eo '"[a-zA-Z-]+"' | head -1 | tr -d '"')
  LOCALE_CC="${SYS_LOCALE##*_}"          # zh_CN -> CN
  [[ "$LOCALE_CC" == "$SYS_LOCALE" ]] && LOCALE_CC=""
}

# ── 5. Claude Code 本地环境(信息项，不计分) ─────────────────────
probe_claude() {
  CLAUDE_VER=""; CLAUDE_BASE=""
  local bin
  # App 启动的进程 PATH 很干净，命中不了 shell 里的安装位置，所以显式扫常见路径
  bin=$(command -v claude 2>/dev/null) \
    || bin=$(ls "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "$HOME/.bun/bin/claude" \
               /usr/local/bin/claude /opt/homebrew/bin/claude 2>/dev/null | head -1)
  [[ -n "$bin" ]] && CLAUDE_VER=$("$bin" --version 2>/dev/null | head -1)
  # 中转地址可能写在 settings.json 或 shell rc 里
  CLAUDE_BASE="${ANTHROPIC_BASE_URL:-}"
  [[ -z "$CLAUDE_BASE" && -f "$HOME/.claude/settings.json" ]] && \
    CLAUDE_BASE=$(grep -Eo '"ANTHROPIC_BASE_URL"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" | cut -d'"' -f4)
  [[ -z "$CLAUDE_BASE" && -f "$HOME/.zshrc" ]] && \
    CLAUDE_BASE=$(grep -E '^[[:space:]]*export[[:space:]]+ANTHROPIC_BASE_URL' "$HOME/.zshrc" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')
}

# ── 6. 打分 ─────────────────────────────────────────────────────
compute_score() {
  ISSUES=""; FIXES=""; SCORE=0; FIXABLE_TZ=""; FIXABLE_LOCALE=""
  local relay=0
  [[ -n "$CLAUDE_BASE" && "$CLAUDE_BASE" != *"api.anthropic.com"* ]] && relay=1

  # 出口国家
  if [[ -z "$COUNTRY" ]]; then
    SCORE=$((SCORE + W_COUNTRY / 2))
    add_issue "出口 IP 归属地未知(IP 情报接口不可达)"
    add_fix "检查网络后重新体检；接口 ip-api.com 走 HTTP 明文，被拦截时会失败"
  elif in_list "$COUNTRY" "$UNSUPPORTED"; then
    add_issue "出口国家 ${COUNTRY} 不在 Anthropic 服务范围，登录/订阅/API 均有封号风险"
    add_fix "把代理切到美国/日本/新加坡等支持地区节点，且保持长期固定，不要频繁换国家"
  elif in_list "$COUNTRY" "$SUPPORTED"; then
    SCORE=$((SCORE + W_COUNTRY))
  else
    SCORE=$((SCORE + W_COUNTRY * 2 / 3))
    add_issue "出口国家 ${COUNTRY} 支持情况未知"
    add_fix "建议改用 US/JP/SG 等已知支持地区的节点"
  fi

  # API 可达性
  if [[ "$API_CODE" == "401" || "$API_CODE" == "400" ]]; then
    SCORE=$((SCORE + W_API))
  elif [[ "$API_BLOCKED" == "1" ]]; then
    add_issue "api.anthropic.com 返回 403，当前出口被地区拦截"
    add_fix "更换到支持地区的节点；确认代理为全局模式而非 PAC 分流"
  elif [[ "$API_CODE" == "000" ]]; then
    if [[ $relay -eq 1 ]]; then
      SCORE=$((SCORE + W_API / 2))
      add_issue "api.anthropic.com 直连不通(你已配置中转 ${CLAUDE_BASE}，CLI 本身可能仍可用)"
      add_fix "如需直连官方，开全局代理；只用中转可忽略此项"
    else
      add_issue "api.anthropic.com 连不上(超时/DNS 污染)"
      add_fix "开启代理并确认为全局模式；检查 DNS 是否被污染(可换 1.1.1.1 / DoH)"
    fi
  else
    SCORE=$((SCORE + W_API / 2))
    add_issue "api.anthropic.com 返回异常状态 ${API_CODE}"
    add_fix "稍后重试；持续异常则更换出口节点"
  fi

  # 三路一致性
  if [[ "$CONSISTENT" == "1" ]]; then
    SCORE=$((SCORE + W_CONSIST))
  else
    SCORE=$((SCORE + W_CONSIST / 3))
    add_issue "三路出口 IP 不一致(分流/PAC/DNS 泄漏)，账号画像会在多个地区间跳变"
    add_fix "代理切成全局模式，让国内/国外/谷歌三路走同一出口"
  fi

  # 时区
  if [[ -n "$GFW_TZ" && "$GFW_TZ" == "$SYS_TZ" ]]; then
    SCORE=$((SCORE + W_TZ))
  elif [[ -z "$GFW_TZ" || "$GFW_TZ" == "?" ]]; then
    SCORE=$((SCORE + W_TZ / 2))
    add_issue "无法解析出口 IP 对应时区"
  else
    add_issue "系统时区 ${SYS_TZ} 与出口时区 ${GFW_TZ} 不一致，是典型的环境矛盾信号"
    add_fix "可一键修复: 把系统时区改为 ${GFW_TZ}"
    FIXABLE_TZ="$GFW_TZ"
  fi

  # 语言/区域
  if [[ -z "$COUNTRY" || -z "$SYS_LOCALE" ]]; then
    SCORE=$((SCORE + W_LOCALE / 2))
  elif [[ "$LOCALE_CC" == "$COUNTRY" ]]; then
    SCORE=$((SCORE + W_LOCALE))
  elif [[ "$SYS_LANG" == zh* ]]; then
    SCORE=$((SCORE + W_LOCALE / 2))
    add_issue "系统语言中文 + 区域 ${LOCALE_CC:-?} 与出口 ${COUNTRY} 不一致(网页端登录会暴露矛盾)"
    add_fix "仅用 Claude Code(CLI)可忽略；若常用网页端，可把系统区域改成 ${COUNTRY}(不用改显示语言)"
    FIXABLE_LOCALE="$COUNTRY"
  else
    SCORE=$((SCORE + W_LOCALE * 7 / 10))
    add_issue "系统区域 ${LOCALE_CC:-?} 与出口 ${COUNTRY} 不一致"
    FIXABLE_LOCALE="$COUNTRY"
  fi

  # IP 质量
  if [[ "$HOSTING" == "-1" ]]; then
    SCORE=$((SCORE + W_IPQ * 7 / 10))
  elif [[ "$PROXY" == "1" ]]; then
    SCORE=$((SCORE + W_IPQ / 4))
    add_issue "出口 IP 被标记为公开代理/VPN 出口，属于高风控段"
    add_fix "换用独享节点或住宅 IP，避免与大量用户共用同一出口"
  elif [[ "$HOSTING" == "1" ]]; then
    SCORE=$((SCORE + W_IPQ / 2))
    add_issue "出口是机房(IDC) IP: ${ISP}，风控强度高于住宅 IP"
    add_fix "有条件换住宅/家宽节点；至少保证该 IP 独享且长期不变"
  else
    SCORE=$((SCORE + W_IPQ))
  fi

  if   [[ $SCORE -ge 85 ]]; then GRADE="优秀"; VERDICT="环境适合运行 Claude"
  elif [[ $SCORE -ge 70 ]]; then GRADE="良好"; VERDICT="基本可用，建议修复下列项"
  elif [[ $SCORE -ge 50 ]]; then GRADE="风险"; VERDICT="存在明显矛盾信号，有封号风险"
  else                           GRADE="高风险"; VERDICT="不建议在当前环境登录或使用 Claude"
  fi
}

# ── 7. 自动修复 ─────────────────────────────────────────────────
apply_fixes() {
  local done_any=0
  if [[ -n "${FIXABLE_TZ:-}" && -x "$TZ_SCRIPT" ]]; then
    echo "→ 修复时区: $SYS_TZ -> $FIXABLE_TZ"
    AUTO_TZ_DIR="$DATA_DIR" bash "$TZ_SCRIPT" >/dev/null 2>&1
    SYS_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
    if [[ "$SYS_TZ" == "$FIXABLE_TZ" ]]; then
      echo "  ✅ 已改为 $SYS_TZ"; log "claude-check: 已修复时区 -> $SYS_TZ"; done_any=1
    else
      echo "  ⚠️  改时区失败，需先运行一次: sudo bash enable-auto-timezone.sh"
    fi
  fi
  if [[ $FIX_LOCALE -eq 1 && -n "${FIXABLE_LOCALE:-}" ]]; then
    local lang="${SYS_LOCALE%%_*}"
    echo "→ 修复系统区域: $SYS_LOCALE -> ${lang}_${FIXABLE_LOCALE}"
    defaults write -g AppleLocale "${lang}_${FIXABLE_LOCALE}" 2>/dev/null \
      && { echo "  ✅ 已改(重开 App 生效，撤销: defaults write -g AppleLocale $SYS_LOCALE)"; done_any=1; }
    SYS_LOCALE="${lang}_${FIXABLE_LOCALE}"; LOCALE_CC="$FIXABLE_LOCALE"
  fi
  [[ $done_any -eq 0 ]] && echo "没有可自动修复的项(其余需手动调整代理/节点)"
  return 0
}

write_cstatus() {
  {
    echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "score=$SCORE"
    echo "grade=$GRADE"
    echo "verdict=$VERDICT"
    echo "ip=${PROBE_IP:-?}"
    echo "country=${COUNTRY:-?}"
    echo "countryname=${COUNTRY_NAME:-?}"
    echo "isp=${ISP:-?}"
    echo "iptype=$( [[ "$PROXY" == 1 ]] && echo 代理/VPN || { [[ "$HOSTING" == 1 ]] && echo 机房IDC || { [[ "$HOSTING" == -1 ]] && echo 未知 || echo 住宅; }; } )"
    echo "api=${API_CODE:-?}"
    echo "consistent=${CONSISTENT:-?}"
    echo "systz=${SYS_TZ:-?}"
    echo "iptz=${GFW_TZ:-?}"
    echo "locale=${SYS_LOCALE:-?}"
    echo "claudever=${CLAUDE_VER:-未安装}"
    echo "base=${CLAUDE_BASE:-官方}"
    echo "fixable=$( [[ -n "${FIXABLE_TZ:-}" ]] && echo 1 || echo 0 )"
    echo "issues=$ISSUES"
    echo "fixes=$FIXES"
  } >"$CSTATUS" 2>/dev/null || true
}

print_report() {
  local bar i
  bar=""; for ((i=0;i<20;i++)); do [[ $((i*5)) -lt $SCORE ]] && bar+="█" || bar+="░"; done
  echo ""
  echo "  Claude 运行环境体检"
  echo "  ────────────────────────────────────────────"
  echo "  得分  $bar  ${SCORE}/100  【${GRADE}】"
  echo "  结论  ${VERDICT}"
  echo ""
  echo "  出口 IP    ${PROBE_IP:-?}  (${COUNTRY_NAME:-?} ${COUNTRY:-?})"
  echo "  归属       ${ISP:-?}"
  echo "  IP 类型    $( [[ "$PROXY" == 1 ]] && echo 代理/VPN || { [[ "$HOSTING" == 1 ]] && echo 机房IDC || { [[ "$HOSTING" == -1 ]] && echo 未知 || echo 住宅; }; } )"
  echo "  API 直连   HTTP ${API_CODE}$( [[ "$API_CODE" == 401 ]] && echo '  (正常，未带密钥)' )"
  echo "  三路一致   $( [[ "$CONSISTENT" == 1 ]] && echo 是 || echo 否 )"
  echo "  时区       系统 ${SYS_TZ:-?}  /  出口 ${GFW_TZ:-?}"
  echo "  语言区域   ${SYS_LOCALE:-?}"
  echo "  Claude CLI ${CLAUDE_VER:-未检测到}   接口: ${CLAUDE_BASE:-官方}"
  if [[ -n "$ISSUES" ]]; then
    echo ""
    echo "  发现的问题"
    echo "$ISSUES" | tr '|' '\n' | sed 's/^/    • /'
    echo ""
    echo "  修复建议"
    echo "$FIXES" | tr '|' '\n' | grep -v '^$' | sed 's/^/    → /'
    [[ -n "${FIXABLE_TZ:-}" ]] && echo "" && echo "    可自动修复: 运行 ./claude-check.sh --fix"
  else
    echo ""
    echo "  ✅ 未发现环境矛盾信号"
  fi
  echo ""
}

main() {
  refresh_base
  probe_ip
  probe_api
  probe_locale
  probe_claude
  compute_score
  if [[ $DO_FIX -eq 1 ]]; then
    apply_fixes
    compute_score          # 修完重新打分
  fi
  write_cstatus
  [[ "$MODE" != "quiet" ]] && print_report
  log "claude-check: ${SCORE}/100 ${GRADE} country=${COUNTRY:-?} api=${API_CODE}"
  exit 0
}

# ponytail: CC_SELFTEST=1 时只加载函数不执行，供 test-claude-check.sh 直接测评分逻辑
[[ -n "${CC_SELFTEST:-}" ]] || main "$@"
