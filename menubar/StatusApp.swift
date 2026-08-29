import Cocoa

// auto-timezone 菜单栏监控 App (LSUIElement)
// 自包含: 检测脚本打包在 App 内，数据写入用户的 Application Support 目录。

// 数据目录: ~/Library/Application Support/AutoTimezone
let baseDir: String = {
    let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSup.appendingPathComponent("AutoTimezone")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}()
let statusPath = (baseDir as NSString).appendingPathComponent("status")
let claudeStatusPath = (baseDir as NSString).appendingPathComponent("claude_status")
let logPath = (baseDir as NSString).appendingPathComponent("auto-timezone.log")
// 检测脚本: 优先用 App 包内 Resources 里的，开发时回退到源码目录
func script(_ name: String) -> String {
    Bundle.main.path(forResource: name, ofType: "sh")
        ?? (NSHomeDirectory() as NSString).appendingPathComponent("auto-timezone/\(name).sh")
}
let scriptPath = script("auto-timezone")
let claudeScriptPath = script("claude-check")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var uiTimer: Timer?
    var scanTimer: Timer?
    var lastExitIP = ""      // 出口 IP 变化时才重跑 Claude 环境体检

    func applicationDidFinishLaunching(_ n: Notification) {
        item.menu = NSMenu()
        item.autosaveName = "AutoTimezoneStatusItem"   // 记住用户 ⌘拖动后的位置，开机后不再回到刘海
        item.behavior = .removalAllowed
        refresh()
        notify("出口IP时区监控已启动", "图标在屏幕右上角菜单栏 🌐，点击查看出口IP与时区")
        runScript(["--once"])            // 启动即检测一次
        // 每 30 秒读快照刷新显示
        uiTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // 定时主动检测(默认 1 分钟，可在菜单"检测间隔"调整)
        startScanTimer()
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
        menu.addItem(disabled("版本 v\(ver)"))
        menu.addItem(action("退出", #selector(quit)))
        item.menu = menu

        autoCheckIfExitChanged(s)
    }

    func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
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
            runScript(["--quiet"], claudeScriptPath)
        }
    }

    func claudeMenuItem() -> NSMenuItem {
        let c = readStatus(claudeStatusPath)
        let score = Int(c["score"] ?? "") ?? -1
        let dot = score < 0 ? "⚪️" : (score >= 85 ? "🟢" : score >= 70 ? "🟡" : score >= 50 ? "🟠" : "🔴")
        let title = score < 0 ? "Claude 环境体检" : "Claude 环境 \(dot) \(score) 分 · \(c["grade"] ?? "")"

        let sub = NSMenu()
        if score < 0 {
            sub.addItem(disabled("尚未体检"))
        } else {
            sub.addItem(disabled(c["verdict"] ?? ""))
            sub.addItem(.separator())
            sub.addItem(disabled("出口: \(c["ip"] ?? "?") · \(c["country"] ?? "?") · \(c["iptype"] ?? "?")"))
            sub.addItem(disabled("归属: \(c["isp"] ?? "?")"))
            sub.addItem(disabled("API 直连: HTTP \(c["api"] ?? "?")   接口: \(c["base"] ?? "?")"))
            sub.addItem(disabled("CLI: \(c["claudever"] ?? "?")"))
            let issues = (c["issues"] ?? "").split(separator: "|").map(String.init)
            let fixes = (c["fixes"] ?? "").split(separator: "|").map(String.init)
            if !issues.isEmpty {
                sub.addItem(.separator())
                issues.forEach { sub.addItem(disabled("⚠️  \($0)")) }
            }
            if !fixes.isEmpty {
                sub.addItem(.separator())
                fixes.forEach { sub.addItem(disabled("→  \($0)")) }
            }
            sub.addItem(.separator())
            sub.addItem(disabled("体检时间: \(c["time"] ?? "—")"))
        }
        sub.addItem(.separator())
        sub.addItem(action("重新体检", #selector(runClaudeCheck)))
        if c["fixable"] == "1" {
            sub.addItem(action("一键修复(时区)", #selector(runClaudeFix)))
        }
        if let cc = c["country"], cc != "?", (c["locale"] ?? "").hasSuffix("_\(cc)") == false {
            sub.addItem(action("把系统区域改为 \(cc)", #selector(runClaudeFixLocale)))
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @objc func runClaudeCheck() { runScript(["--quiet"], claudeScriptPath) }
    @objc func runClaudeFix() { runScript(["--fix"], claudeScriptPath) }
    @objc func runClaudeFixLocale() { runScript(["--fix-locale"], claudeScriptPath) }

    @objc func runCheck() { runScript(["--once"]) }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不在 Dock 显示
let delegate = AppDelegate()
app.delegate = delegate
app.run()
