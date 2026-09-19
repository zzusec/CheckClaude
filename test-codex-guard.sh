#!/bin/bash
# codex-guard 自检: state 校验 + 反代采集/注入 + config.toml 接入与还原
# 全程本机假上游，不碰真实 codex 配置，也不访问外网
set -uo pipefail
set +m          # 后台假上游被 trap 杀掉时不打印 Terminated 噪音
ROOT="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then echo "  ✅ $1"; PASS=$((PASS+1))
    else echo "  ❌ $1: 期望 [$3] 实际 [$2]"; FAIL=$((FAIL+1)); fi
}

GUARD="$ROOT/menubar/codex-guard"
# 总是重编，避免拿旧二进制测新代码(排查过一次，白折腾半天)
swiftc "$ROOT/menubar/CodexGuard.swift" -o "$GUARD" -framework Network -O || exit 1

TMP=$(mktemp -d)
UP_PID=""; GUARD_PID=""
cleanup() { [ -n "$UP_PID" ] && kill "$UP_PID" 2>/dev/null; [ -n "$GUARD_PID" ] && kill "$GUARD_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

UP_PORT=18790
GUARD_PORT=18788

printf '%s\n' '① 假上游 + 反代链路'
python3 - "$TMP" "$UP_PORT" <<'PY' &
import base64, os, struct, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

tmp, port = sys.argv[1], int(sys.argv[2])
# 10 块合格 state: 0x80 + 8 字节签发时间 + 208 字节载荷 = 217 字节 → base64url 292 字符
def make(issued):
    raw = bytes([0x80]) + struct.pack('>Q', int(issued)) + os.urandom(208)
    return base64.urlsafe_b64encode(raw).decode()

fresh = make(time.time())
stale = make(time.time() - 7200)          # 早就过期，反代应当拒绝缓存
open(tmp + '/state.txt', 'w').write(fresh)

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length') or 0))
        body = b'data: {"type":"response.completed"}\n\ndata: [DONE]\n\n'
        self.send_response(200)
        self.send_header('x-codex-turn-state', stale if self.path.endswith('/expired') else fresh)
        self.send_header('x-echo-injected', self.headers.get('x-codex-turn-state') or '-')
        self.send_header('content-type', 'text/event-stream')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
UP_PID=$!
wait_port() {   # 端口没就绪就往下跑，会连到上一轮的残留进程，测出假结果
    for _ in $(seq 50); do nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1 && return 0; sleep 0.1; done
    echo "  ❌ 端口 $1 未就绪"; exit 1
}
wait_port "$UP_PORT"

AUTO_TZ_DIR="$TMP" CODEX_GUARD_PORT="$GUARD_PORT" CODEX_GUARD_UPSTREAM="http://127.0.0.1:$UP_PORT" "$GUARD" &
GUARD_PID=$!
wait_port "$GUARD_PORT"

post() { curl -s -m 10 -D "$TMP/h$1" -o /dev/null -X POST "http://127.0.0.1:$GUARD_PORT$2" -d '{}'; }
hdr()  { tr -d '\r' <"$TMP/h$1" | grep -i "^$2:" | head -1 | cut -d' ' -f2-; }
val()  { grep "^$1=" "$TMP/codex_guard_status" 2>/dev/null | cut -d= -f2-; }

post 1 /codex/responses/expired
sleep 0.5
check "过期 state 不进缓存" "$(val state)" "waiting"
check "首次请求不注入" "$(hdr 1 x-echo-injected)" "-"

post 2 /codex/responses
sleep 0.5
check "合格 state 被采集" "$(val state)" "ready"
check "块数记为 10" "$(val blocks)" "10"

post 3 /codex/responses
sleep 0.5
check "后续请求注入缓存值" "$(hdr 3 x-echo-injected)" "$(cat "$TMP/state.txt")"
check "注入计数" "$(val injected)" "1"

# 用户关掉开关后应立刻停止注入
touch "$TMP/codex_guard_off"
post 4 /codex/responses
check "开关关闭后不注入" "$(hdr 4 x-echo-injected)" "-"
rm -f "$TMP/codex_guard_off"

printf '%s\n' '② config.toml 接入与还原'
export CODEX_HOME="$TMP/codexhome"
mkdir -p "$CODEX_HOME"
ORIG="$CODEX_HOME/config.toml"
printf 'model = "gpt-5.2"\nchatgpt_base_url = "https://chatgpt.com/backend-api/"\n\n[tui]\nnotifications = true\n' >"$ORIG"
cp "$ORIG" "$TMP/orig.toml"

AUTO_TZ_DIR="$TMP" CODEX_GUARD_PORT="$GUARD_PORT" source "$ROOT/codex-guard.sh" --status >/dev/null
link_config
check "接入后 TOML 仍可解析" "$(python3 -c "
import tomllib,sys
d=tomllib.load(open('$ORIG','rb'))
print(d.get('chatgpt_base_url','')==('http://127.0.0.1:$GUARD_PORT/backend-api/') and d['tui']['notifications'])
")" "True"
unlink_config
check "断开后还原成原文件" "$(diff -q "$TMP/orig.toml" "$ORIG" >/dev/null && echo same)" "same"

printf '%s\n' '③ 非官方链路不接入'
printf 'model_provider = "wxglm"\n' >"$ORIG"
check "自定义 provider 被识别" "$(provider_mode)" "custom:wxglm"

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
