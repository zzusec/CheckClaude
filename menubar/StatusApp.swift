import Cocoa
import WebKit

// auto-timezone 菜单栏监控 App (LSUIElement)
// 自包含: 检测脚本打包在 App 内，数据写入用户的 Application Support 目录。

// 数据目录: ~/Library/Application Support/CheckClaude
let baseDir: String = {
    let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSup.appendingPathComponent("CheckClaude")
    // v2.0 改名前叫 AutoTimezone，把旧目录搬过来保住历史日志(出口稳定性要读 24h 记录)
    let old = appSup.appendingPathComponent("AutoTimezone")
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
        try? fm.moveItem(at: old, to: dir)
    }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}()
let statusPath = (baseDir as NSString).appendingPathComponent("status")
let claudeStatusPath = (baseDir as NSString).appendingPathComponent("claude_status")
let browserPath = (baseDir as NSString).appendingPathComponent("browser_signals")
let logPath = (baseDir as NSString).appendingPathComponent("auto-timezone.log")
// 检测脚本: 优先用 App 包内 Resources 里的，开发时回退到源码目录
func script(_ name: String) -> String {
    Bundle.main.path(forResource: name, ofType: "sh")
        ?? (NSHomeDirectory() as NSString).appendingPathComponent("auto-timezone/\(name).sh")
}
let scriptPath = script("auto-timezone")
let claudeScriptPath = script("claude-check")
let upgradeScriptPath = script("upgrade")
let updatePath = (baseDir as NSString).appendingPathComponent("update_status")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var uiTimer: Timer?
    var scanTimer: Timer?
    var lastExitIP = ""      // 出口 IP 变化时才重跑 Claude 环境体检
    var probe: BrowserProbe?
    var updateTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item.menu = NSMenu()
        item.autosaveName = "CheckClaudeStatusItem"   // 记住用户 ⌘拖动后的位置，开机后不再回到刘海
        item.behavior = .removalAllowed
        refresh()
        notify("CheckClaude已启动", "图标在屏幕右上角菜单栏 🌐，点击查看出口IP与时区")
        runScript(["--once"])            // 启动即检测一次
        // 每 30 秒读快照刷新显示
        uiTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // 定时主动检测(默认 1 分钟，可在菜单"检测间隔"调整)
        startScanTimer()
        // 版本检查: 启动时一次，之后每 6 小时。频率再高对 GitHub 也不礼貌
        runScript(["--check"], upgradeScriptPath)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.runScript(["--check"], upgradeScriptPath)
        }
    }

    // 当前检测间隔(秒)，默认 60
    func scanInterval() -> Double {
        let v = UserDefaults.standard.double(forKey: "scanInterval")
        return v > 0 ? v : 60
    }

    func startScanTimer() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval(), repeats: true) { [weak self] _ in
            self?.runScript(["--once"])
        }
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag), forKey: "scanInterval")
        startScanTimer()
        refresh()
    }

    func runScript(_ args: [String], _ path: String = scriptPath) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path] + args
        var env = ProcessInfo.processInfo.environment
        env["AUTO_TZ_DIR"] = baseDir   // 与脚本共用同一数据目录
        p.environment = env
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        try? p.run()
    }

    func notify(_ title: String, _ msg: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(msg)\" with title \"\(title)\""]
        try? p.run()
    }

    func readStatus(_ path: String = statusPath) -> [String: String] {
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var d: [String: String] = [:]
        for line in txt.split(separator: "\n") {
            if let eq = line.firstIndex(of: "=") {
                d[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        return d
    }

    func refresh() {
        let s = readStatus()
        let consistent = s["consistent"] ?? ""
        let tz = s["tz"] ?? "?"

        // 矢量图标(SF Symbol) + 状态色 + 出口时区城市名，确保在菜单栏可见
        let gfwtz = s["gfwtz"] ?? ""
        // 只有合法 IANA 时区(含 /)才取城市名；"?"/空 时留空，避免红叉旁出现问号
        let city = gfwtz.contains("/")
            ? (gfwtz.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "")
            : ""
        if let btn = item.button {
            // 三路一致=绿勾✓ 不一致=红叉✗ 无数据=灰问号 (仅图标一个勾/叉，文字只放城市名)
            let symName: String
            let color: NSColor
            if consistent == "1" { symName = "checkmark.circle.fill"; color = .systemGreen }
            else if s.isEmpty { symName = "questionmark.circle"; color = .systemGray }
            else { symName = "xmark.circle.fill"; color = .systemRed }
            // 颜色只作用在勾/叉图标上(paletteColors)，不用 contentTintColor 以免染到文字
            let conf = NSImage.SymbolConfiguration(paletteColors: [color])
            let img = NSImage(systemSymbolName: symName, accessibilityDescription: "出口IP状态")?
                .withSymbolConfiguration(conf)
            img?.isTemplate = false
            btn.image = img
            btn.imagePosition = .imageLeading
            btn.contentTintColor = nil                          // 文字保持系统默认色，与其它菜单栏文字一致
            btn.title = city.isEmpty ? "" : " \(city)"
        }

        let menu = NSMenu()
        let head = consistent == "1" ? "出口 IP 一致 ✅" : (s.isEmpty ? "尚无检测数据" : "出口 IP 异常 ⚠️")
        menu.addItem(disabled(head))
        menu.addItem(.separator())
        menu.addItem(disabled("国内视角: \(s["cn"] ?? "?")"))
        menu.addItem(disabled("国外视角: \(s["intl"] ?? "?")"))
        menu.addItem(disabled("谷歌/被封: \(s["gfw"] ?? "?")  (Google: \(s["google"] ?? "?"))"))
        menu.addItem(.separator())
        menu.addItem(disabled("谷歌侧时区: \(s["gfwtz"] ?? "?")"))
        menu.addItem(disabled("系统时区: \(tz)"))
        menu.addItem(disabled("更新时间: \(s["time"] ?? "—")"))
        menu.addItem(.separator())
        menu.addItem(claudeMenuItem())
        // 体检和修复都放主菜单一级，不藏进子菜单(子菜单只放明细)
        let c = readStatus(claudeStatusPath)
        menu.addItem(action("重新体检", #selector(runClaudeCheck)))
        if c["fixable"] == "1", let list = c["fixlist"], !list.isEmpty {
            menu.addItem(action("⚡ 一键修复：\(list)", #selector(runClaudeFix)))
        }
        menu.addItem(.separator())
        menu.addItem(action("立即检测", #selector(runCheck)))
        // 检测间隔子菜单
        let intervalMenu = NSMenu()
        for (label, secs) in [("1 分钟", 60), ("2 分钟", 120), ("5 分钟", 300), ("10 分钟", 600)] {
            let mi = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = secs
            mi.state = (Int(scanInterval()) == secs) ? .on : .off
            intervalMenu.addItem(mi)
        }
        let intervalItem = NSMenuItem(title: "检测间隔", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)
        menu.addItem(action("打开日志", #selector(openLog)))
        menu.addItem(.separator())
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let u = readStatus(updatePath)
        if u["hasupdate"] == "1", let latest = u["latest"] {
            menu.addItem(disabled("版本 v\(ver)"))
            menu.addItem(colored("⬆ 升级到 v\(latest)", .systemBlue, #selector(doUpgrade)))
            notifyNewVersion(latest)
        } else {
            menu.addItem(disabled("版本 v\(ver)（已是最新）"))
            menu.addItem(action("检查更新", #selector(checkUpdate)))
        }
        menu.addItem(.separator())
        menu.addItem(disabled("本公司其他产品"))
        menu.addItem(action("叮叮提醒 — 重要的事，我来帮你记着", #selector(openYinso)))
        menu.addItem(action("退出", #selector(quit)))
        item.menu = menu

        autoCheckIfExitChanged(s)
    }

    func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
    // disabled 项的 attributedTitle 会被系统统一压成灰色，所以要上色就必须是 enabled 的，
    // 没有实际动作的就绑一个空 selector。
    func colored(_ t: String, _ color: NSColor, _ sel: Selector? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel ?? #selector(noop), keyEquivalent: "")
        i.target = self
        i.attributedTitle = NSAttributedString(string: t, attributes: [
            .foregroundColor: color,
            .font: NSFont.menuFont(ofSize: 0)
        ])
        return i
    }
    @objc func noop() {}

    func action(_ t: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    // ── Claude 环境体检 ──────────────────────────────────────────
    // 出口 IP 变了才自动重测(环境画像只跟着出口走)，避免每分钟去敲 anthropic API
    func autoCheckIfExitChanged(_ s: [String: String]) {
        let ip = s["gfw"] ?? ""
        guard !ip.isEmpty, ip != "?" else { return }
        if ip != lastExitIP {
            lastExitIP = ip
            fullCheck()
        }
    }

    // 先用 WebView 采集浏览器信号，再跑体检脚本(脚本要读采集结果)
    func fullCheck(_ args: [String] = ["--quiet"]) {
        guard probe == nil else { return }          // 采集中就别叠加
        probe = BrowserProbe(outPath: browserPath) { [weak self] in
            guard let self else { return }
            self.probe = nil
            self.runScript(args, claudeScriptPath)
        }
        probe?.run()
    }

    func claudeMenuItem() -> NSMenuItem {
        let c = readStatus(claudeStatusPath)
        let score = Int(c["score"] ?? "") ?? -1
        let dot = score < 0 ? "⚪️" : (score >= 85 ? "🟢" : score >= 70 ? "🟡" : score >= 50 ? "🟠" : "🔴")
        // 提分详情在子菜单顶部，标题只报状态，不啰嗦
        let title = score < 0 ? "Claude 环境体检" : "Claude 环境 \(dot) \(score) 分 · \(c["grade"] ?? "")"
        // 低于 70 分 = 环境不适合跑 Claude，整块标红，别让人漏看
        let unfit = score >= 0 && score < 70
        let alertColor: NSColor = unfit ? .systemRed : .labelColor

        let sub = NSMenu()
        if score < 0 {
            sub.addItem(disabled("尚未体检"))
        } else {
            sub.addItem(unfit ? colored(c["verdict"] ?? "", .systemRed) : disabled(c["verdict"] ?? ""))

            // 提分清单放最前面，橙色可点，别埋在明细里跟着一起变灰
            let gains = (c["gains"] ?? "").split(separator: "|").map(String.init)
            sub.addItem(.separator())
            if gains.isEmpty {
                sub.addItem(colored("🎉 已满分，没有可提升项", .labelColor))
            } else {
                sub.addItem(colored("还能提 \(100 - score) 分", .labelColor))
                let fixableNames = ["系统时区匹配出口", "DNS 出口", "代理形态"]
                for g in gains {
                    let f = g.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 3 else { continue }
                    // 能一键修的项，点它就直接修
                    let canFix = c["fixable"] == "1" && fixableNames.contains(f[0])
                    let mark = canFix ? "⚡" : "＋\(f[1])"
                    sub.addItem(colored("   \(mark)  \(f[0])：\(f[2])", .labelColor,
                                        canFix ? #selector(runClaudeFix) : nil))
                }
            }
            // 14 项信号，按 出口/质量/画像/DNS 分组展示: 分组~标签~权重~得分~值
            var group = ""
            for row in (c["signals"] ?? "").split(separator: ";") {
                let f = row.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 5 else { continue }
                if f[0] != group {
                    group = f[0]
                    sub.addItem(.separator())
                    sub.addItem(disabled("── \(group) ──"))
                }
                let ok = f[2] == f[3]
                let line = "\(ok ? "✓" : "⚠")  \(f[1])：\(f[4])   \(f[3])/\(f[2])"
                sub.addItem(unfit && !ok ? colored(line, .systemRed) : disabled(line))
            }
            sub.addItem(.separator())
            sub.addItem(disabled("出口: \(c["ip"] ?? "?") · \(c["city"] ?? "") · \(c["asn"] ?? "?")"))
            sub.addItem(disabled("系统: \(c["os"] ?? "?") · \(c["locale"] ?? "?") · \(c["proxymode"] ?? "?")"))
            sub.addItem(disabled("DNS: \(c["dns"] ?? "?") · claude.ai → \(c["dnsresult"] ?? "?")"))
            sub.addItem(disabled("CLI: \(c["claudever"] ?? "?") · 接口 \(c["base"] ?? "?")"))
            let issues = (c["issues"] ?? "").split(separator: "|").map(String.init)
            let fixes = (c["fixes"] ?? "").split(separator: "|").map(String.init)
            if !issues.isEmpty {
                sub.addItem(.separator())
                issues.forEach { sub.addItem(unfit ? colored("⚠️  \($0)", .systemRed) : disabled("⚠️  \($0)")) }
            }
            if !fixes.isEmpty {
                sub.addItem(.separator())
                fixes.forEach { sub.addItem(disabled("→  \($0)")) }
            }
            sub.addItem(.separator())
            sub.addItem(disabled("体检时间: \(c["time"] ?? "—")"))
        }
        sub.addItem(.separator())
        if let cc = c["country"], cc != "?", (c["locale"] ?? "").hasSuffix("_\(cc)") == false {
            sub.addItem(action("把系统区域改为 \(cc)", #selector(runClaudeFixLocale)))
        }
        if c["needsudo"] == "1" {
            sub.addItem(disabled("⚠️ 部分修复需授权：sudo bash enable-auto-timezone.sh"))
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if unfit {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: alertColor,
                .font: NSFont.menuFont(ofSize: 0)
            ])
        }
        item.submenu = sub
        return item
    }

    @objc func runClaudeCheck() { fullCheck() }
    // 修复不依赖浏览器信号，直接跑脚本，别让用户干等 WebView 采集
    @objc func runClaudeFix() { runScript(["--fix"], claudeScriptPath) }
    @objc func runClaudeFixLocale() { runScript(["--fix-locale"], claudeScriptPath) }

    @objc func runCheck() { runScript(["--once"]) }

    // 同一个新版本只弹一次，别每 30 秒重画菜单就骚扰一遍
    func notifyNewVersion(_ latest: String) {
        let key = "notifiedVersion"
        guard UserDefaults.standard.string(forKey: key) != latest else { return }
        UserDefaults.standard.set(latest, forKey: key)
        notify("CheckClaude 有新版本 v\(latest)", "点菜单栏图标 →「升级到 v\(latest)」一键更新")
    }

    @objc func checkUpdate() { runScript(["--check"], upgradeScriptPath) }
    @objc func doUpgrade() { runScript(["--install"], upgradeScriptPath) }

    @objc func openYinso() {
        NSWorkspace.shared.open(URL(string: "https://www.yinso.com")!)
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// 浏览器端信号采集: 用一个隐藏的 WKWebView 跑检测 JS，拿 shell 拿不到的那部分信号
// (WebRTC 泄漏 / Intl locale / 渲染指纹 / 字体 / Emoji)，结果写成 key=value 给 claude-check.sh 读。
//
// 注意: WKWebView 是 Safari 引擎，指纹与用户实际用的 Chrome 不完全一致；能反映的是
// "这台机器 + 这条网络"的环境画像，不是某个浏览器的完整指纹。
//
// WebRTC 是这里最有价值的一项: 它走 UDP，不经过 HTTP 代理，所以能暴露代理没兜住的真实出口。
final class BrowserProbe: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var timeout: Timer?
    private var done = false
    private var collected: [String: Any] = [:]
    private let outPath: String
    private let completion: () -> Void

    init(outPath: String, completion: @escaping () -> Void) {
        self.outPath = outPath
        self.completion = completion
        super.init()
    }

    func run() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "cc")
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        webView = wv
        // 离屏窗口: WKWebView 不在窗口层级里时，系统会把 setTimeout 节流到几十秒，
        // WebRTC 那段等不到结果。挂进一个屏幕外的 1px 窗口就恢复正常速度。
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = wv
        w.alphaValue = 0.01
        w.orderBack(nil)
        window = w
        wv.loadHTMLString(Self.html, baseURL: URL(string: "https://local.probe/"))
        // JS 卡住(STUN 不通等)时兜底，别让菜单一直等
        timeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.collected["rtc_timeout"] = "1"
            self.finish(self.collected)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let d = msg.body as? [String: Any] else { return finish(["error": "返回格式异常"]) }
        collected.merge(d) { _, new in new }
        // JS 分两次发: 第一次是同步信号(语言/时区/指纹)，第二次带 WebRTC 结果。
        // 先落盘一次，这样即便 STUN 不通也不会丢掉已拿到的信号。
        if d["phase"] as? String == "final" { finish(collected) } else { write(collected) }
    }

    private func write(_ dict: [String: Any]) {
        var txt = "time=\(Int(Date().timeIntervalSince1970))\n"
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            txt += "\(k)=\(String(describing: v).replacingOccurrences(of: "\n", with: " "))\n"
        }
        try? txt.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    private func finish(_ dict: [String: Any]) {
        guard !done else { return }
        done = true
        timeout?.invalidate()
        write(dict)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "cc")
        window?.close(); window = nil
        webView = nil
        completion()
    }

    private static let html = """
    <!doctype html><meta charset="utf-8"><body><script>
    (async () => {
      const out = {};
      const send = (phase) => {
        out.phase = phase;
        try { webkit.messageHandlers.cc.postMessage(out); } catch(e){}
      };
      try {
        // ── 浏览器身份画像 ──
        out.languages = (navigator.languages || []).join(',');
        const ro = Intl.DateTimeFormat().resolvedOptions();
        out.tz = ro.timeZone || '';
        out.locale = ro.locale || '';
        out.tzoffset = String(-new Date().getTimezoneOffset() / 60);
        out.platform = navigator.platform || '';
        out.hw = String(navigator.hardwareConcurrency || '');

        // ── 终端环境指纹: 渲染特征 ──
        try {
          const c = document.createElement('canvas'), x = c.getContext('2d');
          x.textBaseline = 'top'; x.font = '14px Arial';
          x.fillText('Claude环境检测', 2, 2);
          const d = c.toDataURL();
          let h = 0; for (let i = 0; i < d.length; i++) h = (h * 31 + d.charCodeAt(i)) | 0;
          out.canvas = (h >>> 0).toString(16);
        } catch (e) { out.canvas = ''; }
        try {
          const gl = document.createElement('canvas').getContext('webgl');
          const dbg = gl.getExtension('WEBGL_debug_renderer_info');
          out.webgl = gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) || '';
        } catch (e) { out.webgl = ''; }
        // Emoji 风格: 苹果彩色字形与开源字形的绘制宽度不同，可粗判是不是原生 macOS 渲染
        try {
          const c = document.createElement('canvas'), x = c.getContext('2d');
          x.font = '16px sans-serif';
          out.emojiw = String(Math.round(x.measureText('\\u{1F600}').width * 10) / 10);
        } catch (e) { out.emojiw = ''; }

        // ── 字体探测: 装了哪些中文字体(国产终端弱信号) ──
        try {
          const probe = ['PingFang SC','Hiragino Sans GB','Microsoft YaHei','SimSun','Songti SC','STHeiti'];
          const s = document.createElement('span');
          s.style.cssText = 'position:absolute;left:-9999px;font-size:72px';
          s.textContent = 'mmmmmmmmmmlli测试';
          document.body.appendChild(s);
          s.style.fontFamily = 'monospace'; const base = s.offsetWidth;
          out.fonts = probe.filter(f => {
            s.style.fontFamily = "'" + f + "',monospace";
            return s.offsetWidth !== base;
          }).join(',');
          s.remove();
        } catch (e) { out.fonts = ''; }

        send('sync');   // 同步信号先落盘，WebRTC 慢或不通也不会连累它们

        // ── WebRTC 泄漏: UDP 不走 HTTP 代理，能暴露代理没兜住的真实出口 ──
        out.rtc_host = ''; out.rtc_srflx = '';
        try {
          const pc = new RTCPeerConnection({ iceServers: [
            { urls: 'stun:stun.cloudflare.com:3478' },
            { urls: 'stun:stun.l.google.com:19302' }
          ]});
          pc.createDataChannel('probe');
          const hosts = new Set(), srflx = new Set();
          pc.onicecandidate = e => {
            if (!e.candidate) return;
            const c = e.candidate.candidate;
            const m = c.match(/([0-9]{1,3}(?:\\.[0-9]{1,3}){3})/);
            if (!m) return;
            if (c.indexOf('typ host') >= 0) hosts.add(m[1]);
            if (c.indexOf('typ srflx') >= 0) srflx.add(m[1]);
          };
          const offer = await pc.createOffer();
          await pc.setLocalDescription(offer);
          await new Promise(r => setTimeout(r, 4000));
          out.rtc_host = [...hosts].join(',');
          out.rtc_srflx = [...srflx].join(',');
          pc.close();
        } catch (e) { out.rtc_err = String(e).slice(0, 60); }
      } catch (e) {
        out.error = String(e).slice(0, 100);
      }
      send('final');
    })();
    </script></body>
    """
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不在 Dock 显示
let delegate = AppDelegate()
app.delegate = delegate
app.run()
