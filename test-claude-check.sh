#!/bin/bash
# claude-check.sh 评分逻辑自测: 不联网，直接喂信号给 compute_score 断言分数与建议。
set -uo pipefail
TEST_DATA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/checkclaude-score.XXXXXX")
export AUTO_TZ_DIR="$TEST_DATA_DIR"
export CC_SELFTEST=1
source "$(dirname "$0")/claude-check.sh"
trap 'rm -rf "$TMP" "$TEST_DATA_DIR"' EXIT

FAIL=0
check() { # check <描述> <实际> <期望>
  if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; else echo "  ✗ $1: 实际=$2 期望=$3"; FAIL=1; fi
}

# 评分测试必须完全离线；WebRTC 泄漏归属查询固定返回 US。
ip_country_code() { printf '%s\n' US; }

# 一个"完美环境"的基线，各用例只覆盖自己关心的字段
base_signals() {
  COUNTRY=US; COUNTRY2=US; COUNTRY3=US; COUNTRY4=US; COUNTRY_NAME=美国; CITY=LA; ISP=Comcast; ASN=AS7922; LATITUDE=34.0522; LONGITUDE=-118.2437
  INTEL_SOURCES="ip-api:US,ipinfo:US,ipwho:US,ip.sb:US"; INTEL_COUNT=4
  HOSTING=0; PROXY=0
  API_CODE=401; WEB_CODE=200; API_REGION_BLOCK=0
  CF_COLO=LAX; CF_LOC=US; CF_IP=1.2.3.4; CF_WARP=off; PROBE_IP=1.2.3.4; CN_IP=1.2.3.4; INTL_IP=1.2.3.4
  CONSISTENT=1; SYS_TZ=America/Los_Angeles; GFW_TZ=America/Los_Angeles
  TZ_SELF_CONSISTENT=1; TZ_OFFSET=-0700; TZ_ABBR=PDT
  SYS_LOCALE=en_US; SYS_LANG=en; LOCALE_CC=US
  PROXY_MODE="TUN 全局"; PAC_ON=0
  DNS_VERDICT="正常(Cloudflare)"; DNS_RESULT=104.18.1.1; DNS_SCOPE="本地/代理接管"; DNS_SERVERS="1.1.1.1 8.8.8.8 "
  CLAUDE_BASE=""; CLAUDE_VER=test
  IP_CHANGES=0; VM_HOST=物理机
  BR_OK=1; BR_TZ=America/Los_Angeles; BR_LANGS=en-US,en; BR_LOCALE=en-US
  BR_RTC=1.2.3.4; BR_RTC_STATUS=ok; BR_RTC_SUPPORTED=1; BR_RTC_CANDIDATES=2; BR_RTC_PUBLIC_COUNT=1
  BR_RTC_MS=350; BR_RTC_ERROR=""; BR_WEBGL="Apple M1"; BR_FONTS="PingFang SC"; BR_LOCALE=en-US
  SITE_CODE=200; IPV6=""; IPV6_CC=""; SYS_LANGS=en-US
  OS_VER="macOS 26.6"; BR_SOURCE=browser; BR_UA=Chrome; BR_UA_JS=Chrome
  BR_CH_UA=Chromium; BR_CH_PLAT=macOS; BR_ACCEPT=en-US; BR_UAD_PLAT=macOS; BR_UAD_BRANDS=Chromium
  BR_SF_SITE=same-origin; BR_SF_MODE=cors; BR_SF_DEST=empty
}

echo "① 完美环境 => 100 分且无问题"
base_signals; compute_score
check "满分" "$SCORE" 100
check "无问题" "$ISSUES" ""
check "26 项信号" "${#SIGNALS[@]}" 26
check "满分环境风险档位" "$RISK_LEVEL/$SAFE_USE" "安全/1"

echo "② 权重表合计必须正好 100(防止加信号时算错总分)"
total=0; for r in "${SIGNALS[@]}"; do IFS='~' read -r _ _ w _ _ <<<"$r"; total=$((total+w)); done
check "权重合计" "$total" 100

echo "③ 国内直连(CN/API403/三路不一致/国内DNS/中文区域) => 高风险"
base_signals
COUNTRY=CN; COUNTRY2=CN; API_CODE=403; WEB_CODE=403; CONSISTENT=0
SYS_TZ=Asia/Shanghai; GFW_TZ=America/New_York; SYS_LOCALE=zh_CN; SYS_LANG=zh; LOCALE_CC=CN
DNS_SCOPE="国内公共DNS(114.114.114.114)"; HOSTING=1; PROXY_MODE=直连
compute_score
check "不服务地区给出具体说明" "$(echo "$VERDICT" | grep -c "中国大陆：Anthropic 未在此开放服务")" 1
check "评级高风险" "$GRADE" 高风险
check "点名不支持地区" "$(echo "$ISSUES" | grep -c '不在 Anthropic 服务范围')" 1
check "点名 DNS 泄漏国内" "$(echo "$ISSUES" | grep -c 'DNS 查询泄漏到国内')" 1

echo "④ 典型代理用户(美国机房/时区没跟上/中文区域/DNS走国内) => 良好且时区可修"
base_signals
HOSTING=1; SYS_TZ=Asia/Shanghai; GFW_TZ=America/New_York
SYS_LOCALE=zh_CN; SYS_LANG=zh; LOCALE_CC=CN
DNS_SCOPE="国内公共DNS(223.5.5.5)"; IPV6="2408:8207::1"; IPV6_CC=CN
compute_score
check "标记时区可修" "$FIXABLE_TZ" America/New_York
check "分数 70-84" "$([[ $SCORE -ge 70 && $SCORE -lt 85 ]] && echo yes)" yes
check "评级为有风险(不能叫良好)" "$GRADE" 有风险

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
check "点名情报冲突" "$(echo "$ISSUES" | grep -c 'IP 情报库对同一出口.*国家码判定不一致')" 1

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
base_signals; COUNTRY=""; COUNTRY2=""; COUNTRY3=""; COUNTRY4=""; INTEL_SOURCES=""; INTEL_COUNT=0; CF_LOC=""; CF_IP=""; HOSTING=-1; compute_score
check "仍有分" "$([[ $SCORE -gt 40 ]] && echo yes)" yes

echo "⑩ WebRTC 暴露了另一个出口 => 扣满 6 分并给建议"
base_signals; compute_score; full2=$SCORE
BR_RTC=8.8.8.8; compute_score
check "扣 6 分" "$SCORE" "$((full2 - 6))"
check "点名 UDP 绕过代理" "$(echo "$ISSUES" | grep -c 'UDP 绕过了代理')" 1

echo "⑪ 浏览器信号没采集到 => 给部分分而不是判零"
base_signals; BR_OK=0; compute_score
check "浏览器组拿到 11/17" "$(t=0; for r in "${SIGNALS[@]}"; do IFS='~' read -r g _ _ p _ <<<"$r"; [[ $g == 浏览器 ]] && t=$((t+p)); done; echo $t)" 11
check "不产生误报问题" "$(echo "$ISSUES" | grep -c 浏览器)" 0

echo "⑫ TUN 全局下 DNS 走隧道，不该按泄漏扣满分"
base_signals; DNS_SCOPE="国内公共DNS(223.5.5.5)"; PROXY_MODE="TUN 全局"; compute_score
tun_dns=$(for r in "${SIGNALS[@]}"; do IFS='~' read -r g l _ p _ <<<"$r"; [[ $l == "DNS 出口" ]] && echo $p; done)
check "TUN 下拿 2/4" "$tun_dns" 2
base_signals; DNS_SCOPE="国内公共DNS(223.5.5.5)"; PROXY_MODE="直连"; compute_score
plain_dns=$(for r in "${SIGNALS[@]}"; do IFS='~' read -r g l _ p _ <<<"$r"; [[ $l == "DNS 出口" ]] && echo $p; done)
check "非 TUN 下扣光" "$plain_dns" 0

echo "⑬ IPv6 出口与 IPv4 不同地区 => 扣满 3 分并点名"
base_signals; compute_score; f6=$SCORE
IPV6="2408:8207::1"; IPV6_CC=CN; compute_score
check "扣 3 分" "$SCORE" "$((f6 - 3))"
check "点名 IPv6 暴露" "$(echo "$ISSUES" | grep -c '代理没接管 IPv6')" 1
base_signals; IPV6="2606:4700::1"; IPV6_CC=US; compute_score
check "同地区不扣分" "$SCORE" "$f6"

echo "⑭ 三路不一致要硬降级，不能因为分数高就叫「良好」"
base_signals; CONSISTENT=0; compute_score
check "评级为风险" "$GRADE" 风险
check "点名分流" "$(echo "$VERDICT" | grep -c "出口 IP 分流")" 1
check "三路不一致硬降级不受分数影响" "$([[ $SCORE -ge 70 ]] && echo yes)" yes
check "三路不一致显示高风险" "$RISK_LEVEL/$SAFE_USE" "高风险/0"

echo "⑮ 85-89 分不算可用(绿档门槛是 90)"
base_signals; compute_score
# 造一个 87 分左右的环境: 时区不匹配扣 5 分 + 语言变体扣 1 分
SYS_TZ=Asia/Shanghai; GFW_TZ=America/New_York; SYS_LOCALE=zh_CN; SYS_LANG=zh; LOCALE_CC=CN; HOSTING=1
compute_score
check "85-89 分不叫优秀" "$([[ $SCORE -ge 85 && $SCORE -lt 90 && $GRADE != 优秀 ]] && echo yes || echo "$SCORE/$GRADE")" yes
check "关键时区冲突即使 85-89 分仍是高风险" "$RISK_LEVEL/$SAFE_USE" "高风险/0"
SCORE=87; GRADE="有风险"; COUNTRY=US; classify_risk ""
check "无关键项失败的 85-89 分显示低风险" "$RISK_LEVEL/$SAFE_USE" "低风险/0"

echo "⑯ WebRTC 明确完成且无公网候选 => 满分"
base_signals; BR_RTC=""; BR_RTC_STATUS=none; BR_RTC_PUBLIC_COUNT=0; compute_score
check "无公网候选不扣分" "$SCORE" 100
check "显示明确完成" "$(for r in "${SIGNALS[@]}"; do IFS='~' read -r _ l _ _ v <<<"$r"; [[ $l == 'WebRTC 出口' ]] && echo "$v"; done)" "检测完成，无公网候选"

echo "⑰ WebRTC 超时 => 中性扣 2 分但不按确认泄漏一票否决"
base_signals; BR_RTC=""; BR_RTC_STATUS=timeout; BR_RTC_PUBLIC_COUNT=0; compute_score
check "超时按中性分" "$SCORE" 98
check "超时不是确认泄漏" "$(echo "$VERDICT" | grep -c '关键项未达标.*WebRTC' || true)" 0

echo "⑱ 四家 IP 情报国家码一致 => 3 分全拿"
base_signals; compute_score
intel_points=$(for r in "${SIGNALS[@]}"; do IFS='~' read -r _ l _ p v <<<"$r"; [[ $l == '多源情报一致' ]] && echo "$p|$v"; done)
check "情报一致得满分" "$intel_points" "3|4/4 · US"

echo "⑲ 国家码大小写规范化，不产生假冲突"
base_signals; COUNTRY2=us; COUNTRY3=Us; COUNTRY4=uS; compute_score
intel_points=$(for r in "${SIGNALS[@]}"; do IFS='~' read -r _ l _ p v <<<"$r"; [[ $l == '多源情报一致' ]] && echo "$p|$v"; done)
check "大小写统一后仍一致" "$intel_points" "3|4/4 · US"

echo "⑳ HTTP UA 与 JavaScript UA 冲突 => Client Hints 扣满"
base_signals; BR_UA_JS=Safari; compute_score
ch_points=$(for r in "${SIGNALS[@]}"; do IFS='~' read -r _ l _ p _ <<<"$r"; [[ $l == 'Client Hints' ]] && echo "$p"; done)
check "UA 冲突得 0 分" "$ch_points" 0
check "UA 冲突给出问题" "$(echo "$ISSUES" | grep -c 'User-Agent 与 JavaScript' || true)" 1

echo "㉑ HTTP 与 JavaScript 首选语言冲突 => 语言首标扣满"
base_signals; BR_ACCEPT=zh-CN; BR_LANGS=en-US,en; compute_score
lang_points=$(for r in "${SIGNALS[@]}"; do IFS='~' read -r _ l _ p _ <<<"$r"; [[ $l == 'HTTP 语言首标' ]] && echo "$p"; done)
check "语言头冲突得 0 分" "$lang_points" 0
check "语言头冲突给出问题" "$(echo "$ISSUES" | grep -c 'Accept-Language 与 navigator.languages' || true)" 1

echo "㉒ IP 情报响应解析 => 四家来源统一成 ISO 国家码"
cat >"$TMP/ipapi" <<'JSON'
{"status":"success","country":"United States","countryCode":"us","city":"Los Angeles","isp":"ISP A","org":"Org A","as":"AS1","hosting":false,"proxy":false}
JSON
cat >"$TMP/ipinfo" <<'JSON'
{"country":"US","org":"Org B"}
JSON
cat >"$TMP/ipwho" <<'JSON'
{"success":true,"country_code":"Us","latitude":34.0522,"longitude":-118.2437,"connection":{"org":"Org C"}}
JSON
cat >"$TMP/ipsb" <<'JSON'
{"country_code":"uS","organization":"Org D"}
JSON
: >"$TMP/cftrace"; echo 401 >"$TMP/apicode"; echo 200 >"$TMP/webcode"; echo 200 >"$TMP/sitecode"; : >"$TMP/ipv6"; : >"$TMP/apibody"
parse_net
check "解析四家来源" "$INTEL_SOURCES" "ip-api:US,ipinfo:US,ipwho:US,ip.sb:US"
check "有效来源数" "$INTEL_COUNT" 4
check "主国家码规范化" "$COUNTRY" US
check "解析经纬度" "$LATITUDE,$LONGITUDE" "34.0522,-118.2437"

echo "㉓ 出口稳定性只统计已确认变化，不统计失败/恢复"
now=$(date +%s); old=$((now - 90000))
cat >"$NETWORK_HISTORY" <<EOF
${old}|4|stable|1.1.1.1|1|1|1|1|1|1|1|1|1
$((now - 120))|50|failure|1.1.1.1|0|10|0|10|0|10|0|10|0
$((now - 60))|5|verifying|1.1.1.1|0|1|1|1|1|1|1|1|1
${now}|4|stable|2.2.2.2|1|1|1|1|1|1|1|1|1
EOF
parse_stability
check "24h 仅统计一次确认变化" "$IP_CHANGES" 1

echo "㉔ 总评分单次探测失败保留上次有效分数，连续两次才发布"
rm -f "$CSTATUS" "$CCANDIDATE" "$CPROBE_STATE"
base_signals; compute_score; build_gains; publish_cstatus
check "先写入健康基线" "$(status_value "$CSTATUS" score)" 100
base_signals; API_CODE=000; WEB_CODE=000; compute_score; build_gains
candidate_score=$SCORE
publish_cstatus || true
check "第一次失败仍显示旧分数" "$(status_value "$CSTATUS" score)" 100
check "第一次标记复核中" "$(status_value "$CPROBE_STATE" state)" verifying
check "候选分数单独保存" "$(status_value "$CCANDIDATE" score)" "$candidate_score"
publish_cstatus || true
check "第二次失败才发布低分" "$(status_value "$CSTATUS" score)" "$candidate_score"
check "第二次标记波动" "$(status_value "$CPROBE_STATE" state)" unstable
base_signals; compute_score; build_gains; publish_cstatus
check "恢复后立即发布健康分数" "$(status_value "$CSTATUS" score)" 100
check "恢复后清零状态" "$(status_value "$CPROBE_STATE" state)/$(status_value "$CPROBE_STATE" failure_count)" "ok/0"
check "候选文件已清理" "$([[ -e "$CCANDIDATE" ]] && echo yes || echo no)" no

echo "㉕ 已确认的关键风险即使伴随超时也必须立即发布"
base_signals; compute_score; build_gains; publish_cstatus
base_signals; COUNTRY=CN; COUNTRY2=CN; COUNTRY3=CN; COUNTRY4=CN; API_CODE=000; compute_score; build_gains
confirmed_score=$SCORE
publish_cstatus || true
check "不被旧高分掩盖" "$(status_value "$CSTATUS" score)" "$confirmed_score"
check "已确认风险不进入复核" "$(status_value "$CPROBE_STATE" state)" ok

echo "㉖ 完整报告状态包含 DNS、Cloudflare、IPv6 和三端连通证据"
base_signals; IPV6="2001:db8::1"; IPV6_CC=US; compute_score; build_gains; write_cstatus
check "写入 DNS 服务器" "$(status_value "$CSTATUS" dnsservers)" "1.1.1.1 8.8.8.8 "
check "写入 DNS 应答" "$(status_value "$CSTATUS" dnsanswer)" "104.18.1.1"
check "写入 Cloudflare 来源" "$(status_value "$CSTATUS" cfip)/$(status_value "$CSTATUS" cfloc)/$(status_value "$CSTATUS" cfwarp)" "1.2.3.4/US/off"
check "写入出口坐标" "$(status_value "$CSTATUS" latitude),$(status_value "$CSTATUS" longitude)" "34.0522,-118.2437"
check "写入 IPv6 证据" "$(status_value "$CSTATUS" ipv6)/$(status_value "$CSTATUS" ipv6country)" "2001:db8::1/US"
check "写入网站连通状态" "$(status_value "$CSTATUS" api)/$(status_value "$CSTATUS" web)/$(status_value "$CSTATUS" site)" "401/200/200"
check "写入风险档位和使用结论" "$(status_value "$CSTATUS" risklevel)/$(status_value "$CSTATUS" safeuse)" "安全/1"

echo "㉗ 无法自动完成的代理/DNS 项仍展示可点击修复指引"
base_signals; PROXY_MODE="直连"; DNS_SCOPE="境外/自定义(8.8.8.8)"; compute_score; AUTO_FIXED_ITEMS=""
guide=$(show_manual_guide 0 2>/dev/null)
check "保留代理形态手动指引" "$(echo "$guide" | grep -c '代理形态' || true)" 1
check "保留 DNS 出口手动指引" "$(echo "$guide" | grep -c 'DNS 出口' || true)" 1

echo ""
[[ $FAIL -eq 0 ]] && echo "全部通过" || { echo "有用例失败"; exit 1; }
