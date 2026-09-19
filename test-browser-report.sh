#!/bin/bash
# 浏览器完整报告页静态/编译自测：不联网、不启动 App、不修改用户数据。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/checkclaude-report.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
FAIL=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1: 实际=$2 期望=$3"
    FAIL=1
  fi
}

# 去掉真实 App 的顶层 run loop，和一个只输出 BrowserBridge.page 的 @main 测试入口一起编译。
sed '/^let app = NSApplication.shared$/,$d' "$ROOT/menubar/StatusApp.swift" >"$TMP_DIR/StatusApp.swift"
cat >"$TMP_DIR/Dump.swift" <<'SWIFT'
import Foundation
@main
struct Dump {
    static func main() { print(BrowserBridge.page(token: "selftesttoken")) }
}
SWIFT
swiftc "$TMP_DIR/StatusApp.swift" "$TMP_DIR/Dump.swift" -o "$TMP_DIR/dump" -framework Cocoa -framework WebKit
"$TMP_DIR/dump" >"$TMP_DIR/report.html"

# 抽出内联脚本，放进未调用函数里让系统 JavaScriptCore 只做语法解析。
sed -n '/<script>/,/<\/script>/p' "$TMP_DIR/report.html" \
  | sed '1s/.*<script>//; $s#</script>.*##' >"$TMP_DIR/report.js"
{
  echo 'function validateReportScript(){'
  cat "$TMP_DIR/report.js"
  echo '}'
} >"$TMP_DIR/report-wrapped.js"
/usr/bin/osascript -l JavaScript "$TMP_DIR/report-wrapped.js" >/dev/null

# 用真实 NWListener/URLSession 跑一遍 page -> POST signals -> publish -> GET report -> close。
cat >"$TMP_DIR/BridgeTest.swift" <<'SWIFT'
import Foundation

final class BridgeIntegration {
    private var bridge: BrowserBridge?
    private var baseURL: URL?
    private var finished = false
    private let output: String

    init(output: String) { self.output = output }

    func start() {
        bridge = BrowserBridge(outPath: output, collected: { [weak self] ok in
            guard let self else { return }
            guard ok else { self.fail("collection callback failed"); return }
            self.bridge?.publishReport([
                "ready": true, "version": "selftest",
                "network": ["gfw": "1.2.3.4"],
                "claude": ["score": "100"],
                "browser": ["tz": "America/Los_Angeles"],
                "probe": [:], "quality": ["samples": 1],
            ])
        }, cleanedUp: { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: self.output),
                  let text = try? String(contentsOfFile: self.output, encoding: .utf8),
                  text.contains("tz=America/Los_Angeles") else {
                self.fail("browser signal file missing"); return
            }
            self.succeed()
        }, ready: { [weak self] url in
            self?.baseURL = url
            self?.getPage(url)
        })
        bridge?.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.fail("integration timeout") }
    }

    private func endpoint(_ path: String) -> URL {
        var components = URLComponents(url: baseURL!, resolvingAgainstBaseURL: false)!
        components.path = path
        return components.url!
    }

    private func getPage(_ url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self, error == nil, let data, let html = String(data: data, encoding: .utf8),
                  html.contains("Claude 完整环境体检"), (response as? HTTPURLResponse)?.statusCode == 200 else {
                self?.fail("GET page failed"); return
            }
            var request = URLRequest(url: self.endpoint("/r"))
            request.httpMethod = "POST"
            request.httpBody = Data("tz=America/Los_Angeles\nlanguages=en-US,en\nrtc_status=none".utf8)
            URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                guard let self, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self?.fail("POST signals failed"); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.getReport() }
            }.resume()
        }.resume()
    }

    private func getReport() {
        URLSession.shared.dataTask(with: endpoint("/report")) { [weak self] data, response, error in
            guard let self, error == nil, let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["version"] as? String == "selftest" else {
                self?.fail("GET report failed"); return
            }
            var request = URLRequest(url: self.endpoint("/close"))
            request.httpMethod = "POST"
            request.httpBody = Data()
            URLSession.shared.dataTask(with: request).resume()
        }.resume()
    }

    private func succeed() {
        guard !finished else { return }; finished = true
        print("bridge integration passed")
        exit(0)
    }

    private func fail(_ message: String) {
        guard !finished else { return }; finished = true
        fputs("bridge integration failed: \(message)\n", stderr)
        exit(2)
    }
}

@main
struct BridgeTest {
    static func main() {
        let test = BridgeIntegration(output: CommandLine.arguments[1])
        test.start()
        dispatchMain()
    }
}
SWIFT
swiftc "$TMP_DIR/StatusApp.swift" "$TMP_DIR/BridgeTest.swift" -o "$TMP_DIR/bridge-test" -framework Cocoa -framework WebKit
"$TMP_DIR/bridge-test" "$TMP_DIR/browser_signals" >"$TMP_DIR/bridge-output"

printf '%s\n' '① Swift、JavaScript 与 localhost Bridge 可运行'
check "报告页 Swift 编译" "$([[ -x "$TMP_DIR/dump" ]] && echo yes)" yes
check "报告页 HTML 已生成" "$([[ -s "$TMP_DIR/report.html" ]] && echo yes)" yes
check "JavaScriptCore 语法验证" yes yes
check "localhost Bridge 往返" "$(grep -c 'bridge integration passed' "$TMP_DIR/bridge-output" || true)" 1

printf '%s\n' '② 完整报告关键分组齐全'
for title in '信号一致性矩阵' '出口与 IP' '时区、区域与语言' 'WebRTC 与泄漏面' 'DNS' \
             'Claude 连通性' '浏览器、设备与运行容器' '线路质量' \
             '26 项加权评分明细' '支付与账号地区（人工核对）'; do
  check "包含 $title" "$([[ $(grep -c "$title" "$TMP_DIR/report.html" || true) -ge 1 ]] && echo yes)" yes
done

printf '%s\n' '③ 生命周期、安全和可访问状态'
check "页面轮询完整报告" "$(grep -c '/report?t=' "$TMP_DIR/report.html" || true)" 1
check "完成后回收 localhost listener" "$(grep -c '/close?t=' "$TMP_DIR/report.html" || true)" 2
check "动态值使用 textContent" "$([[ $(grep -c 'textContent' "$TMP_DIR/report.html" || true) -ge 2 ]] && echo yes)" yes
check "包含 CSP" "$(grep -c 'Content-Security-Policy' "$ROOT/menubar/StatusApp.swift" || true)" 1
check "完成后启动 5 秒倒计时" "$(grep -c 'let remaining=5' "$TMP_DIR/report.html" || true)" 1
check "倒计时结束调用 window.close" "$(grep -c 'escapeClose();window.close()' "$TMP_DIR/report.html" || true)" 1
check "提供保持打开按钮" "$(grep -c '保持打开' "$TMP_DIR/report.html" || true)" 1
check "不再保留旧的 10 秒倒计时" "$(grep -c '10 秒后自动关闭\|本页将在 10 秒' "$TMP_DIR/report.html" || true)" 0
check "时区匹配行使用原生选中态颜色" "$([[ $(grep -c 'plain("系统时区:' "$ROOT/menubar/StatusApp.swift" || true) -ge 2 ]] && echo yes)" yes
check "时区匹配行不再硬编码绿色" "$(grep -c 'colored("系统时区:.*systemGreen' "$ROOT/menubar/StatusApp.swift" || true)" 0
check "线路质量标题不再带 HTTPS/TCP 前缀" "$(grep -c 'HTTPS/TCP 线路质量' "$ROOT/menubar/StatusApp.swift" || true)" 0
check "波动图支持鼠标移动取样" "$(grep -c 'override func mouseMoved' "$ROOT/menubar/StatusApp.swift" || true)" 1
check "波动图提示悬停查看延迟" "$(grep -c '鼠标移到曲线上查看每次延迟' "$ROOT/menubar/StatusApp.swift" || true)" 1
check "主菜单不再重复展示风险摘要" "$(grep -c 'Claude 使用风险:' "$ROOT/menubar/StatusApp.swift" || true)" 0
check "主菜单不再重复展示使用结论" "$(grep -c '使用结论:' "$ROOT/menubar/StatusApp.swift" || true)" 0
check "主菜单不再重复展示出口建议" "$(grep -c '出口建议:' "$ROOT/menubar/StatusApp.swift" || true)" 0
check "Claude 环境项继续使用风险档位" "$([[ $(grep -c 'let riskLevel = c\["risklevel"\]' "$ROOT/menubar/StatusApp.swift" || true) -ge 1 ]] && echo yes)" yes
check "手动项仍可点击查看修复方案" "$(grep -c '一键修复 / 查看方案' "$ROOT/menubar/StatusApp.swift" || true)" 1
check "更新提示使用强调色主按钮" "$(grep -c 'AccentActionButton(title: "更新并重启"' "$ROOT/menubar/StatusApp.swift" || true)" 1
check "更新提示支持减少动态效果" "$(grep -c 'accessibilityDisplayShouldReduceMotion' "$ROOT/menubar/StatusApp.swift" || true)" 2
check "菜单栏标题右侧包含展开箭头" "$([[ $(grep -c '\+ "  ›"' "$ROOT/menubar/StatusApp.swift" || true) -ge 1 ]] && echo yes)" yes

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过"
else
  echo "存在失败"
fi
exit $FAIL
