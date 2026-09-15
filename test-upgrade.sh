#!/bin/bash
# upgrade.sh 更新检查与 LaunchAgent 行为自测：不联网、不安装 App。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/checkclaude-upgrade.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export AUTO_TZ_DIR="$TEST_DIR"
export UPGRADE_SELFTEST=1
source "$ROOT/upgrade.sh"

FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; else echo "  ✗ $1: 实际=$2 期望=$3"; FAIL=1; fi
}
value() { awk -F= -v key="$2" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$1"; }
current_version() { printf '%s\n' "${MOCK_CURRENT:-4.4}"; }
latest_release() {
  [[ "${MOCK_FAIL:-0}" == "1" ]] && return 1
  printf '%s\t%s\n' "${MOCK_LATEST:-4.4}" \
    "https://github.com/zzusec/CheckClaude/releases/download/v${MOCK_LATEST:-4.4}/CheckClaude.dmg"
}

printf '%s\n' '① 已是最新版时写入本次成功状态'
MOCK_CURRENT=4.4; MOCK_LATEST=4.4; MOCK_FAIL=0
do_check >/dev/null
check "检查成功" "$(value "$USTATUS" checkok)" 1
check "没有更新" "$(value "$USTATUS" hasupdate)" 0
check "记录本次时间戳" "$([[ $(value "$USTATUS" checkedat) =~ ^[0-9]+$ ]] && echo yes)" yes

printf '%s\n' '② 有新版时正确标记'
MOCK_LATEST=4.5
do_check >/dev/null
check "发现更新" "$(value "$USTATUS" hasupdate)" 1
check "记录最新版" "$(value "$USTATUS" latest)" 4.5

printf '%s\n' '③ 本次网络失败必须返回失败，不能拿旧缓存冒充成功'
MOCK_FAIL=1
do_check >/dev/null 2>&1; rc=$?
check "失败退出码" "$rc" 2
check "明确标记失败" "$(value "$USTATUS" checkok)" 0
check "保留旧版本信息" "$(value "$USTATUS" latest)/$(value "$USTATUS" hasupdate)" "4.5/1"
check "提供可恢复错误文案" "$(value "$USTATUS" error)" "无法连接 GitHub，请检查网络后重试"

printf '%s\n' '④ 登录启动但用户退出后不再被 KeepAlive 拉起'
check "保留 RunAtLoad" "$(plutil -extract RunAtLoad raw "$ROOT/menubar/com.example.checkclaude.plist")" true
if plutil -extract KeepAlive raw "$ROOT/menubar/com.example.checkclaude.plist" >/dev/null 2>&1; then keepalive=yes; else keepalive=no; fi
check "移除 KeepAlive" "$keepalive" no
check "构建版本为 4.4" "$(sed -n 's/.*CFBundleShortVersionString.*<string>\([^<]*\)<.*/\1/p' "$ROOT/menubar/build.sh")" 4.4

printf '\n'
[[ $FAIL -eq 0 ]] && echo "全部通过" || { echo "存在失败"; exit 1; }
