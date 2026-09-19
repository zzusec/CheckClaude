import Foundation
import Network

// CheckClaude · Codex 防降智守护进程
//
// 原理参考 https://github.com/tzf1003/csss （Surge 脚本版）：
// Codex 请求里的 x-codex-turn-state 表示"这一轮从哪个状态续上"。新会话没有它，
// 每次都从冷状态开始；把一个仍在有效期内的 state 跨会话复用，可以让请求参数保持一致。
// csss 靠 Surge MITM 改写流量，这里改成不依赖任何代理软件：
// 起一个本机反代，codex 的 chatgpt_base_url 指过来，由它采集/缓存/注入 state。
//
// 只处理本机流量，state 只留在内存 + 指纹落盘，不上传、不记录提示词与回答。

let dataDir: String = ProcessInfo.processInfo.environment["AUTO_TZ_DIR"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/CheckClaude")
let statusFile = (dataDir as NSString).appendingPathComponent("codex_guard_status")
// 开关默认打开：只有用户显式关闭时才落这个文件
let offSwitch = (dataDir as NSString).appendingPathComponent("codex_guard_off")
let upstream = ProcessInfo.processInfo.environment["CODEX_GUARD_UPSTREAM"] ?? "https://chatgpt.com/backend-api"
let listenPort = UInt16(ProcessInfo.processInfo.environment["CODEX_GUARD_PORT"] ?? "") ?? 8788
let wantBlocks = 10          // 合格 state 固定 10 块（292 字符），不足视为不可用
let stateTTL: Double = 3600  // 服务端有效期经验值
let renewAhead: Double = 600 // 剩 10 分钟提前续，避免真实请求撞到过期

func now() -> Double { Date().timeIntervalSince1970 }
func injectEnabled() -> Bool { !FileManager.default.fileExists(atPath: offSwitch) }

// MARK: - state 解析

/// base64url → 字节；非法字符返回 nil。10 块的 state 编码出来带 "==" 收尾（292 字符），先剥掉
func decodeStateBytes(_ raw: String) -> [UInt8]? {
    var value = raw
    var padding = 0
    while value.hasSuffix("=") { value.removeLast(); padding += 1 }
    guard padding <= 2, value.count % 4 != 1 else { return nil }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    var index: [Character: Int] = [:]
    for (i, c) in alphabet.enumerated() { index[c] = i }
    var bytes: [UInt8] = []
    var acc = 0, bits = 0
    for ch in value {
        guard let digit = index[ch] else { return nil }
        acc = acc << 6 | digit
        bits += 6
        if bits >= 8 {
            bits -= 8
            bytes.append(UInt8((acc >> bits) & 0xff))
            acc &= (1 << bits) - 1
        }
    }
    return acc == 0 ? bytes : nil
}

struct TurnState {
    let value: String
    let issuedAt: Double
    let blocks: Int
    var fingerprint: String {
        var hash: UInt32 = 2166136261
        for b in Array(value.utf8) { hash = (hash ^ UInt32(b)) &* 16777619 }
        return String(format: "%08x", hash)
    }
    var expiresAt: Double { issuedAt + stateTTL - 30 }
    var renewAt: Double { issuedAt + stateTTL - renewAhead }
}

/// 结构校验：0x80 开头 + 10 块 + 签发时间合理，任何一项不符都不缓存
func parseState(_ raw: String) -> TurnState? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bytes = decodeStateBytes(value), bytes.count >= 73,
          bytes[0] == 0x80, (bytes.count - 57) % 16 == 0 else { return nil }
    var issued: Double = 0
    for i in 1..<9 { issued = issued * 256 + Double(bytes[i]) }
    guard issued > 1_577_836_800, issued < 4_102_444_800 else { return nil }
    let state = TurnState(value: value, issuedAt: issued, blocks: (bytes.count - 57) / 16)
    guard state.blocks == wantBlocks, state.expiresAt > now() else { return nil }
    return state
}

// MARK: - 缓存

/// state 与探针凭据都只活在这个进程的内存里；落盘的只有计数和指纹
final class Store {
    static let shared = Store()
    private let q = DispatchQueue(label: "codex-guard.store")
    private var entry: TurnState?
    private var probeHeaders: [String: String] = [:]   // 仅内存，进程退出即丢
    private var probing = false
    private var cooldownUntil: Double = 0
    private var injected = 0, captured = 0, requests = 0
    private(set) var lastProbe = "-"

    func current() -> TurnState? {
        q.sync { (entry?.expiresAt ?? 0) > now() ? entry : nil }
    }

    func capture(_ raw: String) {
        guard let state = parseState(raw) else { return }
        q.sync {
            if state.fingerprint == entry?.fingerprint { return }
            entry = state
            captured += 1
        }
        writeStatus()
    }

    func countRequest(injected didInject: Bool) {
        q.sync {
            requests += 1
            if didInject { injected += 1 }
        }
        writeStatus()
    }

    func rememberProbeHeaders(_ headers: [String: String]) {
        q.sync { probeHeaders = headers }
    }

    /// 缓存为空或快过期时补一针，避免真实请求裸奔
    func maybeProbe() {
        let job: [String: String]? = q.sync {
            guard injectEnabled(), !probing, now() > cooldownUntil, !probeHeaders.isEmpty else { return nil }
            if let e = entry, now() < e.renewAt { return nil }
            probing = true
            return probeHeaders
        }
        guard let headers = job else { return }
        probe(headers) { [weak self] ok, note, retryAfter in
            guard let self else { return }
            self.q.sync {
                self.probing = false
                self.lastProbe = note
                if !ok { self.cooldownUntil = now() + max(120, retryAfter) }
            }
            self.writeStatus()
        }
    }

    func snapshot() -> [String: String] {
        q.sync {
            var d = [
                "enabled": injectEnabled() ? "1" : "0",
                "port": String(listenPort),
                "requests": String(requests),
                "injected": String(injected),
                "captured": String(captured),
                "probe": lastProbe,
                "updated": String(Int(now())),
            ]
            if let e = entry, e.expiresAt > now() {
                d["state"] = "ready"
                d["fingerprint"] = e.fingerprint
                d["blocks"] = String(e.blocks)
                d["expires"] = String(Int(e.expiresAt))   // 绝对时间，读的人自己算剩余
            } else {
                d["state"] = "waiting"
            }
            return d
        }
    }

    func writeStatus() {
        let text = snapshot().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        try? (text + "\n").write(toFile: statusFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - 探针

let probeSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 120
    return URLSession(configuration: c)
}()

/// 用上一条真实请求的凭据发一条极短的请求，只为把新的 state 带回来
func probe(_ headers: [String: String], done: @escaping (Bool, String, Double) -> Void) {
    guard let url = URL(string: upstream + "/codex/responses") else { return done(false, "地址无效", 0) }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue("text/event-stream", forHTTPHeaderField: "accept")
    req.setValue("1", forHTTPHeaderField: "x-codex-state-probe")
    let body: [String: Any] = [
        "model": headers["x-codex-model"] ?? "gpt-6-astra",
        "instructions": "Reply with OK.",
        "input": [["type": "message", "role": "user",
                   "content": [["type": "input_text", "text": "Reply with OK."]]]],
        "stream": true, "store": false,
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    probeSession.dataTask(with: req) { data, response, error in
        guard let http = response as? HTTPURLResponse else {
            return done(false, "失败 " + (error?.localizedDescription ?? "无响应"), 0)
        }
        let retryAfter = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? 0
        guard http.statusCode == 200 else { return done(false, "HTTP \(http.statusCode)", retryAfter) }
        let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
        guard text.contains("response.completed") else { return done(false, "响应不完整", 0) }
        guard let raw = http.value(forHTTPHeaderField: "x-codex-turn-state"), parseState(raw) != nil else {
            return done(false, "未拿到合格 state", 0)
        }
        Store.shared.capture(raw)
        done(true, "已采集 " + fmtTime(), 0)
    }.resume()
}

func fmtTime() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: Date())
}

// MARK: - 反代

let relaySession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 900      // SSE 长连接，别被默认 60s 掐断
    c.timeoutIntervalForResource = 3600
    return URLSession(configuration: c)
}()

/// 逐条转发：请求进来注入 state，响应流式写回并顺手采集新 state
final class Relay: NSObject, URLSessionDataDelegate {
    private let conn: NWConnection
    private var sentHeader = false
    private var task: URLSessionDataTask?

    init(conn: NWConnection) { self.conn = conn }

    func start(method: String, path: String, headers: [(String, String)], body: Data) {
        guard let url = URL(string: upstream + path) else { return fail(502, "bad path") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body.isEmpty ? nil : body
        var passthrough: [String: String] = [:]
        for (k, v) in headers {
            let key = k.lowercased()
            // host/连接控制交给 URLSession；state 由我们自己决定
            if ["host", "connection", "content-length", "accept-encoding",
                "proxy-connection", "x-codex-turn-state"].contains(key) { continue }
            req.setValue(v, forHTTPHeaderField: k)
            passthrough[key] = v
        }
        var didInject = false
        if injectEnabled(), let state = Store.shared.current() {
            req.setValue(state.value, forHTTPHeaderField: "x-codex-turn-state")
            didInject = true
        }
        // 留一份凭据给续期探针（不含 cookie、不落盘）
        let keep = ["authorization", "chatgpt-account-id", "originator", "user-agent",
                    "version", "openai-beta", "x-codex-installation-id", "x-codex-model"]
        let creds = passthrough.filter { keep.contains($0.key) }
        if creds["authorization"] != nil { Store.shared.rememberProbeHeaders(creds) }
        Store.shared.countRequest(injected: didInject)

        let session = URLSession(configuration: relaySession.configuration, delegate: self, delegateQueue: nil)
        task = session.dataTask(with: req)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        if let raw = http.value(forHTTPHeaderField: "x-codex-turn-state") { Store.shared.capture(raw) }
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        for (k, v) in http.allHeaderFields {
            let key = String(describing: k).lowercased()
            // URLSession 已经解过压、长度也变了，这几个头不能原样转
            if ["content-length", "content-encoding", "transfer-encoding", "connection"].contains(key) { continue }
            head += "\(k): \(v)\r\n"
        }
        // ponytail: 不带 Content-Length，用关连接表示结束，省掉 chunked 编码；
        // 代价是不能复用连接，codex 每轮一条 TCP，这点开销无所谓。
        head += "Connection: close\r\n\r\n"
        sentHeader = true
        send(Data(head.utf8))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        send(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !sentHeader {
            return fail(502, "upstream: \(error.localizedDescription)")
        }
        conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in self.conn.cancel() })
        session.invalidateAndCancel()
        Store.shared.maybeProbe()
    }

    private func send(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func fail(_ code: Int, _ msg: String) {
        let body = Data(msg.utf8)
        let head = "HTTP/1.1 \(code) Bad Gateway\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(Data(head.utf8) + body)
        conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in self.conn.cancel() })
    }
}

/// 只认 Content-Length 的最小 HTTP/1.1 请求解析；codex 的请求体都是定长 JSON
func handle(_ conn: NWConnection) {
    var buffer = Data()
    func pump() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isDone, error in
            if let data { buffer.append(data) }
            if error != nil { return conn.cancel() }
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isDone { conn.cancel() } else { pump() }
                return
            }
            let headText = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
            var lines = headText.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
            guard requestLine.count >= 2 else { return conn.cancel() }
            var headers: [(String, String)] = []
            var contentLength = 0
            for line in lines {
                guard let sep = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<sep])
                let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                headers.append((key, value))
                if key.lowercased() == "content-length" { contentLength = Int(value) ?? 0 }
            }
            let bodyStart = headEnd.upperBound
            if buffer.count - bodyStart < contentLength {
                if isDone { conn.cancel() } else { pump() }
                return
            }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            Relay(conn: conn).start(method: requestLine[0], path: requestLine[1], headers: headers, body: body)
        }
    }
    pump()
}

// MARK: - 启动

let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!)
guard let listener = try? NWListener(using: params) else {
    FileHandle.standardError.write(Data("端口 \(listenPort) 无法监听\n".utf8))
    exit(1)
}
listener.newConnectionHandler = { conn in
    conn.start(queue: .global())
    handle(conn)
}
listener.stateUpdateHandler = { state in
    if case .failed = state {
        FileHandle.standardError.write(Data("监听失败，端口 \(listenPort) 可能被占用\n".utf8))
        exit(1)
    }
}
listener.start(queue: .main)
Store.shared.writeStatus()
// 探针只有拿到过一次真实凭据才有意义，所以挂在请求之后，这里只做定时兜底续期
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in Store.shared.maybeProbe() }
RunLoop.main.run()
