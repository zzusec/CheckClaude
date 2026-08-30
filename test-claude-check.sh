#!/bin/bash
# claude-check.sh 评分逻辑自测: 不联网，直接喂信号给 compute_score 断言分数与建议。
set -uo pipefail
export CC_SELFTEST=1
source "$(dirname "$0")/claude-check.sh"

FAIL=0
check() { # check <描述> <实际> <期望>
  if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; else echo "  ✗ $1: 实际=$2 期望=$3"; FAIL=1; fi
}

# 一个"完美环境"的基线，各用例只覆盖自己关心的字段
base_signals() {
  COUNTRY=US; COUNTRY2=US; COUNTRY_NAME=美国; CITY=LA; ISP=Comcast; ASN=AS7922
  HOSTING=0; PROXY=0
  API_CODE=401; WEB_CODE=200; API_REGION_BLOCK=0
  CF_COLO=LAX; CF_LOC=US; CF_IP=1.2.3.4; PROBE_IP=1.2.3.4
  CONSISTENT=1; SYS_TZ=America/Los_Angeles; GFW_TZ=America/Los_Angeles
  TZ_SELF_CONSISTENT=1; TZ_OFFSET=-0700; TZ_ABBR=PDT
  SYS_LOCALE=en_US; SYS_LANG=en; LOCALE_CC=US
  PROXY_MODE="TUN 全局"; PAC_ON=0
  DNS_VERDICT="正常(Cloudflare)"; DNS_RESULT=104.18.1.1; DNS_SCOPE="本地/代理接管"
  CLAUDE_BASE=""; CLAUDE_VER=test
  IP_CHANGES=0; VM_HOST=物理机
  BR_OK=1; BR_TZ=America/Los_Angeles; BR_LANGS=en-US,en; BR_LOCALE=en-US
  BR_RTC=1.2.3.4; BR_WEBGL="Apple M1"; BR_FONTS="PingFang SC"
}

echo "① 完美环境 => 100 分且无问题"
base_signals; compute_score
check "满分" "$SCORE" 100
check "无问题" "$ISSUES" ""
check "20 项信号" "${#SIGNALS[@]}" 20

echo "② 权重表合计必须正好 100(防止加信号时算错总分)"
total=0; for r in "${SIGNALS[@]}"; do IFS='~' read -r _ _ w _ _ <<<"$r"; total=$((total+w)); done
check "权重合计" "$total" 100

echo "③ 国内直连(CN/API403/三路不一致/国内DNS/中文区域) => 高风险"
base_signals
COUNTRY=CN; COUNTRY2=CN; API_CODE=403; WEB_CODE=403; CONSISTENT=0
SYS_TZ=Asia/Shanghai; GFW_TZ=America/New_York; SYS_LOCALE=zh_CN; SYS_LANG=zh; LOCALE_CC=CN
DNS_SCOPE="国内公共DNS(114.114.114.114)"; HOSTING=1; PROXY_MODE=直连
compute_score
check "低于 50" "$([[ $SCORE -lt 50 ]] && echo yes)" yes
check "评级高风险" "$GRADE" 高风险
check "点名不支持地区" "$(echo "$ISSUES" | grep -c '不在 Anthropic 服务范围')" 1
check "点名 DNS 泄漏国内" "$(echo "$ISSUES" | grep -c 'DNS 查询泄漏到国内')" 1

echo "④ 典型代理用户(美国机房/时区没跟上/中文区域/DNS走国内) => 良好且时区可修"
base_signals
HOSTING=1; SYS_TZ=Asia/Shanghai; GFW_TZ=America/New_York
SYS_LOCALE=zh_CN; SYS_LANG=zh; LOCALE_CC=CN
DNS_SCOPE="国内公共DNS(223.5.5.5)"
compute_score
check "标记时区可修" "$FIXABLE_TZ" America/New_York
check "分数 70-84" "$([[ $SCORE -ge 70 && $SCORE -lt 85 ]] && echo yes)" yes
check "评级良好" "$GRADE" 良好

echo "⑤ 修好时区后应加满 5 分"
before=$SCORE; SYS_TZ=America/New_York; compute_score
check "分数 +5" "$SCORE" "$((before + 5))"
check "时区不再可修" "$FIXABLE_TZ" ""

echo "⑥ PAC 分流 + 多层代理 + 情报冲突 => 各自扣分并给建议"
base_signals
PAC_ON=1; PROXY_MODE="系统 HTTP 代理 + PAC 分流"; CF_IP=9.9.9.9; COUNTRY2=JP
compute_score
check "点名 PAC" "$(echo "$ISSUES" | grep -c 'PAC 自动分流')" 1
check "点名多层代理" "$(echo "$ISSUES" | grep -c '链路上还有一层代理')" 1
check "点名情报冲突" "$(echo "$ISSUES" | grep -c '情报库对该出口判定不一致')" 1

echo "⑦ DNS 被污染 => 扣满 6 分"
base_signals; compute_score; full=$SCORE
DNS_VERDICT="被污染(指向私有地址)"; DNS_RESULT=127.0.0.1; compute_score
check "扣 6 分" "$SCORE" "$((full - 6))"

echo "⑧ 已配中转时 API 直连不通只扣一半"
base_signals; API_CODE=000; CLAUDE_BASE="https://relay.example.com"; compute_score
check "提示中转可忽略" "$(echo "$FIXES" | grep -c '只用中转可忽略')" 1
base_signals; API_CODE=000; compute_score
check "无中转则明确报连不上" "$(echo "$ISSUES" | grep -c '连不上(超时/DNS 污染)')" 1

echo "⑨ 情报接口全挂(国家未知) => 不至于判死"
base_signals; COUNTRY=""; COUNTRY2=""; CF_LOC=""; CF_IP=""; HOSTING=-1; compute_score
check "仍有分" "$([[ $SCORE -gt 40 ]] && echo yes)" yes

echo "⑩ WebRTC 暴露了另一个出口 => 扣满 6 分并给建议"
base_signals; compute_score; full2=$SCORE
BR_RTC=8.8.8.8; compute_score
check "扣 6 分" "$SCORE" "$((full2 - 6))"
check "点名 UDP 绕过代理" "$(echo "$ISSUES" | grep -c 'UDP 绕过了代理')" 1

echo "⑪ 浏览器信号没采集到 => 给部分分而不是判零"
base_signals; BR_OK=0; compute_score
check "浏览器组拿到 9/15" "$(t=0; for r in "${SIGNALS[@]}"; do IFS='~' read -r g _ _ p _ <<<"$r"; [[ $g == 浏览器 ]] && t=$((t+p)); done; echo $t)" 9
check "不产生误报问题" "$(echo "$ISSUES" | grep -c 浏览器)" 0

echo "⑫ TUN 全局下 DNS 走隧道，不该按泄漏扣满分"
base_signals; DNS_SCOPE="国内公共DNS(223.5.5.5)"; PROXY_MODE="TUN 全局"; compute_score
tun_dns=$(for r in "${SIGNALS[@]}"; do IFS='~' read -r g l _ p _ <<<"$r"; [[ $l == "DNS 出口" ]] && echo $p; done)
check "TUN 下拿 2/4" "$tun_dns" 2
base_signals; DNS_SCOPE="国内公共DNS(223.5.5.5)"; PROXY_MODE="直连"; compute_score
plain_dns=$(for r in "${SIGNALS[@]}"; do IFS='~' read -r g l _ p _ <<<"$r"; [[ $l == "DNS 出口" ]] && echo $p; done)
check "非 TUN 下扣光" "$plain_dns" 0

echo ""
[[ $FAIL -eq 0 ]] && echo "全部通过" || { echo "有用例失败"; exit 1; }
