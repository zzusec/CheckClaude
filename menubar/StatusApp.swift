import Cocoa
import WebKit
import Network

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
let upgradeStatePath = (baseDir as NSString).appendingPathComponent("upgrade_state")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var uiTimer: Timer?
    var scanTimer: Timer?
    var lastExitIP = ""      // 出口 IP 变化时才重跑 Claude 环境体检
    var probe: BrowserProbe?
    var bridge: BrowserBridge?
    var phase: String?          // 非 nil = 正在检测(内部分两步，不暴露给用户)
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
        // 版本检查: 启动时一次，之后每 2 小时。GitHub API 匿名限额 60 次/小时，这个频率很安全
        runScript(["--check"], upgradeScriptPath)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2 * 3600, repeats: true) { [weak self] _ in
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

    func runScript(_ args: [String], _ path: String = scriptPath, then: (() -> Void)? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path] + args
        var env = ProcessInfo.processInfo.environment
        env["AUTO_TZ_DIR"] = baseDir   // 与脚本共用同一数据目录
        p.environment = env
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh(); then?() }
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
        // 图标要反映"这台机器现在能不能安全跑 Claude"，而不只是三路 IP 一致性 ——
        // 光看 IP 一致但分数掉到 60 分，图标还是绿的，等于没提醒。
        let cs = readStatus(claudeStatusPath)
        let claudeScore = Int(cs["score"] ?? "") ?? -1
        let safe = claudeScore >= 90 && consistent == "1"
        alertIfUnsafe(claudeScore, consistent: consistent, verdict: cs["verdict"] ?? "")

        if let btn = item.button {
            // 综合判定: 安全=绿勾 / 有隐患=黄感叹号 / 不建议使用=红叉 / 无数据=灰问号
            let symName: String
            let color: NSColor
            if claudeScore < 0 && s.isEmpty { symName = "questionmark.circle"; color = .systemGray }
            else if safe { symName = "checkmark.circle.fill"; color = .systemGreen }
            else if claudeScore >= 70 && consistent == "1" { symName = "exclamationmark.triangle.fill"; color = .systemOrange }
            else { symName = "xmark.circle.fill"; color = .systemRed }
            // 颜色只作用在勾/叉图标上(paletteColors)，不用 contentTintColor 以免染到文字
            let conf = NSImage.SymbolConfiguration(paletteColors: [color])
            let img = NSImage(systemSymbolName: symName, accessibilityDescription: "出口IP状态")?
                .withSymbolConfiguration(conf)
            img?.isTemplate = false
            btn.image = img
            btn.imagePosition = .imageLeading
            btn.contentTintColor = nil                          // 文字保持系统默认色，与其它菜单栏文字一致
            let hasUpd = readStatus(updatePath)["hasupdate"] == "1"
            if let up = upgradeState {
                btn.title = " 升级 \(up)"
            } else {
                btn.title = (city.isEmpty ? "" : " \(city)") + (hasUpd ? " ⬆" : "")
            }
        }

        let menu = NSMenu()
        if let up = upgradeState {
            menu.addItem(colored("⬆ 正在升级：\(up)", .labelColor))
            menu.addItem(.separator())
        }
        let head = consistent == "1" ? "出口 IP 一致 ✅" : (s.isEmpty ? "尚无检测数据" : "出口 IP 异常 ⚠️")
        menu.addItem(disabled(head))
        menu.addItem(.separator())
        menu.addItem(disabled("国内视角: \(s["cn"] ?? "?")"))
        menu.addItem(disabled("国外视角: \(s["intl"] ?? "?")"))
        menu.addItem(disabled("谷歌/被封: \(s["gfw"] ?? "?")  (Google: \(s["google"] ?? "?"))"))
        menu.addItem(.separator())
        menu.addItem(disabled("谷歌侧时区: \(s["gfwtz"] ?? "?")"))
        menu.addItem(disabled("系统时区: \(tz)"))
        // 时间戳跟着系统时区走，而系统时区跟着出口走 —— 出口回到国内时它就是本地时间
        let exitCC = readStatus(claudeStatusPath)["country"] ?? ""
        menu.addItem(disabled("\(exitCC == "CN" ? "本地时间" : "海外时间"): \(s["time"] ?? "—")"))
        menu.addItem(.separator())
        menu.addItem(claudeMenuItem())
        // 体检和修复都放主菜单一级，不藏进子菜单(子菜单只放明细)
        let c = readStatus(claudeStatusPath)
        if phase != nil {
            menu.addItem(disabled("正在检测…"))
        } else {
            menu.addItem(action("重新体检", #selector(runClaudeCheck)))
        }
        // 始终摆在这儿: 按钮凭空消失会让人以为功能没了，置灰说明比隐藏清楚
        if c["fixable"] == "1", let list = c["fixlist"], !list.isEmpty {
            menu.addItem(action("⚡ 一键修复：\(list)", #selector(runClaudeFix)))
        } else if !c.isEmpty {
            // score 只存在于 claudeMenuItem() 内部，这里自己从快照读
            let sc = Int(c["score"] ?? "") ?? -1
            menu.addItem(disabled(sc >= 100 ? "⚡ 一键修复（已满分，无需修复）"
                                            : "⚡ 一键修复（剩余项需手动处理）"))
        }

        // 手动处理步骤常驻菜单: 修复弹窗是一次性的，关掉就找不回来了
        let autoFixable = ["系统时区匹配出口", "DNS 出口", "代理形态"]
        let manual = (c["gains"] ?? "").split(separator: "|").map(String.init).compactMap { g -> [String]? in
            let f = g.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, !autoFixable.contains(f[0]) else { return nil }
            return f
        }
        if !manual.isEmpty {
            let mi = NSMenuItem(title: "📋 手动处理步骤（\(manual.count) 项）", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for f in manual {
                sub.addItem(colored("\(f[0])   +\(f[1]) 分", .labelColor))
                // 步骤按分号折行，太长的菜单项会被系统截断
                for (i, part) in f[2].components(separatedBy: "；").enumerated() {
                    sub.addItem(disabled("      \(i == 0 ? "" : "或 ")\(part)"))
                }
                sub.addItem(.separator())
            }
            sub.addItem(action("重新体检", #selector(runClaudeCheck)))
            mi.submenu = sub
            menu.addItem(mi)
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
        menu.addItem(action("官方网站", #selector(openYinso)))
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

    // 状态跌到"不建议使用"时主动弹通知 —— 用户不会一直盯着菜单栏图标。
    // 只在档位变化时弹，同一档不重复打扰。
    var lastSafetyTier = ""
    func alertIfUnsafe(_ score: Int, consistent: String, verdict: String) {
        guard score >= 0 else { return }
        let tier: String
        if score >= 90 && consistent == "1" { tier = "safe" }
        else if score >= 70 && consistent == "1" { tier = "warn" }
        else { tier = "unsafe" }

        defer { lastSafetyTier = tier }
        guard !lastSafetyTier.isEmpty, tier != lastSafetyTier else { return }

        switch tier {
        case "unsafe":
            notify("⚠️ 不建议使用 Claude", verdict.isEmpty ? "环境 \(score) 分，存在安全风险，点菜单栏查看" : verdict)
        case "warn":
            // 用户的标准是二元的: 不是绿色就别用。橙档虽然比红档轻，措辞一样不留余地。
            notify("⚠️ 不建议使用 Claude", "环境 \(score) 分存在隐患，点菜单栏看还差哪几项")
        default:
            notify("Claude 环境已恢复", "\(score) 分，可以正常使用")
        }
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

    // 体检分两步: ① 系统检测(本地信号，1~2 秒出结果) ② 浏览器指纹采集(后台开标签，采完自动关)
    // 第二步失败或用户关掉时，回退到内置 WKWebView 采集，保证浏览器组始终有数据。
    func fullCheck(_ args: [String] = ["--quiet"]) {
        guard phase == nil else { return }           // 正在检测就别叠加
        phase = "1/2 系统检测"
        refresh()
        runScript(args, claudeScriptPath) { [weak self] in
            guard let self else { return }
            guard self.browserProbeEnabled else { self.phase = nil; self.refresh(); return }
            self.phase = "2/2 浏览器指纹"
            self.refresh()
            self.bridge = BrowserBridge(outPath: browserPath) { [weak self] ok in
                guard let self else { return }
                self.bridge = nil
                if ok {
                    // 拿到真实浏览器指纹，重跑一次评分把这组信号合进去
                    self.runScript(["--quiet"], claudeScriptPath) { self.phase = nil; self.refresh() }
                } else {
                    self.fallbackWebView()
                }
            }
            self.bridge?.start()
        }
    }

    // 真实浏览器没回传时的兜底: 用内置 WKWebView 采一份(拿不到 Client Hints，但总比没有强)
    func fallbackWebView() {
        guard probe == nil else { phase = nil; refresh(); return }
        probe = BrowserProbe(outPath: browserPath) { [weak self] in
            guard let self else { return }
            self.probe = nil
            self.runScript(["--quiet"], claudeScriptPath) { self.phase = nil; self.refresh() }
        }
        probe?.run()
    }

    // 隐藏开关，正常用户不需要知道体检内部分两步。真要关:
    //   defaults write com.hx10.checkclaude browserProbe -bool false
    var browserProbeEnabled: Bool {
        UserDefaults.standard.object(forKey: "browserProbe") as? Bool ?? true
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
            // 26 项信号，按六组展示: 分组~标签~权重~得分~值
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

    @objc func toggleBrowserProbe() {
        UserDefaults.standard.set(!browserProbeEnabled, forKey: "browserProbe")
        refresh()
    }
    // 修复不依赖浏览器信号，直接跑脚本，别让用户干等 WebView 采集
    @objc func runClaudeFix() { runScript(["--fix"], claudeScriptPath) }

    // 升级期间每秒刷新菜单显示进度 —— 点了「立即升级」之后一片寂静，
    // 用户不知道是在下载还是卡死了。
    var upgradeTimer: Timer?
    func startUpgrade() {
        try? "启动中".write(toFile: upgradeStatePath, atomically: true, encoding: .utf8)
        upgradeTimer?.invalidate()
        upgradeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        runScript(["--install"], upgradeScriptPath) { [weak self] in
            guard let self else { return }
            self.upgradeTimer?.invalidate(); self.upgradeTimer = nil
            let st = (try? String(contentsOfFile: upgradeStatePath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if st.hasPrefix("失败") { self.notify("升级失败", st) }
            try? FileManager.default.removeItem(atPath: upgradeStatePath)
            self.refresh()
        }
    }

    var upgradeState: String? {
        guard let t = try? String(contentsOfFile: upgradeStatePath, encoding: .utf8) else { return nil }
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    @objc func runClaudeFixLocale() { runScript(["--fix-locale"], claudeScriptPath) }

    @objc func runCheck() { runScript(["--once"]) }

    // 发现新版直接弹对话框问要不要装 —— 纯通知只是告知，用户还得自己去菜单栏找入口，太绕。
    // 每天最多弹一次: 只弹一次会错过，每次重画菜单都弹会烦死人。
    var promptingUpgrade = false
    func notifyNewVersion(_ latest: String) {
        let d = UserDefaults.standard
        let key = "notifiedVersion", tsKey = "notifiedAt"
        let sameVersion = d.string(forKey: key) == latest
        let elapsed = Date().timeIntervalSince1970 - d.double(forKey: tsKey)
        guard !sameVersion || elapsed > 86400 else { return }
        guard !promptingUpgrade else { return }
        promptingUpgrade = true
        d.set(latest, forKey: key)
        d.set(Date().timeIntervalSince1970, forKey: tsKey)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.promptingUpgrade = false }
            let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "CheckClaude 有新版本 v\(latest)"
            a.informativeText = "当前 v\(cur)。点「立即升级」自动下载、安装并重启，无需其它操作。"
            a.alertStyle = .informational
            a.addButton(withTitle: "立即升级")
            a.addButton(withTitle: "稍后提醒")
            if a.runModal() == .alertFirstButtonReturn {
                self.startUpgrade()
            }
        }
    }

    @objc func checkUpdate() {
        notify("正在检查更新…", "")
        runScript(["--check"], upgradeScriptPath) { [weak self] in
            guard let self else { return }
            let u = self.readStatus(updatePath)
            if u["hasupdate"] == "1", let l = u["latest"] {
                self.notify("发现新版本 v\(l)", "点菜单栏「⬆ 升级到 v\(l)」一键更新")
            } else {
                self.notify("已经是最新版本", "v\(u["current"] ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))")
            }
            self.refresh()
        }
    }
    @objc func doUpgrade() { startUpgrade() }

    @objc func openYinso() {
        NSWorkspace.shared.open(URL(string: "https://www.yinso.com/labs/")!)
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


// 真实浏览器指纹采集: 起一个只听 127.0.0.1 的极简 HTTP server，用 open 唤起用户的默认浏览器
// 来访问它。WKWebView 是 Safari 引擎，拿不到 Client Hints / Sec-Fetch，也不是用户真正登录
// claude.ai 时用的那个浏览器；走这条路采到的才是 Anthropic 网页端实际看到的指纹。
//
// 安全: 只绑 127.0.0.1、随机端口、URL 带一次性 token、拿到结果或 90 秒超时立即关闭监听。
final class BrowserBridge {
    private var listener: NWListener?
    private var timeout: Timer?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    private let outPath: String
    private let done: (Bool) -> Void
    private var finished = false

    init(outPath: String, done: @escaping (Bool) -> Void) { self.outPath = outPath; self.done = done }

    func start() {
        do {
            let l = try NWListener(using: .tcp, on: .any)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] st in
                guard case .ready = st, let self, let port = self.listener?.port else { return }
                let url = "http://127.0.0.1:\(port.rawValue)/c?t=\(self.token)"
                // activates=false: 浏览器在后台开标签页，不抢焦点、不打断当前工作。
                // 采集完页面会自己 window.close()，用户基本无感。
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                cfg.addsToRecentItems = false
                NSWorkspace.shared.open(URL(string: url)!, configuration: cfg, completionHandler: nil)
            }
            listener = l
            l.start(queue: .main)
            timeout = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in self?.finish(false) }
        } catch { done(false) }
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 262144) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let head = req.components(separatedBy: "\r\n\r\n").first ?? req
            let lines = head.components(separatedBy: "\r\n")
            let start = lines.first ?? ""
            guard start.contains(self.token) else { self.respond(c, 403, "text/plain", "forbidden"); return }

            if start.hasPrefix("POST") {
                let body = req.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
                self.save(headers: lines, body: body)
                self.respond(c, 200, "text/plain", "ok")
                self.finish(true)
            } else {
                self.respond(c, 200, "text/html; charset=utf-8", Self.page(token: String(self.token)))
            }
        }
    }

    private func respond(_ c: NWConnection, _ code: Int, _ type: String, _ body: String) {
        let b = Array(body.utf8)
        let resp = "HTTP/1.1 \(code) OK\r\nContent-Type: \(type)\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(resp.utf8) + Data(b), completion: .contentProcessed { _ in c.cancel() })
    }

    // 服务端能看到的请求头正是浏览器指纹的一部分，JS 拿不到自己发出去的这些头
    private func save(headers: [String], body: String) {
        var out: [String: String] = ["source": "browser"]
        let want = ["user-agent": "ua", "accept-language": "accept_lang",
                    "sec-ch-ua": "ch_ua", "sec-ch-ua-platform": "ch_platform",
                    "sec-ch-ua-mobile": "ch_mobile", "sec-fetch-site": "sf_site",
                    "sec-fetch-mode": "sf_mode", "sec-fetch-dest": "sf_dest"]
        for h in headers.dropFirst() {
            guard let i = h.firstIndex(of: ":") else { continue }
            let k = h[..<i].lowercased(), v = h[h.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if let key = want[String(k)] { out[key] = v.replacingOccurrences(of: "\"", with: "") }
        }
        for kv in body.components(separatedBy: "\n") {
            guard let i = kv.firstIndex(of: "=") else { continue }
            out[String(kv[..<i])] = String(kv[kv.index(after: i)...])
        }
        var txt = "time=\(Int(Date().timeIntervalSince1970))\n"
        for (k, v) in out.sorted(by: { $0.key < $1.key }) {
            txt += "\(k)=\(v.replacingOccurrences(of: "\n", with: " "))\n"
        }
        try? txt.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        timeout?.invalidate(); listener?.cancel(); listener = nil
        done(ok)
    }

    static func page(token: String) -> String {
        return """
        <!doctype html><meta charset="utf-8"><title>CheckClaude 浏览器指纹检测</title>
        <style>body{font:15px/1.8 -apple-system,system-ui,sans-serif;max-width:32rem;margin:16vh auto;padding:0 1.5rem;color:#1a1a2e}
        h1{font-size:1.3rem;margin:0 0 .6rem}p{color:#5c5c70;margin:.4rem 0}
        .ok{color:#2f855a;font-weight:500}.err{color:#c53030}
        table{border-collapse:collapse;width:100%;margin:1rem 0 1.4rem;font-size:.92rem}
        th{text-align:left;font-weight:400;color:#8a8a9a;padding:.45rem .9rem .45rem 0;white-space:nowrap;vertical-align:top;width:7.5rem}
        td{padding:.45rem 0;color:#1a1a2e;word-break:break-all}
        tr+tr th,tr+tr td{border-top:1px solid #ececf3}
        .mute{font-size:.86rem;color:#8a8a9a}
        #keep{font:inherit;font-size:.86rem;margin-left:.5rem;padding:.2rem .7rem;cursor:pointer;
              border:1px solid #ddd8ff;border-radius:6px;background:#f0eeff;color:#4e4aaf}</style>
        <h1>CheckClaude 浏览器指纹检测</h1>
        <p id="s">正在采集…</p>
        <div id="d"></div>
        <div id="f" style="display:none">
          <p>这些信号已回传到本机的 CheckClaude，用于评估 claude.ai 网页端登录时的环境画像。
             <b>完整体检结果请看菜单栏的 CheckClaude 图标。</b></p>
          <p class="mute">检测在本机完成，数据不经过任何服务器，也不会被保存到本机以外的地方。</p>
          <p class="mute"><span id="cd"></span> <button id="keep">保持打开</button></p>
        </div>
        <script>
        (async () => {
          const o = {};
          const set = (k, v) => { o[k] = String(v == null ? "" : v).replace(/\\n/g, " "); };
          try {
            set("languages", (navigator.languages || []).join(","));
            const ro = Intl.DateTimeFormat().resolvedOptions();
            set("tz", ro.timeZone); set("locale", ro.locale);
            set("tzoffset", -new Date().getTimezoneOffset() / 60);
            set("platform", navigator.platform); set("hw", navigator.hardwareConcurrency);
            // 高熵 Client Hints: 只有 Chromium 有，能拿到真实平台版本和品牌列表
            if (navigator.userAgentData) {
              set("uad_mobile", navigator.userAgentData.mobile);
              set("uad_platform", navigator.userAgentData.platform);
              try {
                const h = await navigator.userAgentData.getHighEntropyValues(
                  ["platformVersion", "architecture", "fullVersionList"]);
                set("uad_platform_version", h.platformVersion);
                set("uad_arch", h.architecture);
                set("uad_brands", (h.fullVersionList || []).map(b => b.brand + " " + b.version).join("; "));
              } catch (e) {}
            }
            try {
              const c = document.createElement("canvas"), x = c.getContext("2d");
              x.textBaseline = "top"; x.font = "14px Arial"; x.fillText("Claude环境检测", 2, 2);
              const d = c.toDataURL(); let h = 0;
              for (let i = 0; i < d.length; i++) h = (h * 31 + d.charCodeAt(i)) | 0;
              set("canvas", (h >>> 0).toString(16));
            } catch (e) {}
            try {
              const gl = document.createElement("canvas").getContext("webgl");
              const dbg = gl.getExtension("WEBGL_debug_renderer_info");
              set("webgl", gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL));
              set("webgl_vendor", gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL));
            } catch (e) {}
            try {
              const c = document.createElement("canvas"), x = c.getContext("2d");
              x.font = "16px sans-serif";
              set("emojiw", Math.round(x.measureText("\\u{1F600}").width * 10) / 10);
            } catch (e) {}
            try {
              const probe = ["PingFang SC","Hiragino Sans GB","Microsoft YaHei","SimSun","Songti SC","STHeiti","Noto Sans CJK SC"];
              const sp = document.createElement("span");
              sp.style.cssText = "position:absolute;left:-9999px;font-size:72px";
              sp.textContent = "mmmmmmmmmmlli测试";
              document.body.appendChild(sp);
              sp.style.fontFamily = "monospace"; const base = sp.offsetWidth;
              set("fonts", probe.filter(f => { sp.style.fontFamily = "'" + f + "',monospace"; return sp.offsetWidth !== base; }).join(","));
              sp.remove();
            } catch (e) {}
            // WebRTC: UDP 不经 HTTP 代理，能暴露代理没兜住的真实出口
            try {
              const pc = new RTCPeerConnection({ iceServers: [
                { urls: "stun:stun.cloudflare.com:3478" }, { urls: "stun:stun.l.google.com:19302" }] });
              pc.createDataChannel("p");
              const hosts = new Set(), srflx = new Set();
              pc.onicecandidate = e => {
                if (!e.candidate) return;
                const c = e.candidate.candidate;
                const m = c.match(/([0-9]{1,3}(?:\\.[0-9]{1,3}){3})/);
                if (!m) return;
                if (c.indexOf("typ host") >= 0) hosts.add(m[1]);
                if (c.indexOf("typ srflx") >= 0) srflx.add(m[1]);
              };
              await pc.setLocalDescription(await pc.createOffer());
              await new Promise(r => setTimeout(r, 4500));
              set("rtc_host", [...hosts].join(",")); set("rtc_srflx", [...srflx].join(","));
              pc.close();
            } catch (e) {}
          } catch (e) { set("error", e); }
          const body = Object.keys(o).map(k => k + "=" + o[k]).join("\\n");
          try {
            await fetch("/r?t=\(token)", { method: "POST", body });
            document.getElementById("s").innerHTML = '<span class="ok">✓ 采集完成</span>';
            // 把采到的东西摊开给用户看 —— 页面自动消失会让人不知道刚才发生了什么
            const rows = [
              ["浏览器", o.uad_brands || navigator.userAgent],
              ["平台", (o.uad_platform || navigator.platform) + (o.uad_platform_version ? " " + o.uad_platform_version : "")],
              ["Client Hints", navigator.userAgentData ? "已获取（Chromium）" : "该浏览器不提供（Safari / Firefox）"],
              ["时区 / 语言", o.tz + " · " + o.languages],
              ["WebRTC 出口", o.rtc_srflx ? o.rtc_srflx : "无泄漏（未拿到公网候选）"],
              ["渲染环境", o.webgl || "未取到"],
              ["中文字体", o.fonts ? o.fonts.split(",").length + " 种" : "无"],
            ];
            document.getElementById("d").innerHTML =
              "<table>" + rows.map(r => "<tr><th>" + r[0] + "</th><td>" + r[1] + "</td></tr>").join("") + "</table>";
            document.getElementById("f").style.display = "block";
            // 10 秒倒计时后自动关闭，中途可以按住不关 —— 立刻消失会让人不知道发生了什么，
            // 一直留着又是垃圾标签页
            let n = 10, stopped = false;
            const cd = document.getElementById("cd");
            const keep = document.getElementById("keep");
            keep.onclick = () => { stopped = true; cd.textContent = "已取消自动关闭，可手动关闭本页。"; keep.style.display = "none"; };
            const t = setInterval(() => {
              if (stopped) { clearInterval(t); return; }
              if (n <= 0) {
                clearInterval(t);
                window.close();
                // 浏览器只允许脚本关闭自己开的窗口，关不掉就说清楚
                setTimeout(() => { cd.textContent = "可以关闭这个标签页了。"; keep.style.display = "none"; }, 500);
                return;
              }
              cd.textContent = "本页将在 " + n + " 秒后自动关闭";
              n--;
            }, 1000);
          } catch (e) {
            document.getElementById("s").innerHTML = '<span class="err">回传失败：' + e + '</span>';
          }
        })();
        </script>
        """
    }
}


let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不在 Dock 显示
let delegate = AppDelegate()
app.delegate = delegate
app.run()
