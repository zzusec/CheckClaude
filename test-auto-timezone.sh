#!/bin/bash
# auto-timezone.sh 网络波动状态机自测：不联网，不修改系统时区，不弹真实通知。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/checkclaude-network.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export AUTO_TZ_DIR="$TEST_DIR"
export AUTO_TZ_SELFTEST=1
source "$ROOT/auto-timezone.sh"

FAIL=0
NOTIFY_LOG="$TEST_DIR/notifications"
APPLY_LOG="$TEST_DIR/applied-timezones"
MOCK_CN=""; MOCK_INTL=""; MOCK_GFW=""; MOCK_GOOGLE=1; MOCK_TZ="America/Los_Angeles"
MOCK_CURRENT_TZ="America/Los_Angeles"

check() { # check <描述> <实际> <期望>
  if [[ "$2" == "$3" ]]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1: 实际=$2 期望=$3"
    FAIL=1
  fi
}

value() { awk -F= -v key="$2" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$1" 2>/dev/null; }
notification_count() { [[ -f "$NOTIFY_LOG" ]] && wc -l <"$NOTIFY_LOG" | tr -d ' ' || echo 0; }

ip_china() { [[ -n "$MOCK_CN" ]] && printf '%s|0.010|0.050|0.090|0.120|200\n' "$MOCK_CN"; }
ip_intl() { [[ -n "$MOCK_INTL" ]] && printf '%s|0.020|0.060|0.100|0.140|200\n' "$MOCK_INTL"; }
ip_gfw() { [[ -n "$MOCK_GFW" ]] && printf '%s|0.030|0.070|0.110|0.160|200\n' "$MOCK_GFW"; }
google_reachable() {
  if [[ "$MOCK_GOOGLE" == "1" ]]; then
    printf '%s\n' '0.040|0.080|0.120|0.180|204'; return 0
  fi
  printf '%s\n' '0.000|0.000|0.000|0.900|000'; return 1
}
ip_timezone() { [[ -n "$MOCK_TZ" ]] && printf '%s\n' "$MOCK_TZ"; }
current_timezone() { printf '%s\n' "$MOCK_CURRENT_TZ"; }
apply_timezone() {
  [[ "$1" == "$MOCK_CURRENT_TZ" ]] && return 0
  printf '%s\n' "$1" >>"$APPLY_LOG"
  MOCK_CURRENT_TZ="$1"
  return 0
}

notify() { printf '%s|%s\n' "$1" "$2" >>"$NOTIFY_LOG"; }

run_sample() {
  main >/dev/null 2>&1
  return $?
}

set_sample() {
  MOCK_CN="$1"; MOCK_INTL="$2"; MOCK_GFW="$3"
}

OLD_IP="1.2.3.4"
NEW_IP="5.6.7.8"

printf '%s\n' '① 首次有效结果立即建立基线'
printf '%s\n' 'none|0' >"$STATE"   # 模拟旧版本恰好停在获取失败状态
OLD_EPOCH=$(( $(date +%s) - 90000 ))
printf '%s\n' "$OLD_EPOCH|9|failure|?|0|9|0|9|0|9|0|9|0" >"$HISTORY"
set_sample "$OLD_IP" "$OLD_IP" "$OLD_IP"
run_sample || true
check "网络稳定" "$(value "$STATUS" network)" "ok"
check "记录出口 IP" "$(value "$STATUS" gfw)" "$OLD_IP"
check "建立通知基线" "$(cat "$STATE")" "$OLD_IP|1"
check "没有首次变化通知" "$(notification_count)" "0"
check "写入 HTTPS/TCP 历史字段" "$(awk -F'|' 'NR==1 {print NF}' "$HISTORY")" "29"
check "记录国内 TCP/TLS/TTFB/HTTP" "$(awk -F'|' 'NR==1 {print $14"|"$15"|"$16"|"$17}' "$HISTORY")" "0.010|0.050|0.090|200"
check "记录 Google HTTPS 指标" "$(awk -F'|' 'NR==1 {print $26"|"$27"|"$28"|"$29}' "$HISTORY")" "0.040|0.080|0.120|204"
check "裁掉 24 小时以前记录" "$(grep -c "^${OLD_EPOCH}|" "$HISTORY" || true)" "0"

printf '%s\n' '② 单次接口失败只标记复核，保留上次 IP'
set_sample "$OLD_IP" "" ""
run_sample || true
check "状态为复核中" "$(value "$STATUS" network)" "verifying"
check "失败计数为 1" "$(value "$STATUS" failure_count)" "1"
check "菜单快照保留原 IP" "$(value "$STATUS" gfw)" "$OLD_IP"
check "last_state 不写 none" "$(cat "$STATE")" "$OLD_IP|1"
check "不发送 IP 变化通知" "$(notification_count)" "0"

printf '%s\n' '③ 连续两次失败才确认网络波动'
run_sample || true
check "状态为波动中" "$(value "$STATUS" network)" "unstable"
check "失败计数为 2" "$(value "$STATUS" failure_count)" "2"
check "波动时仍保留原 IP" "$(value "$STATUS" gfw)" "$OLD_IP"
check "仍不发送 IP 变化通知" "$(notification_count)" "0"

printf '%s\n' '④ 恢复后连续两次有效结果才解除波动'
set_sample "$OLD_IP" "$OLD_IP" "$OLD_IP"
run_sample || true
check "第一次恢复仍在复核" "$(value "$STATUS" network)" "verifying"
check "恢复确认 1/2" "$(value "$STATUS" confirm_count)" "1"
check "复核时沿用原 IP" "$(value "$STATUS" gfw)" "$OLD_IP"
run_sample || true
check "第二次恢复为稳定" "$(value "$STATUS" network)" "ok"
check "确认计数清零" "$(value "$STATUS" confirm_count)" "0"
check "恢复过程没有虚假通知" "$(notification_count)" "0"

printf '%s\n' '⑤ Google 单路失败能独立记录，不误判三路 IP 波动'
MOCK_GOOGLE=0
run_sample || true
check "Google 不可达但三路状态仍稳定" "$(value "$STATUS" network)" "ok"
check "Google 成功字段为 0" "$(awk -F'|' 'END {print $13}' "$HISTORY")" "0"
check "其余三路均成功" "$(awk -F'|' 'END {print $7 $9 $11}' "$HISTORY")" "111"
MOCK_GOOGLE=1

printf '%s\n' '⑥ 新 IP 连续出现两次后才正式提交并通知'
set_sample "$NEW_IP" "$NEW_IP" "$NEW_IP"
run_sample || true
check "第一次新 IP 仍在复核" "$(value "$STATUS" network)" "verifying"
check "快照仍是旧 IP" "$(value "$STATUS" gfw)" "$OLD_IP"
check "基线仍是旧 IP" "$(cat "$STATE")" "$OLD_IP|1"
check "第一次不通知" "$(notification_count)" "0"
run_sample || true
check "第二次新 IP 提交" "$(value "$STATUS" gfw)" "$NEW_IP"
check "网络恢复稳定" "$(value "$STATUS" network)" "ok"
check "基线更新为新 IP" "$(cat "$STATE")" "$NEW_IP|1"
check "只发送一次变化通知" "$(notification_count)" "1"
check "通知不包含 none" "$(grep -c 'none' "$NOTIFY_LOG" 2>/dev/null || true)" "0"

printf '%s\n' '⑦ 三路完整但一致性变化也需要连续确认'
set_sample "9.9.9.9" "$NEW_IP" "$NEW_IP"
run_sample || true
check "第一次不一致仍在复核" "$(value "$STATUS" network)" "verifying"
check "仍显示上次一致结果" "$(value "$STATUS" consistent)" "1"
run_sample || true
check "第二次才提交不一致" "$(value "$STATUS" consistent)" "0"
check "不一致提交后网络探测本身稳定" "$(value "$STATUS" network)" "ok"
check "没有额外 IP 变化通知" "$(grep -c '^出口 IP 变化|' "$NOTIFY_LOG" 2>/dev/null || true)" "1"

printf '%s\n' '⑧ 已有检测锁时跳过，不覆盖状态'
BEFORE=$(cat "$STATUS")
HISTORY_BEFORE=$(wc -l <"$HISTORY" | tr -d ' ')
mkdir "$LOCK_DIR"
set_sample "$OLD_IP" "$OLD_IP" "$OLD_IP"
run_sample || true
rmdir "$LOCK_DIR"
check "锁冲突不改快照" "$(cat "$STATUS")" "$BEFORE"
check "日志记录跳过" "$(grep -c '已有出口检测正在运行，本次跳过' "$LOG" || true)" "1"
check "锁冲突不写历史" "$(wc -l <"$HISTORY" | tr -d ' ')" "$HISTORY_BEFORE"

printf '%s\n' '⑨ 分路历史和状态写入均不残留临时文件'
check "共记录 10 次真实检测" "$(wc -l <"$HISTORY" | tr -d ' ')" "10"
check "记录两次接口失败" "$(awk -F'|' '$3 == "failure" {n++} END {print n+0}' "$HISTORY")" "2"
check "只标记一次已确认换 IP" "$(awk -F'|' '$5 == 1 {n++} END {print n+0}' "$HISTORY")" "1"
TMP_COUNT=$(find "$TEST_DIR" -maxdepth 1 -name '*.tmp.*' | wc -l | tr -d ' ')
check "没有临时文件残留" "$TMP_COUNT" "0"

printf '%s\n' '⑩ 同一 IP 的时区变化连续两次才接受'
STABLE_TIMEZONE="America/Los_Angeles"
SNAP_GFWTZ="America/Los_Angeles"
PENDING_TIMEZONE=""; PENDING_TZ_COUNT=0; TIMEZONE_DETAIL=""
confirm_timezone_candidate "$NEW_IP" "$NEW_IP" "America/New_York" || true
check "第一次时区跳变沿用旧值" "$CONFIRMED_TIMEZONE" "America/Los_Angeles"
check "记录时区候选 1/2" "$PENDING_TZ_COUNT" "1"
check "给出时区复核提示" "$(echo "$TIMEZONE_DETAIL" | grep -c '复核中')" "1"
confirm_timezone_candidate "$NEW_IP" "$NEW_IP" "America/New_York" || true
check "第二次相同结果才接受" "$CONFIRMED_TIMEZONE" "America/New_York"
check "更新稳定时区" "$STABLE_TIMEZONE" "America/New_York"
check "时区候选计数清零" "$PENDING_TZ_COUNT" "0"


printf '%s\n' '⑪ 辅助探针失败时，谷歌侧出口仍独立确认并修正时区'
TZ_ONLY_IP="9.8.7.6"
set_sample "" "" "$TZ_ONLY_IP"
MOCK_TZ="America/New_York"
MOCK_CURRENT_TZ="America/Los_Angeles"
run_sample || true
check "第一次权威出口变化只复核" "$(value "$STATUS" timezone_ip)" "$NEW_IP"
check "记录权威出口确认 1/2" "$(value "$PROBE_STATE" pending_timezone_ip_count)" "1"
check "第一次不修改系统时区" "$MOCK_CURRENT_TZ" "America/Los_Angeles"
run_sample || true
check "第二次独立确认权威出口" "$(value "$STATUS" timezone_ip)" "$TZ_ONLY_IP"
check "辅助探针波动时仍更新出口时区" "$(value "$STATUS" gfwtz)" "America/New_York"
check "系统时区已自动修正" "$MOCK_CURRENT_TZ" "America/New_York"
check "快照标记时区一致" "$(value "$STATUS" timezone_synced)" "1"

printf '%s\n' '⑫ 系统时区被外部改动后，下一轮自动纠偏'
MOCK_CURRENT_TZ="Asia/Shanghai"
run_sample || true
check "相同权威出口自动纠偏" "$MOCK_CURRENT_TZ" "America/New_York"
check "纠偏后快照仍一致" "$(value "$STATUS" timezone_synced)" "1"
check "时区修正记录两次真实变更" "$(wc -l <"$APPLY_LOG" | tr -d ' ')" "2"

if [[ $FAIL -eq 0 ]]; then
  echo
  echo "全部通过"
else
  echo
  echo "存在失败"
fi
exit $FAIL
