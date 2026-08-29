#!/bin/bash
# claude-check.sh 评分逻辑自测: 不联网，直接喂信号给 compute_score 断言分数与建议。
set -uo pipefail
export CC_SELFTEST=1
source "$(dirname "$0")/claude-check.sh"

FAIL=0
check() { # check <描述> <实际> <期望>
  if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; else echo "  ✗ $1: 实际=$2 期望=$3"; FAIL=1; fi
}
set_signals() {
  COUNTRY="$1"; COUNTRY_NAME="$1"; ISP="test"; HOSTING="$2"; PROXY="$3"
  API_CODE="$4"; API_BLOCKED="$5"; CONSISTENT="$6"; SYS_TZ="$7"; GFW_TZ="$8"
  SYS_LOCALE="$9"; SYS_LANG="${SYS_LOCALE%%_*}"; LOCALE_CC="${SYS_LOCALE##*_}"
  CLAUDE_BASE=""; CLAUDE_VER="test"
}

echo "理想环境(美国住宅/API通/三路一致/时区区域都对) => 100"
set_signals US 0 0 401 0 1 America/Los_Angeles America/Los_Angeles en_US
compute_score
check "满分" "$SCORE" 100
check "无问题" "$ISSUES" ""

echo "国内直连(CN/API被拦/不一致/中文区域/机房IP) => 高风险"
set_signals CN 1 0 403 1 0 Asia/Shanghai America/New_York zh_CN
compute_score
check "低于 50" "$([[ $SCORE -lt 50 ]] && echo yes)" yes
check "评级高风险" "$GRADE" 高风险
check "点名不支持地区" "$(echo "$ISSUES" | grep -c '不在 Anthropic 服务范围')" 1
check "给出换节点建议" "$(echo "$FIXES" | grep -c '支持地区节点')" 1

echo "典型代理用户(美国机房IP/时区没跟上/中文区域) => 可自动修时区"
set_signals US 1 0 401 0 1 Asia/Shanghai America/New_York zh_CN
compute_score
check "标记时区可修" "$FIXABLE_TZ" America/New_York
check "分数落在 70-84" "$([[ $SCORE -ge 70 && $SCORE -lt 85 ]] && echo yes)" yes
check "评级良好" "$GRADE" 良好

echo "修好时区后应加满 10 分"
before=$SCORE
SYS_TZ=America/New_York; compute_score
check "分数 +10" "$SCORE" "$((before + 10))"
check "时区不再可修" "$FIXABLE_TZ" ""

echo "IP 情报接口挂了(国家未知) => 不至于判死"
set_signals "" -1 0 000 0 1 UTC "" en_US
compute_score
check "仍有分" "$([[ $SCORE -gt 20 ]] && echo yes)" yes

echo ""
[[ $FAIL -eq 0 ]] && echo "全部通过" || { echo "有用例失败"; exit 1; }
