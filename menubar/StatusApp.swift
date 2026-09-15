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
let claudeProbeStatePath = (baseDir as NSString).appendingPathComponent("claude_probe_state")
let browserPath = (baseDir as NSString).appendingPathComponent("browser_signals")
let logPath = (baseDir as NSString).appendingPathComponent("auto-timezone.log")
let networkHistoryPath = (baseDir as NSString).appendingPathComponent("network_history")
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

struct NetworkHistoryPoint {
    let timestamp: TimeInterval
    let totalSeconds: Double
    let result: String
    let ip: String
    let ipChanged: Bool
    let cnSeconds: Double
    let cnOK: Bool
    let intlSeconds: Double
    let intlOK: Bool
    let gfwSeconds: Double
    let gfwOK: Bool
    let googleSeconds: Double
    let googleOK: Bool

    func seconds(for route: NetworkRoute) -> Double {
        switch route {
        case .cn: return cnSeconds
        case .intl: return intlSeconds
        case .gfw: return gfwSeconds
        case .google: return googleSeconds
        }
    }

    func succeeded(_ route: NetworkRoute) -> Bool {
        switch route {
        case .cn: return cnOK
        case .intl: return intlOK
        case .gfw: return gfwOK
        case .google: return googleOK
        }
    }
}

enum NetworkRoute: CaseIterable {
    case cn, intl, gfw, google

    var title: String {
        switch self {
        case .cn: return "国内"
        case .intl: return "国外"
        case .gfw: return "谷歌侧"
        case .google: return "Google"
        }
    }

    var color: NSColor {
        switch self {
        case .cn: return .systemBlue
        case .intl: return .systemTeal
        case .gfw: return .systemPurple
        case .google: return .systemGreen
        }
    }
}

// NSMenu 没有原生图表控件，用一个只读 NSView 画四路小趋势图。
// 每一路独立折线，能直接看出是国内、国外、谷歌侧还是 Google 连通性在失败。
final class NetworkHistoryView: NSView {
    private let points: [NetworkHistoryPoint]

    init(points: [NetworkHistoryPoint]) {
        self.points = points
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 350, height: 116)))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilitySummary())
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private func accessibilitySummary() -> String {
        guard !points.isEmpty else { return "网络波动图，暂无历史数据" }
        let routeText = NetworkRoute.allCases.map { route in
            let failures = points.filter { !$0.succeeded(route) }.count
            return "\(route.title)失败\(failures)次"
        }.joined(separator: "，")
        let changes = points.filter(\.ipChanged).count
        return "最近\(points.count)次网络检测，\(routeText)，确认换IP\(changes)次"
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        let noteFont = NSFont.systemFont(ofSize: 9)
        drawText("最近 \(points.count) 次分路趋势", at: NSPoint(x: 8, y: 5),
                 font: titleFont, color: .labelColor)

        guard !points.isEmpty else {
            drawText("暂无历史数据，完成一次出口检测后显示", at: NSPoint(x: 52, y: bounds.midY - 7),
                     font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
            return
        }

        let left: CGFloat = 54
        let right: CGFloat = 10
        let top: CGFloat = 24
        let rowHeight: CGFloat = 18.5
        let plotWidth = max(1, bounds.width - left - right)
        let plotBottom = top + rowHeight * CGFloat(NetworkRoute.allCases.count)

        func xPosition(_ index: Int) -> CGFloat {
            guard points.count > 1 else { return left + plotWidth }
            return left + CGFloat(index) * plotWidth / CGFloat(points.count - 1)
        }

        // 已确认的换 IP 用贯穿四路的红线标记，和单路接口失败区分开。
        NSColor.systemRed.withAlphaComponent(0.55).setStroke()
        for (index, point) in points.enumerated() where point.ipChanged {
            let x = xPosition(index)
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: x, y: top))
            marker.line(to: NSPoint(x: x, y: plotBottom))
            marker.lineWidth = 1.2
            marker.stroke()
        }

        for (routeIndex, route) in NetworkRoute.allCases.enumerated() {
            let rowTop = top + CGFloat(routeIndex) * rowHeight
            let rowBottom = rowTop + rowHeight - 4
            let baseline = NSBezierPath()
            baseline.move(to: NSPoint(x: left, y: rowBottom))
            baseline.line(to: NSPoint(x: left + plotWidth, y: rowBottom))
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            baseline.lineWidth = 0.5
            baseline.stroke()

            drawText(route.title, at: NSPoint(x: 8, y: rowTop + 3), font: labelFont, color: route.color)

            let successfulDurations = points.filter { $0.succeeded(route) }.map { max(0.5, $0.seconds(for: route)) }.sorted()
            let percentileIndex = max(0, Int(Double(max(0, successfulDurations.count - 1)) * 0.95))
            let p95 = successfulDurations.isEmpty ? 1 : successfulDurations[percentileIndex]
            let maxScale = max(1, p95 * 1.25)
            let amplitude = max(3, rowHeight - 8)
            let path = NSBezierPath()
            var previousSucceeded = false

            for (index, point) in points.enumerated() {
                let x = xPosition(index)
                if point.succeeded(route) {
                    let value = min(maxScale, max(0.5, point.seconds(for: route)))
                    let y = rowBottom - CGFloat(value / maxScale) * amplitude
                    if previousSucceeded { path.line(to: NSPoint(x: x, y: y)) }
                    else { path.move(to: NSPoint(x: x, y: y)) }
                    let dot = NSBezierPath(ovalIn: NSRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
                    route.color.setFill()
                    dot.fill()
                    previousSucceeded = true
                } else {
                    previousSucceeded = false
                    let dot = NSBezierPath(ovalIn: NSRect(x: x - 2.2, y: rowBottom - amplitude / 2 - 2.2, width: 4.4, height: 4.4))
                    NSColor.systemOrange.setFill()
                    dot.fill()
                }
            }
            route.color.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1.25
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }

        drawText("折线=耗时   橙点=该路失败   红线=已确认换 IP",
                 at: NSPoint(x: left, y: plotBottom + 3), font: noteFont, color: .secondaryLabelColor)
    }
}

// 非模态新版提示：不抢走当前窗口焦点，用户可直接在线更新并自动重启。
// 视觉层级参考桌面软件常见的右下角更新卡片，但保持 macOS 原生材质和控件行为。
final class UpdateToastController: NSObject {
    private var panel: NSPanel!
    private let onUpgrade: () -> Void
    private let onDismiss: () -> Void

    init(current: String, latest: String, onUpgrade: @escaping () -> Void,
         onDismiss: @escaping () -> Void) {
        self.onUpgrade = onUpgrade
        self.onDismiss = onDismiss
        super.init()

        let size = NSSize(width: 360, height: 112)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        panel = p

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("发现 CheckClaude 新版本 v\(latest)")
        p.contentView = root

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "arrow.up.circle.fill",
                             accessibilityDescription: "发现新版本")
        icon.contentTintColor = .systemGreen
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 23, weight: .medium)

        let title = NSTextField(labelWithString: "发现新版本 v\(latest)")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor

        let body = NSTextField(wrappingLabelWithString:
            "当前 v\(current)，在线安装后自动重启。")
        body.translatesAutoresizingMaskIntoConstraints = false
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 2

        let update = NSButton(title: "立即更新", target: self, action: #selector(upgradeNow))
        update.translatesAutoresizingMaskIntoConstraints = false
        update.bezelStyle = .rounded
        update.controlSize = .small
        update.contentTintColor = .systemGreen
        update.keyEquivalent = "\r"
        update.setAccessibilityLabel("立即更新到 v\(latest) 并重启 CheckClaude")

        let close = NSButton(image: NSImage(systemSymbolName: "xmark",
                                             accessibilityDescription: "关闭")!,
                             target: self, action: #selector(closeToast))
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.setAccessibilityLabel("稍后提醒")

        [icon, title, body, update, close].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),

            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -11),
            close.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 15),

            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            update.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            update.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 7),
            update.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            update.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        ])
    }

    func show() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // macOS 通知习惯位于右上角：贴近菜单栏下方，同时避开安全区域。
        let finalOrigin = NSPoint(x: visible.maxX - panel.frame.width - 22,
                                  y: visible.maxY - panel.frame.height - 14)
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + 14))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }
    }

    func dismiss() {
        guard panel.isVisible else { onDismiss(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.onDismiss()
        })
    }

    @objc private func upgradeNow() {
        panel.orderOut(nil)
        onDismiss()
        onUpgrade()
    }

    @objc private func closeToast() { dismiss() }
}

// 更新检查结果使用 App 自己的非模态提示，不依赖系统通知权限或专注模式。
final class FeedbackToastController: NSObject {
    private var panel: NSPanel!
    private var timer: Timer?
    private let onDismiss: () -> Void

    init(symbol: String, color: NSColor, titleText: String, bodyText: String,
         onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init()

        let size = NSSize(width: 360, height: 92)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        panel = p

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("\(titleText)。\(bodyText)")
        p.contentView = root

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: titleText)
        icon.contentTintColor = color
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)

        let title = NSTextField(labelWithString: titleText)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor

        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 2

        let close = NSButton(image: NSImage(systemSymbolName: "xmark",
                                             accessibilityDescription: "关闭")!,
                             target: self, action: #selector(closeToast))
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor

        [icon, title, body, close].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),

            close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -11),
            close.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5)
        ])
    }

    func show() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let finalOrigin = NSPoint(x: visible.maxX - panel.frame.width - 22,
                                  y: visible.maxY - panel.frame.height - 14)
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + 14))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        guard panel.isVisible else { onDismiss(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.onDismiss()
        })
    }

    @objc private func closeToast() { dismiss() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var uiTimer: Timer?
    var scanTimer: Timer?
    var scanProcess: Process?   // 同一时间只允许一个出口检测，避免旧结果覆盖新结果
    var lastExitIP = ""      // 出口 IP 变化时才重跑 Claude 环境体检
    var probe: BrowserProbe?
    var bridge: BrowserBridge?
    var phase: String?          // 非 nil = 正在检测(内部分两步，不暴露给用户)
    var updateTimer: Timer?
    var updateToast: UpdateToastController?
    var feedbackToast: FeedbackToastController?
    var feedbackToastToken = UUID()
    var isCheckingUpdate = false

    func applicationDidFinishLaunching(_ n: Notification) {
        // 上次升级若被 kickstart 打断，状态文件可能残留，启动时先清掉
        try? FileManager.default.removeItem(atPath: upgradeStatePath)
        item.menu = NSMenu()
        item.autosaveName = "CheckClaudeStatusItem"   // 记住用户 ⌘拖动后的位置，开机后不再回到刘海
        item.behavior = .removalAllowed
        refresh()
        notify("CheckClaude已启动", "图标在屏幕右上角菜单栏 🌐，点击查看出口IP与时区")
        runScript(["--once"], isScan: true) // 启动即检测一次
        // 每 30 秒读快照刷新显示
        uiTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // 定时主动检测(默认 1 分钟，可在菜单"检测间隔"调整)
        startScanTimer()
        // 版本检查: 启动时一次，之后每 2 小时。GitHub API 匿名限额 60 次/小时，这个频率很安全
        runScript(["--check"], upgradeScriptPath) { [weak self] _ in self?.refresh() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2 * 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.runScript(["--check"], upgradeScriptPath) { [weak self] _ in self?.refresh() }
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
            self?.runScript(["--once"], isScan: true)
        }
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag), forKey: "scanInterval")
        startScanTimer()
        refresh()
    }

    func runScript(_ args: [String], _ path: String = scriptPath, isScan: Bool = false,
                   then: ((Int32) -> Void)? = nil) {
        // 定时器、启动检测和“立即检测”可能同时触发。出口检测只保留一个进程；
        // shell 侧还有跨进程锁，防止 launchd 或其它入口与 App 竞争写状态。
        if isScan, scanProcess != nil { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path] + args
        var env = ProcessInfo.processInfo.environment
        env["AUTO_TZ_DIR"] = baseDir   // 与脚本共用同一数据目录
        p.environment = env
        if isScan { scanProcess = p }
        p.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                if isScan { self?.scanProcess = nil }
                self?.refresh()
                then?(process.terminationStatus)
            }
        }
        do {
            try p.run()
        } catch {
            if isScan { scanProcess = nil }
            refresh()
            then?(-1)
        }
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

    func readNetworkHistory() -> [NetworkHistoryPoint] {
        guard let txt = try? String(contentsOfFile: networkHistoryPath, encoding: .utf8) else { return [] }
        let now = Date().timeIntervalSince1970
        let cutoff = now - 24 * 3600
        return txt.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 13,
                  let timestamp = TimeInterval(f[0]), timestamp >= cutoff, timestamp <= now + 300,
                  let total = Double(f[1]),
                  let cnSeconds = Double(f[5]), let cnOK = Int(f[6]),
                  let intlSeconds = Double(f[7]), let intlOK = Int(f[8]),
                  let gfwSeconds = Double(f[9]), let gfwOK = Int(f[10]),
                  let googleSeconds = Double(f[11]), let googleOK = Int(f[12]) else { return nil }
            return NetworkHistoryPoint(timestamp: timestamp, totalSeconds: total, result: f[2], ip: f[3],
                                       ipChanged: f[4] == "1",
                                       cnSeconds: cnSeconds, cnOK: cnOK == 1,
                                       intlSeconds: intlSeconds, intlOK: intlOK == 1,
                                       gfwSeconds: gfwSeconds, gfwOK: gfwOK == 1,
                                       googleSeconds: googleSeconds, googleOK: googleOK == 1)
        }.sorted { $0.timestamp < $1.timestamp }
    }

    func refresh() {
        let s = readStatus()
        let consistent = s["consistent"] ?? ""
        let network = s["network"] ?? "ok"   // 旧版快照没有该字段，按稳定处理
        let history = readNetworkHistory()
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
        let cps = readStatus(claudeProbeStatePath)
        let claudeScore = Int(cs["score"] ?? "") ?? -1
        let scoreVerifying = cps["state"] == "verifying"
        let safe = claudeScore >= 90 && consistent == "1" && network == "ok"
        // 网络结果还在复核时不改变安全档位，也不发送“不可用/恢复”通知。
        if network == "ok" && !scoreVerifying {
            alertIfUnsafe(claudeScore, consistent: consistent, verdict: cs["verdict"] ?? "")
        }

        if let btn = item.button {
            // 综合判定: 安全=绿勾 / 有隐患=黄感叹号 / 不建议使用=红叉 / 无数据=灰问号
            let symName: String
            let color: NSColor
            if claudeScore < 0 && s.isEmpty { symName = "questionmark.circle"; color = .systemGray }
            else if network != "ok" { symName = "exclamationmark.triangle.fill"; color = .systemOrange }
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
        let head: String
        switch network {
        case "unstable": head = "出口探测接口波动 ⚠️"
        case "verifying": head = "出口探测结果复核中…"
        default: head = consistent == "1" ? "出口 IP 一致 ✅" : (s.isEmpty ? "尚无检测数据" : "出口 IP 异常 ⚠️")
        }
        if s.isEmpty {
            menu.addItem(disabled(head))
        } else if network != "ok" {
            menu.addItem(colored(head, .systemOrange))
        } else if consistent == "1" {
            menu.addItem(colored(head, .systemGreen))
        } else {
            menu.addItem(colored(head, .systemRed))
        }

        let failures = Int(s["failure_count"] ?? "0") ?? 0
        let confirmations = Int(s["confirm_count"] ?? "0") ?? 0
        let required = Int(s["confirm_required"] ?? "2") ?? 2
        let networkLine: String
        if network == "unstable" {
            networkLine = "探测状态: 接口波动（连续失败 \(failures) 次，沿用上次结果）"
        } else if network == "verifying", failures > 0 {
            networkLine = "探测状态: 单次接口波动（\(failures)/\(required)，沿用上次结果）"
        } else if network == "verifying" {
            networkLine = "出口状态: 正在复核（\(confirmations)/\(required)，沿用上次结果）"
        } else if s.isEmpty {
            networkLine = "探测状态: 尚未检测"
        } else {
            networkLine = "探测状态: 正常"
        }
        menu.addItem(disabled(networkLine))
        if let latest = history.last {
            let failedRoutes = NetworkRoute.allCases.filter { !latest.succeeded($0) }.map(\.title)
            if !failedRoutes.isEmpty {
                menu.addItem(disabled("波动位置: \(failedRoutes.joined(separator: "、"))"))
            } else if latest.result == "inconsistent" {
                menu.addItem(disabled("波动位置: 三路出口结果不一致"))
            }
        }
        menu.addItem(networkHistoryMenuItem(history))
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
        if scanProcess != nil {
            menu.addItem(disabled("正在检测出口…"))
        } else {
            menu.addItem(action("立即检测", #selector(runCheck)))
        }
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
            let versionState = u["checkok"] == "0" ? "更新状态未知" : "已是最新"
            menu.addItem(disabled("版本 v\(ver)（\(versionState)）"))
            menu.addItem(isCheckingUpdate
                ? disabled("正在检查更新…")
                : action("检查更新", #selector(checkUpdate)))
        }
        menu.addItem(.separator())
        menu.addItem(action("官方网站", #selector(openYinso)))
        menu.addItem(action("退出", #selector(quit)))
        item.menu = menu

        autoCheckIfExitChanged(s)
    }

    func networkHistoryMenuItem(_ history: [NetworkHistoryPoint]) -> NSMenuItem {
        let recent = Array(history.suffix(60))
        let title = history.isEmpty ? "网络波动图（暂无数据）" : "网络波动图（最近 \(recent.count) 次）"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let chartItem = NSMenuItem()
        chartItem.view = NetworkHistoryView(points: recent)
        submenu.addItem(chartItem)
        submenu.addItem(.separator())

        if history.isEmpty {
            submenu.addItem(disabled("24 小时内暂无检测记录"))
        } else {
            let changes = history.filter(\.ipChanged).count
            submenu.addItem(disabled("24 小时统计: \(history.count) 次检测 · 确认换 IP \(changes) 次"))
            for route in NetworkRoute.allCases {
                submenu.addItem(disabled(routeSummary(route, history: history)))
            }
        }
        item.submenu = submenu
        return item
    }

    func routeSummary(_ route: NetworkRoute, history: [NetworkHistoryPoint]) -> String {
        let successes = history.filter { $0.succeeded(route) }
        let failures = history.count - successes.count
        let rate = history.isEmpty ? 0 : Int((Double(successes.count) * 100 / Double(history.count)).rounded())
        let average = successes.isEmpty ? 0 : successes.reduce(0) { $0 + $1.seconds(for: route) } / Double(successes.count)
        let duration = successes.isEmpty ? "—" : (average < 1 ? "<1 秒" : String(format: "%.1f 秒", average))
        return "\(route.title): \(rate)% 成功 · 失败 \(failures) · 平均 \(duration)"
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
        guard (s["network"] ?? "ok") == "ok" else { return }
        let ip = s["gfw"] ?? ""
        guard !ip.isEmpty, ip != "?" else { return }
        if ip != lastExitIP {
            lastExitIP = ip
            fullCheck()
        }
    }

    // 先采浏览器指纹，再只运行一次完整评分。检测期间保留上次有效分数，
    // 不再把缺少浏览器信号的中间分数写进菜单并触发假告警。
    func fullCheck(_ args: [String] = ["--quiet"]) {
        guard phase == nil else { return }           // 正在检测就别叠加
        guard browserProbeEnabled else {
            phase = "系统检测"
            refresh()
            runScript(args, claudeScriptPath) { [weak self] _ in self?.phase = nil; self?.refresh() }
            return
        }
        phase = "浏览器指纹"
        refresh()
        bridge = BrowserBridge(outPath: browserPath) { [weak self] ok in
            guard let self else { return }
            self.bridge = nil
            if ok {
                self.phase = "系统检测"
                self.refresh()
                self.runScript(args, claudeScriptPath) { [weak self] _ in
                    self?.phase = nil
                    self?.refresh()
                }
            } else {
                self.fallbackWebView(args)
            }
        }
        bridge?.start()
    }

    // 真实浏览器没回传时的兜底: 用内置 WKWebView 采一份(拿不到 Client Hints，但总比没有强)
    func fallbackWebView(_ args: [String] = ["--quiet"]) {
        guard probe == nil else { phase = nil; refresh(); return }
        probe = BrowserProbe(outPath: browserPath) { [weak self] in
            guard let self else { return }
            self.probe = nil
            self.phase = "系统检测"
            self.refresh()
            self.runScript(args, claudeScriptPath) { [weak self] _ in
                self?.phase = nil
                self?.refresh()
            }
        }
        probe?.run()
    }

    // 隐藏开关，正常用户不需要知道体检内部分两步。真要关:
    //   defaults write com.example.checkclaude browserProbe -bool false
    var browserProbeEnabled: Bool {
        UserDefaults.standard.object(forKey: "browserProbe") as? Bool ?? true
    }

    func claudeMenuItem() -> NSMenuItem {
        let c = readStatus(claudeStatusPath)
        let probeState = readStatus(claudeProbeStatePath)
        let score = Int(c["score"] ?? "") ?? -1
        let grade = c["grade"] ?? ""
        let exitConsistent = c["consistent"] == "1"
        // 颜色必须和最终评级一致，不能再出现“🟢 85 分 · 风险”。
        // 只有 90+、评级优秀且三路出口一致才是绿色；确认风险直接红色。
        let isSafe = score >= 90 && grade == "优秀" && exitConsistent
        let isWarning = !isSafe && score >= 70 && grade == "有风险" && exitConsistent
        let dot = score < 0 ? "⚪️" : (isSafe ? "🟢" : (isWarning ? "🟠" : "🔴"))
        let riskColor: NSColor = isSafe ? .labelColor : (isWarning ? .systemOrange : .systemRed)
        // 提分详情在子菜单顶部，标题只报状态，不啰嗦
        let verifying = probeState["state"] == "verifying"
        let title = score < 0 ? "Claude 环境体检"
            : "Claude 环境 \(dot) \(score) 分 · \(verifying ? "复核中" : grade)"
        let unfit = score >= 0 && !isSafe
        let alertColor: NSColor = score < 0 ? .labelColor : riskColor

        let sub = NSMenu()
        if score < 0 {
            sub.addItem(disabled("尚未体检"))
        } else {
            if verifying {
                let candidate = probeState["candidate_score"] ?? "?"
                let count = probeState["failure_count"] ?? "1"
                let required = probeState["confirm_required"] ?? "2"
                sub.addItem(colored("探测波动：保留上次 \(score) 分", .systemOrange))
                sub.addItem(disabled("候选 \(candidate) 分 · 复核 \(count)/\(required)"))
                if let detail = probeState["detail"], !detail.isEmpty {
                    sub.addItem(disabled(detail))
                }
                sub.addItem(.separator())
            }
            sub.addItem(unfit ? colored(c["verdict"] ?? "", riskColor) : disabled(c["verdict"] ?? ""))

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
            sub.addItem(disabled("IP 情报: \(c["intelsources"] ?? "未采集")"))
            sub.addItem(disabled("系统: \(c["os"] ?? "?") · \(c["locale"] ?? "?") · \(c["proxymode"] ?? "?")"))
            sub.addItem(disabled("DNS: \(c["dns"] ?? "?") · claude.ai → \(c["dnsresult"] ?? "?")"))
            sub.addItem(disabled("CLI: \(c["claudever"] ?? "?") · 接口 \(c["base"] ?? "?")"))
            func reach(_ key: String, _ msKey: String) -> String {
                let status = c[key] ?? "未采集"
                if status == "ok", let ms = c[msKey], !ms.isEmpty { return "✓ \(ms)ms" }
                if status == "ok" { return "✓" }
                if status == "timeout" { return "超时" }
                if status == "error" { return "异常" }
                return "未采集"
            }
            sub.addItem(disabled("浏览器访问: Claude \(reach("brclaude", "brclaudems")) · 官网 \(reach("branthropic", "branthropicms")) · API \(reach("brapi", "brapims"))"))
            let rtcStatus: String = {
                switch c["brrtcstatus"] ?? "未采集" {
                case "ok": return "完成"
                case "none": return "完成，无公网候选"
                case "timeout": return "超时"
                case "error": return "异常"
                case "unsupported": return "不支持或已禁用"
                default: return "未采集"
                }
            }()
            let rtcElapsed = (c["brrtcms"] ?? "").isEmpty ? "" : " · \(c["brrtcms"]!)ms"
            sub.addItem(disabled("WebRTC 探测: \(rtcStatus) · 候选 \(c["brrtccandidates"] ?? "0") · 公网 \(c["brrtcpublic"] ?? "0")\(rtcElapsed)"))
            let headerState: String
            switch c["brheaders"] ?? "unknown" {
            case "ok": headerState = "✓ 一致"
            case "conflict": headerState = "⚠ 冲突"
            case "partial": headerState = "部分采集"
            default: headerState = "未采集"
            }
            sub.addItem(disabled("浏览器请求头: \(headerState) · Sec-Fetch \(c["brfetch"] ?? "?")"))
            let issues = (c["issues"] ?? "").split(separator: "|").map(String.init)
            let fixes = (c["fixes"] ?? "").split(separator: "|").map(String.init)
            if !issues.isEmpty {
                sub.addItem(.separator())
                issues.forEach { sub.addItem(unfit ? colored("⚠️  \($0)", riskColor) : disabled("⚠️  \($0)")) }
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
        updateToast?.dismiss()
        try? "启动中".write(toFile: upgradeStatePath, atomically: true, encoding: .utf8)
        upgradeTimer?.invalidate()
        upgradeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        runScript(["--install"], upgradeScriptPath) { [weak self] _ in
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

    @objc func runCheck() { runScript(["--once"], isScan: true) }

    // 发现新版时主动显示右下角非模态提示，不抢当前窗口焦点；每天最多提醒一次。
    func presentUpdateToast(_ latest: String, throttled: Bool) {
        let defaults = UserDefaults.standard
        let key = "notifiedVersion", timestampKey = "notifiedAt"
        if throttled {
            let sameVersion = defaults.string(forKey: key) == latest
            let elapsed = Date().timeIntervalSince1970 - defaults.double(forKey: timestampKey)
            guard !sameVersion || elapsed > 86400 else { return }
        }
        guard updateToast == nil else { return }

        defaults.set(latest, forKey: key)
        defaults.set(Date().timeIntervalSince1970, forKey: timestampKey)
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let toast = UpdateToastController(current: current, latest: latest,
            onUpgrade: { [weak self] in self?.startUpgrade() },
            onDismiss: { [weak self] in self?.updateToast = nil })
        updateToast = toast
        toast.show()
    }

    func notifyNewVersion(_ latest: String) {
        DispatchQueue.main.async { [weak self] in
            self?.presentUpdateToast(latest, throttled: true)
        }
    }

    func presentFeedback(symbol: String, color: NSColor, title: String, body: String) {
        feedbackToast?.dismiss()
        let token = UUID()
        feedbackToastToken = token
        let toast = FeedbackToastController(symbol: symbol, color: color,
            titleText: title, bodyText: body,
            onDismiss: { [weak self] in
                guard let self, self.feedbackToastToken == token else { return }
                self.feedbackToast = nil
            })
        feedbackToast = toast
        toast.show()
    }

    @objc func checkUpdate() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        let startedAt = Int(Date().timeIntervalSince1970)
        refresh()
        runScript(["--check"], upgradeScriptPath) { [weak self] exitCode in
            guard let self else { return }
            self.isCheckingUpdate = false
            let u = self.readStatus(updatePath)
            let checkedAt = Int(u["checkedat"] ?? "") ?? 0
            if exitCode != 0 || u["checkok"] != "1" || checkedAt < startedAt {
                self.presentFeedback(symbol: "wifi.exclamationmark", color: .systemOrange,
                    title: "检查更新失败",
                    body: u["error"] ?? "无法连接 GitHub，请检查网络后重试。")
            } else if u["hasupdate"] == "1", let l = u["latest"] {
                self.presentUpdateToast(l, throttled: false)
            } else {
                let current = u["current"] ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                self.presentFeedback(symbol: "checkmark.circle.fill", color: .systemGreen,
                    title: "已经是最新版本", body: "当前版本 v\(current)。")
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

    // v4.3 及更早版本把 LaunchAgent 配成 KeepAlive，正常退出也会被 launchd 立即拉起。
    // 退出前先把磁盘配置迁移成“仅登录时启动”，再由独立 helper 卸载仍在内存里的旧任务。
    func prepareLaunchAgentForRealQuit() {
        let fm = FileManager.default
        let launchAgents = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let currentLabel = "com.example.checkclaude"
        let legacyLabel = "com.hx10.checkclaude"
        let currentPlist = launchAgents.appendingPathComponent("\(currentLabel).plist")
        let legacyPlist = launchAgents.appendingPathComponent("\(legacyLabel).plist")
        guard fm.fileExists(atPath: currentPlist.path) || fm.fileExists(atPath: legacyPlist.path) else { return }

        try? fm.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let executable = Bundle.main.executablePath
            ?? "/Applications/CheckClaude.app/Contents/MacOS/CheckClaude"
        let plist: [String: Any] = [
            "Label": currentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                           format: .xml, options: 0) {
            do {
                try data.write(to: currentPlist, options: .atomic)
                try? fm.removeItem(at: legacyPlist)
            } catch {
                return
            }
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = ["-c", """
            sleep 0.25
            launchctl bootout gui/\(getuid())/\(legacyLabel) 2>/dev/null || true
            launchctl bootout gui/\(getuid())/\(currentLabel) 2>/dev/null || true
            """]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try? helper.run()
    }

    @objc func quit() {
        prepareLaunchAgentForRealQuit()
        NSApp.terminate(nil)
    }
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
            let rtc = String(describing: self.collected["rtc_status"] ?? "")
            if rtc.isEmpty || rtc == "collecting" { self.collected["rtc_status"] = "timeout" }
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
        out.source = 'webview';
        out.ua_js = navigator.userAgent || '';
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

        send('sync');   // 同步信号先落盘，网络探测或 WebRTC 慢时也不会连累它们

        // ── 浏览器侧 Claude 服务可达性 ──
        // shell curl 和真实浏览器可能走不同的 PAC/扩展代理；这里只判断传输路径能否完成，
        // no-cors 看不到 401/403，不能替代 shell 侧的地区拦截判定。
        const reachOne = async (key, url) => {
          const started = performance.now(), ctl = new AbortController();
          const timer = setTimeout(() => ctl.abort(), 3500);
          try {
            await fetch(url, { mode: 'no-cors', cache: 'no-store', signal: ctl.signal });
            out['reach_' + key] = 'ok';
            out['reach_' + key + '_ms'] = String(Math.round(performance.now() - started));
          } catch (e) {
            out['reach_' + key] = e && e.name === 'AbortError' ? 'timeout' : 'error';
            out['reach_' + key + '_ms'] = '';
          } finally { clearTimeout(timer); }
        };
        const reachPromise = Promise.all([
          reachOne('claude', 'https://claude.ai/'),
          reachOne('anthropic', 'https://www.anthropic.com/'),
          reachOne('api', 'https://api.anthropic.com/')
        ]);

        // ── WebRTC 泄漏: 明确区分无泄漏、超时、异常和不支持 ──
        out.rtc_host = ''; out.rtc_srflx = ''; out.rtc_candidate_count = '0';
        out.rtc_public_count = '0'; out.rtc_supported = '0'; out.rtc_status = 'unsupported';
        if ('RTCPeerConnection' in window) {
          out.rtc_supported = '1'; out.rtc_status = 'collecting';
          const rtcStarted = performance.now();
          try {
            const pc = new RTCPeerConnection({ iceServers: [
              { urls: 'stun:stun.cloudflare.com:3478' },
              { urls: 'stun:stun.l.google.com:19302' }
            ]});
            pc.createDataChannel('probe');
            const hosts = new Set(), srflx = new Set();
            let candidates = 0, completed = false, finishGathering;
            const gathered = new Promise(r => { finishGathering = r; });
            pc.onicecandidate = e => {
              if (!e.candidate) { completed = true; finishGathering(); return; }
              candidates += 1;
              const c = e.candidate.candidate;
              const m = c.match(/([0-9]{1,3}(?:\\.[0-9]{1,3}){3})/);
              if (!m) return;
              if (c.indexOf('typ host') >= 0) hosts.add(m[1]);
              if (c.indexOf('typ srflx') >= 0) srflx.add(m[1]);
            };
            pc.onicegatheringstatechange = () => {
              if (pc.iceGatheringState === 'complete') { completed = true; finishGathering(); }
            };
            await pc.setLocalDescription(await pc.createOffer());
            await Promise.race([gathered, new Promise(r => setTimeout(r, 4500))]);
            out.rtc_host = [...hosts].join(',');
            out.rtc_srflx = [...srflx].join(',');
            out.rtc_candidate_count = String(candidates);
            out.rtc_public_count = String(srflx.size);
            out.rtc_elapsed_ms = String(Math.round(performance.now() - rtcStarted));
            out.rtc_status = srflx.size > 0 ? 'ok' : (completed ? 'none' : 'timeout');
            pc.close();
          } catch (e) {
            out.rtc_status = 'error';
            out.rtc_elapsed_ms = String(Math.round(performance.now() - rtcStarted));
            out.rtc_err = String(e).slice(0, 60);
          }
        }
        await reachPromise;
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
            set("ua_js", navigator.userAgent || "");
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
            // 浏览器侧 Claude 服务可达性：和 WebRTC 并行，避免额外延长体检。
            const reachOne = async (key, url) => {
              const started = performance.now(), ctl = new AbortController();
              const timer = setTimeout(() => ctl.abort(), 3500);
              try {
                await fetch(url, { mode: "no-cors", cache: "no-store", signal: ctl.signal });
                set("reach_" + key, "ok");
                set("reach_" + key + "_ms", Math.round(performance.now() - started));
              } catch (e) {
                set("reach_" + key, e && e.name === "AbortError" ? "timeout" : "error");
                set("reach_" + key + "_ms", "");
              } finally { clearTimeout(timer); }
            };
            const reachPromise = Promise.all([
              reachOne("claude", "https://claude.ai/"),
              reachOne("anthropic", "https://www.anthropic.com/"),
              reachOne("api", "https://api.anthropic.com/")
            ]);
            // WebRTC: 明确区分无泄漏、超时、异常和不支持
            set("rtc_host", ""); set("rtc_srflx", ""); set("rtc_candidate_count", 0);
            set("rtc_public_count", 0); set("rtc_supported", 0); set("rtc_status", "unsupported");
            if ("RTCPeerConnection" in window) {
              set("rtc_supported", 1); set("rtc_status", "collecting");
              const rtcStarted = performance.now();
              try {
                const pc = new RTCPeerConnection({ iceServers: [
                  { urls: "stun:stun.cloudflare.com:3478" }, { urls: "stun:stun.l.google.com:19302" }] });
                pc.createDataChannel("p");
                const hosts = new Set(), srflx = new Set();
                let candidates = 0, completed = false, finishGathering;
                const gathered = new Promise(r => { finishGathering = r; });
                pc.onicecandidate = e => {
                  if (!e.candidate) { completed = true; finishGathering(); return; }
                  candidates += 1;
                  const c = e.candidate.candidate;
                  const m = c.match(/([0-9]{1,3}(?:\\.[0-9]{1,3}){3})/);
                  if (!m) return;
                  if (c.indexOf("typ host") >= 0) hosts.add(m[1]);
                  if (c.indexOf("typ srflx") >= 0) srflx.add(m[1]);
                };
                pc.onicegatheringstatechange = () => {
                  if (pc.iceGatheringState === "complete") { completed = true; finishGathering(); }
                };
                await pc.setLocalDescription(await pc.createOffer());
                await Promise.race([gathered, new Promise(r => setTimeout(r, 4500))]);
                set("rtc_host", [...hosts].join(",")); set("rtc_srflx", [...srflx].join(","));
                set("rtc_candidate_count", candidates); set("rtc_public_count", srflx.size);
                set("rtc_elapsed_ms", Math.round(performance.now() - rtcStarted));
                set("rtc_status", srflx.size > 0 ? "ok" : (completed ? "none" : "timeout"));
                pc.close();
              } catch (e) {
                set("rtc_status", "error"); set("rtc_elapsed_ms", Math.round(performance.now() - rtcStarted));
                set("rtc_err", String(e).slice(0, 60));
              }
            }
            await reachPromise;
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
              ["WebRTC 出口", o.rtc_status === "ok" ? o.rtc_srflx : (o.rtc_status === "none" ? "检测完成，无公网候选" : "检测" + (o.rtc_status || "未知"))],
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
