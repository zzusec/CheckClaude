// CheckClaude for Windows —— 检查这台机器适不适合跑 Claude，能修的直接修。
// 与 macOS 版同一套评分模型(20 项加权信号，合计 100)，这里是 .NET Framework 4.8 实现：
// 用 csc.exe 编译，产物是单个 exe，不需要装任何运行时。
//
// 浏览器 4 项(WebRTC/Intl/渲染)在 Windows 版按中性 70% 计分——csc 单文件带不了 WebView2 依赖，
// 和命令行单跑 macOS 版是同一口径，不假装测过。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace CheckClaude
{
    // ── 一条加权信号 ────────────────────────────────────────────
    class Signal
    {
        public string Group, Label, Value, Hint;
        public int Weight, Points;
        public bool Ok { get { return Points >= Weight; } }
    }

    static class Paths
    {
        public static readonly string Dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CheckClaude");
        public static string Log { get { return Path.Combine(Dir, "checkclaude.log"); } }
        public static string State { get { return Path.Combine(Dir, "last_state"); } }
        public static void Ensure() { try { Directory.CreateDirectory(Dir); } catch { } }
        public static void Write(string msg)
        {
            try
            {
                Ensure();
                // 日志会被"出口稳定性"逐行扫，超过 2MB 就只留最后 2000 行
                if (File.Exists(Log) && new FileInfo(Log).Length > 2 * 1024 * 1024)
                {
                    var keep = File.ReadAllLines(Log);
                    File.WriteAllLines(Log, keep.Skip(Math.Max(0, keep.Length - 2000)).ToArray());
                }
                File.AppendAllText(Log,
                    string.Format("[{0:yyyy-MM-dd HH:mm:ss}] {1}{2}", DateTime.Now, msg, Environment.NewLine));
            }
            catch { }
        }
    }

    static class Net
    {
        static Net()
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11;
            ServicePointManager.DefaultConnectionLimit = 16;
        }

        public static string Get(string url, int timeoutMs = 9000)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.UserAgent = "Mozilla/5.0 CheckClaude";
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var sr = new StreamReader(resp.GetResponseStream()))
                    return sr.ReadToEnd();
            }
            catch { return null; }
        }

        // 只要状态码，403/401 这类"失败"响应也算有效结果
        public static int Status(string url, string method = "GET", string body = null, int timeoutMs = 10000)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = method;
                req.Timeout = timeoutMs;
                req.UserAgent = "Mozilla/5.0 CheckClaude";
                if (body != null)
                {
                    req.ContentType = "application/json";
                    var b = Encoding.UTF8.GetBytes(body);
                    req.ContentLength = b.Length;
                    using (var s = req.GetRequestStream()) s.Write(b, 0, b.Length);
                }
                using (var resp = (HttpWebResponse)req.GetResponse()) return (int)resp.StatusCode;
            }
            catch (WebException we)
            {
                var r = we.Response as HttpWebResponse;
                return r != null ? (int)r.StatusCode : 0;
            }
            catch { return 0; }
        }

        public static string FirstIp(params string[] urls)
        {
            foreach (var u in urls)
            {
                var t = Get(u);
                if (t == null) continue;
                var m = Regex.Match(t, @"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b");
                if (m.Success) return m.Groups[1].Value;
            }
            return null;
        }

        public static string Json(string body, string key)
        {
            if (body == null) return null;
            var m = Regex.Match(body, "\"" + key + "\"\\s*:\\s*\"([^\"]*)\"");
            return m.Success ? m.Groups[1].Value : null;
        }
    }

    // ── IANA ↔ Windows 时区映射 ────────────────────────────────
    // .NET Framework 4.8 没有 TryConvertIanaIdToWindowsId(那是 .NET 6+)，
    // 常用地区手写一张表就够，查不到就按 UTC 偏移兜底。
    static class Tz
    {
        static readonly Dictionary<string, string> Map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            {"America/Los_Angeles","Pacific Standard Time"}, {"America/Vancouver","Pacific Standard Time"},
            {"America/Denver","Mountain Standard Time"},     {"America/Phoenix","US Mountain Standard Time"},
            {"America/Chicago","Central Standard Time"},     {"America/Mexico_City","Central Standard Time (Mexico)"},
            {"America/New_York","Eastern Standard Time"},    {"America/Toronto","Eastern Standard Time"},
            {"America/Sao_Paulo","E. South America Standard Time"},
            {"America/Argentina/Buenos_Aires","Argentina Standard Time"},
            {"Europe/London","GMT Standard Time"},           {"Europe/Dublin","GMT Standard Time"},
            {"Europe/Lisbon","GMT Standard Time"},           {"Europe/Paris","Romance Standard Time"},
            {"Europe/Madrid","Romance Standard Time"},       {"Europe/Berlin","W. Europe Standard Time"},
            {"Europe/Amsterdam","W. Europe Standard Time"},  {"Europe/Rome","W. Europe Standard Time"},
            {"Europe/Stockholm","W. Europe Standard Time"},  {"Europe/Oslo","W. Europe Standard Time"},
            {"Europe/Copenhagen","Romance Standard Time"},   {"Europe/Zurich","W. Europe Standard Time"},
            {"Europe/Vienna","W. Europe Standard Time"},     {"Europe/Warsaw","Central European Standard Time"},
            {"Europe/Prague","Central European Standard Time"}, {"Europe/Helsinki","FLE Standard Time"},
            {"Europe/Moscow","Russian Standard Time"},       {"Europe/Istanbul","Turkey Standard Time"},
            {"Asia/Tokyo","Tokyo Standard Time"},            {"Asia/Seoul","Korea Standard Time"},
            {"Asia/Shanghai","China Standard Time"},         {"Asia/Hong_Kong","China Standard Time"},
            {"Asia/Taipei","Taipei Standard Time"},          {"Asia/Singapore","Singapore Standard Time"},
            {"Asia/Bangkok","SE Asia Standard Time"},        {"Asia/Jakarta","SE Asia Standard Time"},
            {"Asia/Ho_Chi_Minh","SE Asia Standard Time"},    {"Asia/Kuala_Lumpur","Singapore Standard Time"},
            {"Asia/Manila","Singapore Standard Time"},       {"Asia/Kolkata","India Standard Time"},
            {"Asia/Dubai","Arabian Standard Time"},          {"Asia/Jerusalem","Israel Standard Time"},
            {"Australia/Sydney","AUS Eastern Standard Time"},{"Australia/Melbourne","AUS Eastern Standard Time"},
            {"Australia/Perth","W. Australia Standard Time"},{"Pacific/Auckland","New Zealand Standard Time"},
            {"Africa/Johannesburg","South Africa Standard Time"}, {"UTC","UTC"},
        };

        public static string ToWindows(string iana)
        {
            if (string.IsNullOrEmpty(iana)) return null;
            string w;
            return Map.TryGetValue(iana, out w) ? w : null;
        }

        // 系统当前时区是否就是这个 IANA 时区(映射表查不到时退化成比 UTC 偏移)
        public static bool Matches(string iana)
        {
            if (string.IsNullOrEmpty(iana)) return false;
            var win = ToWindows(iana);
            if (win != null) return string.Equals(win, TimeZoneInfo.Local.Id, StringComparison.OrdinalIgnoreCase);
            return false;
        }
    }

    // ── 采集到的原始信号 ────────────────────────────────────────
    class Facts
    {
        public string CnIp, IntlIp, GfwIp, ProbeIp;
        public bool GoogleReachable;
        public bool Consistent;
        public string Country, CountryName, City, Isp, Asn, Country2;
        public int Hosting = -1;     // -1 未知 0 住宅 1 机房
        public bool Proxy;
        public string CfColo, CfLoc, CfIp;
        public int ApiCode, WebCode, SiteCode;
        public string Ipv6, Ipv6Cc;
        public string IpTimezone;                 // 出口 IP 对应的 IANA 时区
        public string SysTimezone { get { return TimeZoneInfo.Local.Id; } }
        public string Locale, LangName;
        public string DnsServers, DnsScope, DnsResult, DnsVerdict;
        public string ProxyMode; public bool PacOn;
        public string VmHost; public int IpChanges;
        public string ClaudeVer, ClaudeBase;
        public string ActiveNic;
    }

    static class Collector
    {
        static readonly string[] UnsupportedCc = { "CN", "HK", "MO", "RU", "IR", "KP", "CU", "SY", "BY", "VE" };
        static readonly string[] SupportedCc = {
            "US","CA","GB","IE","DE","FR","NL","SE","NO","DK","FI","IT","ES","PT","PL","CZ","AT","CH","BE","LU",
            "JP","KR","SG","TW","AU","NZ","IL","AE","MX","BR","IN","PH","TH","MY","ID","VN","ZA","TR","SA","AR","CL" };
        static readonly string[] CnDns = {
            "114.114.114.114","114.114.115.115","223.5.5.5","223.6.6.6","119.29.29.29",
            "182.254.116.116","180.76.76.76","117.50.10.10","1.2.4.8","210.2.4.8" };

        public static bool IsUnsupported(string cc) { return cc != null && UnsupportedCc.Contains(cc.ToUpperInvariant()); }
        public static bool IsSupported(string cc) { return cc != null && SupportedCc.Contains(cc.ToUpperInvariant()); }

        public static Facts Collect()
        {
            var f = new Facts();
            // 三路出口并行拿，串行会拖到半分钟以上
            var tCn = Task.Run(() => Net.FirstIp(
                "http://members.3322.org/dyndns/getip",
                "https://whois.pconline.com.cn/ipJson.jsp?json=true",
                "http://www.taobao.com/help/getip.php"));
            var tIntl = Task.Run(() => Net.FirstIp(
                "https://api.ipify.org", "https://icanhazip.com", "https://ipinfo.io/ip"));
            var tGfw = Task.Run(() => Net.FirstIp(
                "https://www.cloudflare.com/cdn-cgi/trace", "https://api.ip.sb/ip", "https://api.myip.com"));
            var tGoogle = Task.Run(() => Net.Status("https://www.google.com/generate_204"));
            var tCf = Task.Run(() => Net.Get("https://www.cloudflare.com/cdn-cgi/trace"));
            var tApi = Task.Run(() => Net.Status("https://api.anthropic.com/v1/messages", "POST", "{}"));
            var tWeb = Task.Run(() => Net.Status("https://claude.ai/robots.txt"));
            var tSite = Task.Run(() => Net.Status("https://www.anthropic.com/robots.txt"));
            var tV6 = Task.Run(() => Ipv6Exit());
            Task.WaitAll(new Task[] { tCn, tIntl, tGfw, tGoogle, tCf, tApi, tWeb, tSite, tV6 }, 22000);

            f.CnIp = tCn.Result; f.IntlIp = tIntl.Result; f.GfwIp = tGfw.Result;
            int gcode = tGoogle.Result; f.GoogleReachable = (gcode == 204 || gcode == 200);
            f.Consistent = !string.IsNullOrEmpty(f.CnIp) && f.CnIp == f.IntlIp && f.IntlIp == f.GfwIp;
            f.ProbeIp = f.GfwIp ?? f.IntlIp;
            f.ApiCode = tApi.Result; f.WebCode = tWeb.Result; f.SiteCode = tSite.Result;
            f.Ipv6 = tV6.Result;

            var trace = tCf.Result;
            if (trace != null)
            {
                foreach (var line in trace.Split('\n'))
                {
                    if (line.StartsWith("colo=")) f.CfColo = line.Substring(5).Trim();
                    else if (line.StartsWith("loc=")) f.CfLoc = line.Substring(4).Trim();
                    else if (line.StartsWith("ip=")) f.CfIp = line.Substring(3).Trim();
                }
            }

            if (!string.IsNullOrEmpty(f.ProbeIp))
            {
                var t1 = Task.Run(() => Net.Get("http://ip-api.com/json/" + f.ProbeIp +
                    "?fields=status,country,countryCode,city,isp,as,proxy,hosting,timezone"));
                var t2 = Task.Run(() => Net.Get("https://ipinfo.io/" + f.ProbeIp + "/json"));
                Task.WaitAll(new Task[] { t1, t2 }, 15000);
                var a = t1.Result;
                if (a != null && a.Contains("\"status\":\"success\""))
                {
                    f.Country = Net.Json(a, "countryCode"); f.CountryName = Net.Json(a, "country");
                    f.City = Net.Json(a, "city"); f.Isp = Net.Json(a, "isp"); f.Asn = Net.Json(a, "as");
                    f.IpTimezone = Net.Json(a, "timezone");
                    f.Hosting = a.Contains("\"hosting\":true") ? 1 : 0;
                    f.Proxy = a.Contains("\"proxy\":true");
                }
                if (!string.IsNullOrEmpty(f.Ipv6))
                {
                    var v6 = Net.Get("http://ip-api.com/json/" + f.Ipv6 + "?fields=status,countryCode");
                    f.Ipv6Cc = Net.Json(v6, "countryCode");
                }
                var b = t2.Result;
                f.Country2 = Net.Json(b, "country");
                if (f.Country == null && f.Country2 != null)
                {
                    f.Country = f.Country2; f.CountryName = f.Country2;
                    f.Isp = Net.Json(b, "org"); f.IpTimezone = Net.Json(b, "timezone");
                }
            }

            CollectDns(f);
            CollectSystem(f);
            CollectStability(f);
            CollectClaude(f);
            return f;
        }

        // 只认 IPv6-only 端点: api64 这类双栈域名在没有 IPv6 时会回退 IPv4，得出错误结论
        static string Ipv6Exit()
        {
            foreach (var u in new[] { "https://ipv6.icanhazip.com", "https://v6.ident.me", "https://api6.ipify.org" })
            {
                var t = Net.Get(u, 6000);
                if (t == null) continue;
                t = t.Trim();
                if (t.Contains(":") && t.Length > 5 && t.Length < 46) return t;
            }
            return null;
        }

        static void CollectDns(Facts f)
        {
            var servers = new List<string>();
            string activeNic = null;
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    var props = ni.GetIPProperties();
                    if (props.GatewayAddresses.Count == 0) continue;
                    if (activeNic == null) activeNic = ni.Name;
                    foreach (var d in props.DnsAddresses)
                        if (d.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork &&
                            !servers.Contains(d.ToString())) servers.Add(d.ToString());
                }
            }
            catch { }
            f.ActiveNic = activeNic;
            f.DnsServers = string.Join(" ", servers.Take(3).ToArray());

            string firstPublic = servers.FirstOrDefault(s => !IsPrivate(s));
            if (firstPublic == null) f.DnsScope = "本地/代理接管";
            else if (CnDns.Contains(firstPublic)) f.DnsScope = "国内公共DNS(" + firstPublic + ")";
            else f.DnsScope = "境外/自定义(" + firstPublic + ")";

            try
            {
                var addrs = Dns.GetHostAddresses("claude.ai");
                var ip = addrs.FirstOrDefault(a => a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork);
                f.DnsResult = ip == null ? null : ip.ToString();
            }
            catch { f.DnsResult = null; }

            var r = f.DnsResult;
            if (r == null) f.DnsVerdict = "解析失败";
            else if (r.StartsWith("198.18.") || r.StartsWith("198.19.") || r.StartsWith("240.")) f.DnsVerdict = "代理接管(fake-ip)";
            else if (r == "0.0.0.0" || IsPrivate(r)) f.DnsVerdict = "被污染(指向私有地址)";
            // 160.79.104.0/23 是 Anthropic 自有段(AS399358)，claude.ai 已从纯 Cloudflare 迁过来
            else if (r.StartsWith("160.79.104.") || r.StartsWith("160.79.105.")) f.DnsVerdict = "正常(Anthropic)";
            else if (r.StartsWith("104.") || r.StartsWith("172.6") || r.StartsWith("162.15") ||
                     r.StartsWith("188.114.") || r.StartsWith("141.101.")) f.DnsVerdict = "正常(Cloudflare)";
            else f.DnsVerdict = "可疑(" + r + ")";
        }

        static bool IsPrivate(string ip)
        {
            return ip.StartsWith("127.") || ip.StartsWith("10.") || ip.StartsWith("192.168.") ||
                   ip.StartsWith("172.16.") || ip.StartsWith("172.17.") || ip.StartsWith("172.18.") ||
                   ip.StartsWith("172.19.") || ip.StartsWith("172.2") || ip.StartsWith("172.30.") ||
                   ip.StartsWith("172.31.") || ip.StartsWith("100.64.") || ip.StartsWith("198.18.");
        }

        static void CollectSystem(Facts f)
        {
            f.Locale = CultureInfo.CurrentCulture.Name;               // 如 zh-CN / en-US
            f.LangName = CultureInfo.CurrentCulture.TwoLetterISOLanguageName;

            // 代理形态: 注册表看系统代理和 PAC；TUN 类代理会插一块虚拟网卡并抢默认路由
            f.ProxyMode = "直连"; f.PacOn = false;
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings"))
                {
                    if (k != null)
                    {
                        var pe = k.GetValue("ProxyEnable");
                        var pac = k.GetValue("AutoConfigURL") as string;
                        if (!string.IsNullOrEmpty(pac)) f.PacOn = true;
                        if (pe != null && Convert.ToInt32(pe) == 1) f.ProxyMode = "系统代理";
                    }
                }
            }
            catch { }
            if (HasTunRoute()) f.ProxyMode = "TUN 全局";
            if (f.PacOn) f.ProxyMode += " + PAC 分流";

            f.VmHost = "物理机";
            try
            {
                var model = RunCapture("wmic", "computersystem get model");
                if (model != null)
                {
                    var m = model.ToLowerInvariant();
                    if (m.Contains("virtual") || m.Contains("vmware") || m.Contains("parallels") ||
                        m.Contains("kvm") || m.Contains("hyper-v") || m.Contains("virtualbox"))
                        f.VmHost = "虚拟机";
                }
            }
            catch { }
        }

        // TUN 代理(Clash/FlClash/Surge)靠虚拟网卡 + 抢路由接管流量，
        // 和 macOS 版一样：不看默认路由，看去公网的地址实际走哪块网卡。
        static bool HasTunRoute()
        {
            try
            {
                var outp = RunCapture("cmd.exe", "/c route print -4");
                if (outp == null) return false;
                foreach (var line in outp.Split('\n'))
                {
                    var t = line.Trim();
                    if (t.StartsWith("0.0.0.0") && (t.Contains("128.0.0.0") || t.Contains("0.0.0.0"))) { }
                    // 0.0.0.0/1 + 128.0.0.0/1 这一对是 TUN 抢路由的典型指纹
                    if (t.StartsWith("128.0.0.0") && t.Contains("128.0.0.0")) return true;
                }
            }
            catch { }
            // 兜底: 存在 TAP/WinTun/Wintun 虚拟网卡且已启用
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    var d = (ni.Description + " " + ni.Name).ToLowerInvariant();
                    if (d.Contains("wintun") || d.Contains("tap-windows") || d.Contains("clash") ||
                        d.Contains("tun") && d.Contains("adapter")) return true;
                }
            }
            catch { }
            return false;
        }

        static void CollectStability(Facts f)
        {
            f.IpChanges = 0;
            try
            {
                if (!File.Exists(Paths.Log)) return;
                var since = DateTime.Now.AddHours(-24);
                foreach (var line in File.ReadAllLines(Paths.Log))
                {
                    if (line.IndexOf("出口 IP 变化", StringComparison.Ordinal) < 0) continue;
                    var m = Regex.Match(line, @"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]");
                    DateTime t;
                    if (m.Success && DateTime.TryParse(m.Groups[1].Value, out t) && t >= since) f.IpChanges++;
                }
            }
            catch { }
        }

        static void CollectClaude(Facts f)
        {
            f.ClaudeVer = null;
            try
            {
                var where = RunCapture("cmd.exe", "/c where claude");
                if (!string.IsNullOrWhiteSpace(where))
                {
                    var v = RunCapture("cmd.exe", "/c claude --version");
                    if (!string.IsNullOrWhiteSpace(v)) f.ClaudeVer = v.Trim().Split('\n')[0].Trim();
                }
            }
            catch { }
            f.ClaudeBase = Environment.GetEnvironmentVariable("ANTHROPIC_BASE_URL");
            if (string.IsNullOrEmpty(f.ClaudeBase))
            {
                try
                {
                    var settings = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "settings.json");
                    if (File.Exists(settings))
                        f.ClaudeBase = Net.Json(File.ReadAllText(settings), "ANTHROPIC_BASE_URL");
                }
                catch { }
            }
        }

        public static string RunCapture(string exe, string args, int timeoutMs = 8000)
        {
            try
            {
                var psi = new ProcessStartInfo(exe, args)
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8
                };
                using (var p = Process.Start(psi))
                {
                    var outp = p.StandardOutput.ReadToEnd();
                    if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } }
                    return outp;
                }
            }
            catch { return null; }
        }
    }

    // ── 打分: 与 macOS 版同一套权重 ─────────────────────────────
    class Report
    {
        public int Score;
        public string Grade, Verdict;
        public List<Signal> Signals = new List<Signal>();
        public List<string> Issues = new List<string>();
        public List<string> Fixes = new List<string>();
        public string FixableTz;          // 待修的目标 Windows 时区 ID
        public bool FixableDns, FixablePac;
        public Facts F;

        public List<Signal> Gains
        {
            get { return Signals.Where(s => s.Points < s.Weight).OrderByDescending(s => s.Weight - s.Points).ToList(); }
        }
        public string FixList
        {
            get
            {
                var l = new List<string>();
                if (FixableTz != null) l.Add("时区");
                if (FixablePac) l.Add("关PAC分流");
                if (FixableDns) l.Add("DNS加密");
                return string.Join("、", l.ToArray());
            }
        }

        void Sig(string group, string label, int weight, int pct, string value, string hint,
                 string issue = null, string fix = null)
        {
            var s = new Signal { Group = group, Label = label, Weight = weight, Points = weight * pct / 100, Value = value, Hint = hint };
            Signals.Add(s);
            Score += s.Points;
            if (issue != null) Issues.Add(issue);
            if (fix != null) Fixes.Add(fix);
        }

        public static Report Build(Facts f)
        {
            var r = new Report { F = f };
            bool relay = !string.IsNullOrEmpty(f.ClaudeBase) && !f.ClaudeBase.Contains("api.anthropic.com");

            // A. 出口地区与服务可用 (35)
            if (string.IsNullOrEmpty(f.Country))
                r.Sig("出口", "出口国家", 15, 50, "未知", "换到 US / JP / SG 等支持地区的节点",
                    "出口 IP 归属地未知(IP 情报接口不可达)", "检查网络后重新体检");
            else if (Collector.IsUnsupported(f.Country))
                r.Sig("出口", "出口国家", 15, 0, f.Country + " 不支持", "换到 US / JP / SG 等支持地区的节点",
                    "出口国家 " + f.Country + " 不在 Anthropic 服务范围，登录/订阅/API 均有封号风险",
                    "切到美国/日本/新加坡等支持地区节点，并长期固定");
            else if (Collector.IsSupported(f.Country))
                r.Sig("出口", "出口国家", 15, 100, f.Country + " " + (f.City ?? ""), null);
            else
                r.Sig("出口", "出口国家", 15, 66, f.Country + " 支持未知", "换到 US / JP / SG 等已知支持地区的节点",
                    "出口国家 " + f.Country + " 支持情况未知", "建议改用 US/JP/SG 等已知支持地区节点");

            if (f.ApiCode == 401 || f.ApiCode == 400)
                r.Sig("出口", "Anthropic API 可达", 10, 100, "HTTP " + f.ApiCode, null);
            else if (f.ApiCode == 403)
                r.Sig("出口", "Anthropic API 可达", 10, 0, "HTTP 403 地区拦截", "开全局代理，确认能直连 api.anthropic.com",
                    "api.anthropic.com 返回 403，当前出口被地区拦截", "更换支持地区节点；确认代理为全局而非 PAC 分流");
            else if (f.ApiCode == 0 && relay)
                r.Sig("出口", "Anthropic API 可达", 10, 50, "直连不通(已配中转)", "只用中转可忽略",
                    "api.anthropic.com 直连不通，但你已配置中转 " + f.ClaudeBase, "只用中转可忽略；需直连官方则开全局代理");
            else if (f.ApiCode == 0)
                r.Sig("出口", "Anthropic API 可达", 10, 0, "连不上", "开全局代理，确认能直连 api.anthropic.com",
                    "api.anthropic.com 连不上(超时/DNS 污染)", "开启全局代理；检查 DNS 是否被污染");
            else
                r.Sig("出口", "Anthropic API 可达", 10, 50, "HTTP " + f.ApiCode, "稍后重试；持续异常则换节点",
                    "api.anthropic.com 返回异常状态 " + f.ApiCode, "稍后重试；持续异常则换节点");

            if (f.WebCode == 200 || f.WebCode == 301 || f.WebCode == 302 || f.WebCode == 307)
                r.Sig("出口", "claude.ai 可达", 2, 100, "HTTP " + f.WebCode, null);
            else if (f.WebCode == 403)
                r.Sig("出口", "claude.ai 可达", 2, 20, "HTTP 403 被拦", "换干净节点，确认浏览器能打开 claude.ai",
                    "claude.ai 返回 403(地区拦截或风控挑战)", "换支持地区的干净节点");
            else if (f.WebCode == 0)
                r.Sig("出口", "claude.ai 可达", 2, 0, "连不上", "开全局代理", "claude.ai 连不上", "开启全局代理");
            else
                r.Sig("出口", "claude.ai 可达", 2, 60, "HTTP " + f.WebCode, "换干净节点");

            if (f.SiteCode == 200 || f.SiteCode == 301 || f.SiteCode == 302 || f.SiteCode == 307)
                r.Sig("出口", "anthropic.com 可达", 2, 100, "HTTP " + f.SiteCode, null);
            else if (f.SiteCode == 403)
                r.Sig("出口", "anthropic.com 可达", 2, 20, "HTTP 403 被拦", "换支持地区的干净节点",
                    "anthropic.com 返回 403，官网侧也被拦", "换支持地区的干净节点");
            else if (f.SiteCode == 0)
                r.Sig("出口", "anthropic.com 可达", 2, 0, "连不上", "开全局代理", "anthropic.com 连不上", "开启全局代理");
            else r.Sig("出口", "anthropic.com 可达", 2, 60, "HTTP " + f.SiteCode, "换干净节点");

            // IPv6 出口: 没有最省心；有就必须和 IPv4 同地区，否则代理没接管 IPv6 等于开了后门
            if (string.IsNullOrEmpty(f.Ipv6))
                r.Sig("出口", "IPv6 出口", 3, 100, "无 IPv6(无泄漏面)", null);
            else if (string.IsNullOrEmpty(f.Ipv6Cc))
                r.Sig("出口", "IPv6 出口", 3, 60, "归属未知", "确认代理是否接管 IPv6");
            else if (string.Equals(f.Ipv6Cc, f.Country, StringComparison.OrdinalIgnoreCase))
                r.Sig("出口", "IPv6 出口", 3, 100, f.Ipv6Cc + " 与 IPv4 一致", null);
            else
                r.Sig("出口", "IPv6 出口", 3, 0, f.Ipv6Cc + " ≠ " + f.Country,
                    "在代理里开启 IPv6 接管，或在网络设置里关掉 IPv6",
                    "IPv6 出口在 " + f.Ipv6Cc + "，与 IPv4 出口 " + f.Country + " 不一致 —— 代理没接管 IPv6，真实地区被暴露",
                    "开启代理的 IPv6 接管或关闭系统 IPv6");

            if (!string.IsNullOrEmpty(f.Country) && !string.IsNullOrEmpty(f.Country2))
            {
                if (string.Equals(f.Country, f.Country2, StringComparison.OrdinalIgnoreCase))
                    r.Sig("出口", "多源情报一致", 3, 100, f.Country + " = " + f.Country2, null);
                else
                    r.Sig("出口", "多源情报一致", 3, 0, f.Country + " ≠ " + f.Country2, "换一个归属明确、情报干净的节点",
                        "两家 IP 情报库对该出口判定不一致(" + f.Country + " vs " + f.Country2 + ")", "换归属明确的节点");
            }
            else r.Sig("出口", "多源情报一致", 3, 50, "数据不足", "重新体检");

            // B. 出口质量 (12)
            if (f.Proxy)
                r.Sig("质量", "IP 类型", 5, 25, "公开代理/VPN", "换独享节点或住宅 IP",
                    "出口 IP 被标记为公开代理/VPN 出口，属高风控段", "换独享节点或住宅 IP");
            else if (f.Hosting == 1)
                r.Sig("质量", "IP 类型", 5, 50, "机房 IDC", "换住宅 / 家宽节点",
                    "出口是机房(IDC) IP: " + f.Isp + "，风控强度高于住宅", "有条件换住宅/家宽节点");
            else if (f.Hosting == 0) r.Sig("质量", "IP 类型", 5, 100, "住宅", null);
            else r.Sig("质量", "IP 类型", 5, 70, "未知", "重新体检");

            if (!string.IsNullOrEmpty(f.CfLoc) && !string.IsNullOrEmpty(f.Country))
            {
                if (string.Equals(f.CfLoc, f.Country, StringComparison.OrdinalIgnoreCase))
                    r.Sig("质量", "边缘机房匹配", 3, 100, f.CfColo + " (" + f.CfLoc + ")", null);
                else
                    r.Sig("质量", "边缘机房匹配", 3, 25, f.CfColo + "(" + f.CfLoc + ") ≠ " + f.Country,
                        "换地理归属真实的节点",
                        "Cloudflare 边缘落在 " + f.CfLoc + "，与 IP 库归属 " + f.Country + " 不一致", "换归属真实的节点");
            }
            else r.Sig("质量", "边缘机房匹配", 3, 50, f.CfColo ?? "未知", "重新体检");

            if (!string.IsNullOrEmpty(f.CfIp) && !string.IsNullOrEmpty(f.ProbeIp))
            {
                if (f.CfIp == f.ProbeIp) r.Sig("质量", "出口链路单一", 3, 100, f.CfIp, null);
                else r.Sig("质量", "出口链路单一", 3, 0, f.CfIp + " ≠ " + f.ProbeIp, "别叠多层代理",
                    "Cloudflare 看到的来源 " + f.CfIp + " 与检测到的出口 " + f.ProbeIp + " 不同，链路上还有一层代理",
                    "统一走同一出口，避免多层嵌套代理");
            }
            else r.Sig("质量", "出口链路单一", 3, 50, "数据不足", "重新体检");

            // C. 地区画像一致性 (18)
            if (f.Consistent) r.Sig("画像", "三路出口一致", 6, 100, f.ProbeIp, null);
            else r.Sig("画像", "三路出口一致", 6, 30, "不一致", "代理切全局模式，三路走同一出口",
                "三路出口 IP 不一致(分流/PAC/DNS 泄漏)，账号画像会在多地区间跳变", "代理切全局模式");

            if (!string.IsNullOrEmpty(f.IpTimezone) && Tz.Matches(f.IpTimezone))
                r.Sig("画像", "系统时区匹配出口", 5, 100, f.SysTimezone, null);
            else if (string.IsNullOrEmpty(f.IpTimezone))
                r.Sig("画像", "系统时区匹配出口", 5, 50, "出口时区未知", "重新体检", "无法解析出口 IP 对应时区");
            else
            {
                var target = Tz.ToWindows(f.IpTimezone);
                r.Sig("画像", "系统时区匹配出口", 5, 0, f.SysTimezone + " ≠ " + f.IpTimezone,
                    target != null ? "点「一键修复」即可自动改" : "手动把系统时区改成 " + f.IpTimezone,
                    "系统时区 " + f.SysTimezone + " 与出口时区 " + f.IpTimezone + " 不一致，是典型的环境矛盾信号",
                    target != null ? "可一键修复: 把系统时区改为 " + f.IpTimezone : "手动改系统时区");
                r.FixableTz = target;
            }

            // Windows 上时区偏移由系统统一管理，没有 macOS 那种 TZ 环境变量覆盖的情况，
            // 这项只校验当前偏移与时区定义自洽。
            bool offsetOk = TimeZoneInfo.Local.GetUtcOffset(DateTime.Now) == DateTimeOffset.Now.Offset;
            r.Sig("画像", "时区偏移自洽", 2, offsetOk ? 100 : 0,
                DateTimeOffset.Now.ToString("zzz"), "检查系统日期时间设置",
                offsetOk ? null : "当前 UTC 偏移与时区定义不符");

            string localeCc = f.Locale != null && f.Locale.Contains("-") ? f.Locale.Split('-').Last() : null;
            if (string.IsNullOrEmpty(f.Country) || localeCc == null)
                r.Sig("画像", "系统区域匹配出口", 4, 50, "数据不足", "重新体检");
            else if (string.Equals(localeCc, f.Country, StringComparison.OrdinalIgnoreCase))
                r.Sig("画像", "系统区域匹配出口", 4, 100, f.Locale, null);
            else if (f.LangName == "zh")
                r.Sig("画像", "系统区域匹配出口", 4, 50, f.Locale + " vs " + f.Country,
                    "只用 Claude Code(CLI) 可忽略；常用网页端可把系统区域改成 " + f.Country,
                    "系统语言中文 + 区域 " + localeCc + " 与出口 " + f.Country + " 不一致(网页端登录会暴露矛盾)",
                    "常用网页端可把系统区域改成 " + f.Country);
            else
                r.Sig("画像", "系统区域匹配出口", 4, 70, f.Locale + " vs " + f.Country,
                    "把系统区域改成 " + f.Country, "系统区域 " + localeCc + " 与出口 " + f.Country + " 不一致");

            // 简繁与出口地区的对应: 繁体主要用于 TW/HK/MO，简体用于 CN/SG
            string variant = null, ln = (f.Locale ?? "").ToLowerInvariant();
            if (ln.Contains("hant") || ln.EndsWith("-tw") || ln.EndsWith("-hk") || ln.EndsWith("-mo")) variant = "繁体";
            else if (ln.StartsWith("zh")) variant = "简体";
            var tw = new[] { "TW", "HK", "MO" }; var cn = new[] { "CN", "SG", "MY" };
            if (variant == null || string.IsNullOrEmpty(f.Country))
                r.Sig("画像", "语言变体一致", 2, 100, variant ?? "非中文", null);
            else if (variant == "繁体" && tw.Contains(f.Country.ToUpperInvariant()))
                r.Sig("画像", "语言变体一致", 2, 100, "繁体 · " + f.Country, null);
            else if (variant == "简体" && cn.Contains(f.Country.ToUpperInvariant()))
                r.Sig("画像", "语言变体一致", 2, 100, "简体 · " + f.Country, null);
            else
                r.Sig("画像", "语言变体一致", 2, 50, variant + " vs " + f.Country,
                    "网页端登录前可把首选语言调成 en-US",
                    "系统用" + variant + "中文但出口在 " + f.Country + "，语言变体与地区画像不对应");

            // D. DNS (10)
            if (f.DnsVerdict.StartsWith("正常") || f.DnsVerdict.StartsWith("代理接管"))
                r.Sig("DNS", "claude.ai 解析", 6, 100, f.DnsVerdict, null);
            else if (f.DnsVerdict.StartsWith("被污染"))
            {
                r.Sig("DNS", "claude.ai 解析", 6, 0, f.DnsVerdict, "点「一键修复」换成验证过的境外 DNS",
                    "claude.ai 的 DNS 解析被污染(" + f.DnsResult + ")", "换成可信 DNS 或让代理接管 DNS");
                r.FixableDns = true;
            }
            else if (f.DnsVerdict == "解析失败")
                r.Sig("DNS", "claude.ai 解析", 6, 20, "失败", "检查 DNS 设置", "claude.ai 无法解析", "检查 DNS 设置");
            else
                r.Sig("DNS", "claude.ai 解析", 6, 40, f.DnsVerdict, "换 DNS 或让代理接管 DNS",
                    "claude.ai 解析到非预期地址(" + f.DnsResult + ")，可能被劫持", "换可信 DNS");

            bool tun = f.ProxyMode.StartsWith("TUN 全局");
            if (f.DnsScope.StartsWith("本地/代理接管")) r.Sig("DNS", "DNS 出口", 4, 100, f.DnsScope, null);
            else if (f.DnsScope.StartsWith("国内公共DNS"))
            {
                if (tun) r.Sig("DNS", "DNS 出口", 4, 70, f.DnsScope + " (走隧道)", "换成 1.1.1.1 / 8.8.8.8",
                    "用的是国内公共 DNS，虽然 TUN 下查询走隧道不算泄漏，但没必要绕这一圈", "换成 1.1.1.1 / 8.8.8.8");
                else r.Sig("DNS", "DNS 出口", 4, 0, f.DnsScope, "点「一键修复」自动换成验证过的境外 DNS",
                    "正在用" + f.DnsScope + "，DNS 查询泄漏到国内，与国外出口矛盾", "改用 1.1.1.1 / 8.8.8.8");
                r.FixableDns = true;
            }
            else r.Sig("DNS", "DNS 出口", 4, tun ? 100 : 80, f.DnsScope + (tun ? " (走隧道)" : ""),
                tun ? null : "让代理接管 DNS 可拿满分");

            // E. 环境稳定性 / 运行容器 (10)
            if (f.PacOn)
            {
                r.Sig("稳定", "代理形态", 3, 20, f.ProxyMode, "关掉 PAC，改用 TUN 全局模式",
                    "启用了 PAC 自动分流，不同网站会走不同出口，账号画像不稳定", "关掉 PAC，改用 TUN 全局模式");
                r.FixablePac = true;
            }
            else if (f.ProxyMode.StartsWith("TUN 全局")) r.Sig("稳定", "代理形态", 3, 100, f.ProxyMode, null);
            else r.Sig("稳定", "代理形态", 3, 70, f.ProxyMode, "代理开 TUN / 虚拟网卡模式");

            if (f.IpChanges <= 1) r.Sig("稳定", "出口稳定性", 4, 100, "24h 内 " + f.IpChanges + " 次跳变", null);
            else if (f.IpChanges <= 5) r.Sig("稳定", "出口稳定性", 4, 50, "24h 内 " + f.IpChanges + " 次跳变",
                "固定一个节点，24 小时内别切线路(到点自动回满)",
                "24 小时内出口 IP 变了 " + f.IpChanges + " 次，设备连续性差", "固定一个节点用");
            else r.Sig("稳定", "出口稳定性", 4, 0, "24h 内 " + f.IpChanges + " 次跳变",
                "固定一个节点，24 小时内别切线路(到点自动回满)",
                "24 小时内出口 IP 变了 " + f.IpChanges + " 次，账号画像极不稳定", "关掉代理的自动切换/负载均衡");

            if (f.VmHost == "物理机") r.Sig("稳定", "运行容器", 3, 100, "物理机", null);
            else r.Sig("稳定", "运行容器", 3, 30, f.VmHost, "在物理机上登录和使用",
                "运行在" + f.VmHost + "中，设备指纹异常是风控关注的信号", "尽量在物理机上使用 Claude");

            // F. 浏览器画像 (15) —— Windows 版不带 WebView2 依赖，按中性 70% 计分，不假装测过
            r.Sig("浏览器", "WebRTC 出口", 6, 70, "未采集", "Windows 版暂不采集浏览器信号");
            r.Sig("浏览器", "浏览器时区", 4, 70, "未采集", "Windows 版暂不采集浏览器信号");
            r.Sig("浏览器", "浏览器语言", 2, 70, "未采集", "Windows 版暂不采集浏览器信号");
            // 1 分的项不值得因为"没测"就扣成 0/1，那看起来像 bug
            r.Sig("浏览器", "Intl 区域设置", 1, 100, "未采集", null);
            r.Sig("浏览器", "渲染环境", 2, 70, "未采集", "Windows 版暂不采集浏览器信号");

            if (r.Score >= 85) { r.Grade = "优秀"; r.Verdict = "环境适合运行 Claude"; }
            else if (r.Score >= 70) { r.Grade = "良好"; r.Verdict = "基本可用，建议修复下列项"; }
            else if (r.Score >= 50) { r.Grade = "风险"; r.Verdict = "存在明显矛盾信号，有封号风险"; }
            else { r.Grade = "高风险"; r.Verdict = "不建议在当前环境登录或使用 Claude"; }
            return r;
        }
    }

    // ── 修复 ────────────────────────────────────────────────────
    static class Fixer
    {
        // 改时区和 DNS 都要管理员，用 runas 提权跑一条命令，会弹一次 UAC
        static bool RunElevated(string exe, string args)
        {
            try
            {
                var psi = new ProcessStartInfo(exe, args)
                {
                    UseShellExecute = true,
                    Verb = "runas",
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                using (var p = Process.Start(psi))
                {
                    p.WaitForExit(30000);
                    return p.ExitCode == 0;
                }
            }
            catch { return false; }   // 用户点了「否」也走这里
        }

        public static bool FixTimezone(string windowsTzId)
        {
            if (string.IsNullOrEmpty(windowsTzId)) return false;
            var ok = RunElevated("cmd.exe", "/c tzutil /s \"" + windowsTzId + "\"");
            Paths.Write("fix: 时区 -> " + windowsTzId + (ok ? " 成功" : " 失败"));
            return ok;
        }

        // 先验证候选 DNS 能正确解析 claude.ai(没被投毒)再写入 —— 盲目改会把能用的环境改坏
        public static List<string> VerifyDns(params string[] servers)
        {
            var good = new List<string>();
            foreach (var s in servers)
            {
                var outp = Collector.RunCapture("nslookup", "claude.ai " + s, 6000);
                if (outp == null) continue;
                var ms = Regex.Matches(outp, @"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b");
                foreach (Match m in ms)
                {
                    var ip = m.Groups[1].Value;
                    if (ip == s) continue;                       // 这是 DNS 服务器自己的地址
                    if (ip.StartsWith("160.79.104.") || ip.StartsWith("160.79.105.") ||
                        ip.StartsWith("104.") || ip.StartsWith("172.6") || ip.StartsWith("162.15") ||
                        ip.StartsWith("188.114.") || ip.StartsWith("141.101."))
                    { good.Add(s); break; }
                }
            }
            return good;
        }

        public static bool FixDns(string nic)
        {
            if (string.IsNullOrEmpty(nic)) return false;
            var good = VerifyDns("1.1.1.1", "8.8.8.8", "9.9.9.9");
            if (good.Count == 0) { Paths.Write("fix: 候选 DNS 全部解析异常，放弃"); return false; }

            var sb = new StringBuilder();
            sb.Append("/c netsh interface ipv4 set dnsservers name=\"" + nic + "\" static " + good[0] + " primary validate=no");
            for (int i = 1; i < good.Count; i++)
                sb.Append(" && netsh interface ipv4 add dnsservers name=\"" + nic + "\" " + good[i] + " index=" + (i + 1) + " validate=no");
            sb.Append(" && ipconfig /flushdns");
            var ok = RunElevated("cmd.exe", sb.ToString());
            Paths.Write("fix: DNS " + nic + " -> " + string.Join(",", good.ToArray()) + (ok ? " 成功" : " 失败"));
            return ok;
        }

        public static bool DisablePac()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Internet Settings", true))
                {
                    if (k == null) return false;
                    k.DeleteValue("AutoConfigURL", false);
                }
                Paths.Write("fix: 已关闭 PAC 自动分流");
                return true;
            }
            catch { return false; }
        }
    }

    // ── 检查更新 ────────────────────────────────────────────────
    static class Updater
    {
        public const string Repo = "zzusec/CheckClaude";
        public static string Latest, Current;
        public static bool HasUpdate;

        public static void Check()
        {
            Current = Application.ProductVersion;
            var body = Net.Get("https://api.github.com/repos/" + Repo + "/releases/latest", 15000);
            var tag = Net.Json(body, "tag_name");
            if (string.IsNullOrEmpty(tag)) return;      // 查不到就保留上次结果，别让提示忽隐忽现
            Latest = tag.TrimStart('v', 'V');
            HasUpdate = CompareVer(Current, Latest) < 0;
        }

        public static int CompareVer(string a, string b)
        {
            var pa = (a ?? "0").Split('.'); var pb = (b ?? "0").Split('.');
            for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
            {
                int x = i < pa.Length ? SafeInt(pa[i]) : 0;
                int y = i < pb.Length ? SafeInt(pb[i]) : 0;
                if (x != y) return x < y ? -1 : 1;
            }
            return 0;
        }
        static int SafeInt(string s) { int v; return int.TryParse(s, out v) ? v : 0; }

        // 下载 zip → 解到临时目录 → 用一个批处理等本进程退出后替换 exe 再重启
        public static void Install()
        {
            try
            {
                var url = "https://github.com/" + Repo + "/releases/latest/download/CheckClaude-win.zip";
                var tmp = Path.Combine(Path.GetTempPath(), "cc-upd-" + Guid.NewGuid().ToString("N").Substring(0, 8));
                Directory.CreateDirectory(tmp);
                var zip = Path.Combine(tmp, "cc.zip");
                using (var wc = new WebClient()) { wc.Headers.Add("User-Agent", "CheckClaude"); wc.DownloadFile(url, zip); }

                var ex = Path.Combine(tmp, "x");
                Directory.CreateDirectory(ex);
                // Win10 自带 tar/expand，用 PowerShell 解压最稳
                Collector.RunCapture("powershell",
                    "-NoProfile -Command \"Expand-Archive -LiteralPath '" + zip + "' -DestinationPath '" + ex + "' -Force\"", 60000);

                var newExe = Directory.GetFiles(ex, "CheckClaude.exe", SearchOption.AllDirectories).FirstOrDefault();
                if (newExe == null) { MessageBox.Show("更新包里没有 CheckClaude.exe"); return; }

                var self = Application.ExecutablePath;
                var bat = Path.Combine(tmp, "upd.bat");
                File.WriteAllText(bat,
                    "@echo off\r\n" +
                    "ping 127.0.0.1 -n 3 >nul\r\n" +                       // 等本进程退出
                    "copy /Y \"" + newExe + "\" \"" + self + "\" >nul\r\n" +
                    "start \"\" \"" + self + "\"\r\n" +
                    "rmdir /S /Q \"" + tmp + "\"\r\n", Encoding.Default);
                Process.Start(new ProcessStartInfo(bat) { WindowStyle = ProcessWindowStyle.Hidden, UseShellExecute = true });
                Application.Exit();
            }
            catch (Exception e) { MessageBox.Show("升级失败: " + e.Message, "CheckClaude"); }
        }
    }

    // ── 托盘 ────────────────────────────────────────────────────
    class TrayApp : ApplicationContext
    {
        NotifyIcon icon;
        Report report;
        System.Windows.Forms.Timer scanTimer, updTimer;
        string lastExitIp = "", notifiedVersion = "";
        bool busy;

        public TrayApp()
        {
            Paths.Ensure();
            icon = new NotifyIcon { Visible = true, Text = "CheckClaude", Icon = MakeIcon(Color.Gray) };
            icon.ContextMenuStrip = new ContextMenuStrip();
            icon.MouseUp += (s, e) => { if (e.Button == MouseButtons.Left) icon.ContextMenuStrip.Show(Cursor.Position); };
            BuildMenu();

            scanTimer = new System.Windows.Forms.Timer { Interval = 5 * 60 * 1000 };     // 每 5 分钟一次出口检测
            scanTimer.Tick += (s, e) => RunCheck(false);
            scanTimer.Start();

            updTimer = new System.Windows.Forms.Timer { Interval = 6 * 3600 * 1000 };    // 每 6 小时查一次新版本
            updTimer.Tick += (s, e) => Task.Run(() => { Updater.Check(); Sync(BuildMenu); });
            updTimer.Start();

            Task.Run(() => { Updater.Check(); Sync(BuildMenu); });
            RunCheck(false);
        }

        void Sync(Action a) { try { if (icon.ContextMenuStrip.InvokeRequired) icon.ContextMenuStrip.BeginInvoke(a); else a(); } catch { } }

        // 托盘图标: 按分数画个圆点，省掉外部图标资源
        static Icon MakeIcon(Color c)
        {
            using (var bmp = new Bitmap(32, 32))
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (var b = new SolidBrush(c)) g.FillEllipse(b, 3, 3, 26, 26);
                using (var p = new Pen(Color.FromArgb(70, 0, 0, 0), 2)) g.DrawEllipse(p, 3, 3, 26, 26);
                return Icon.FromHandle(bmp.GetHicon());
            }
        }

        static Color ScoreColor(int score)
        {
            if (score < 0) return Color.Gray;
            if (score >= 85) return Color.FromArgb(52, 199, 89);
            if (score >= 70) return Color.FromArgb(255, 204, 0);
            if (score >= 50) return Color.FromArgb(255, 149, 0);
            return Color.FromArgb(255, 59, 48);
        }

        void RunCheck(bool manual)
        {
            if (busy) return;
            busy = true;
            Task.Run(() =>
            {
                Facts f = null;
                try { f = Collector.Collect(); } catch (Exception e) { Paths.Write("体检异常: " + e.Message); }
                if (f != null)
                {
                    // 出口 IP 变了才记一笔，"出口稳定性"就是数这些行
                    var cur = f.ProbeIp ?? "none";
                    if (!string.IsNullOrEmpty(lastExitIp) && lastExitIp != cur)
                        Paths.Write("出口 IP 变化: " + lastExitIp + " -> " + cur);
                    lastExitIp = cur;
                    report = Report.Build(f);
                    Paths.Write(string.Format("体检: {0}/100 {1} country={2} api={3}",
                        report.Score, report.Grade, f.Country ?? "?", f.ApiCode));
                }
                busy = false;
                Sync(BuildMenu);
                if (manual && report != null)
                    Sync(() => icon.ShowBalloonTip(4000, "CheckClaude",
                        report.Score + " 分 · " + report.Grade, ToolTipIcon.Info));
            });
        }

        ToolStripMenuItem Item(string text, EventHandler on = null, bool enabled = true)
        {
            var i = new ToolStripMenuItem(text);
            if (on != null) i.Click += on; else i.Enabled = enabled;
            if (on == null) i.Enabled = false;
            return i;
        }

        void BuildMenu()
        {
            var m = icon.ContextMenuStrip;
            m.Items.Clear();
            int score = report == null ? -1 : report.Score;
            icon.Icon = MakeIcon(ScoreColor(score));
            icon.Text = report == null ? "CheckClaude 检测中…" : ("CheckClaude " + score + " 分 · " + report.Grade);

            if (report == null) { m.Items.Add(Item("正在检测…")); }
            else
            {
                var f = report.F;
                bool unfit = score < 70;
                var head = new ToolStripMenuItem("Claude 环境 " + score + " 分 · " + report.Grade);
                if (unfit) head.ForeColor = Color.FromArgb(200, 30, 30);
                // 明细放子菜单，主菜单保持短
                head.DropDownItems.Add(Item(report.Verdict));
                head.DropDownItems.Add(new ToolStripSeparator());
                if (report.Gains.Count == 0) head.DropDownItems.Add(Item("🎉 已满分，没有可提升项"));
                else
                {
                    head.DropDownItems.Add(Item("还能提 " + (100 - score) + " 分"));
                    foreach (var g in report.Gains)
                        head.DropDownItems.Add(Item("   ＋" + (g.Weight - g.Points) + "  " + g.Label + "：" + (g.Hint ?? "")));
                }
                head.DropDownItems.Add(new ToolStripSeparator());
                string grp = null;
                foreach (var s in report.Signals)
                {
                    if (s.Group != grp) { grp = s.Group; head.DropDownItems.Add(Item("── " + grp + " ──")); }
                    var li = Item((s.Ok ? "✓" : "⚠") + "  " + s.Label + "：" + s.Value + "   " + s.Points + "/" + s.Weight);
                    if (unfit && !s.Ok) li.ForeColor = Color.FromArgb(200, 30, 30);
                    head.DropDownItems.Add(li);
                }
                head.DropDownItems.Add(new ToolStripSeparator());
                head.DropDownItems.Add(Item("出口: " + (f.ProbeIp ?? "?") + " · " + (f.City ?? "") + " · " + (f.Asn ?? "?")));
                head.DropDownItems.Add(Item("系统: " + f.SysTimezone + " · " + f.Locale + " · " + f.ProxyMode));
                head.DropDownItems.Add(Item("DNS: " + f.DnsScope + " · claude.ai → " + f.DnsVerdict));
                head.DropDownItems.Add(Item("CLI: " + (f.ClaudeVer ?? "未检测到") + " · 接口 " +
                    (string.IsNullOrEmpty(f.ClaudeBase) ? "官方" : f.ClaudeBase)));
                m.Items.Add(head);

                m.Items.Add(Item("重新体检", (s, e) => RunCheck(true)));
                if (!string.IsNullOrEmpty(report.FixList))
                    m.Items.Add(Item("⚡ 一键修复：" + report.FixList, (s, e) => DoFix()));

                m.Items.Add(new ToolStripSeparator());
                m.Items.Add(Item("出口 IP: " + (f.ProbeIp ?? "?") + (f.Consistent ? "（三路一致）" : "（三路不一致）")));
                m.Items.Add(Item("系统时区: " + f.SysTimezone));
            }

            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(Item("打开日志", (s, e) => { try { Process.Start("notepad.exe", Paths.Log); } catch { } }));
            var auto = new ToolStripMenuItem("开机自启") { Checked = AutoStart.Enabled, CheckOnClick = true };
            auto.Click += (s, e) => { AutoStart.Toggle(); BuildMenu(); };
            m.Items.Add(auto);
            m.Items.Add(new ToolStripSeparator());
            if (Updater.HasUpdate)
            {
                m.Items.Add(Item("版本 v" + Application.ProductVersion));
                var up = Item("⬆ 升级到 v" + Updater.Latest, (s, e) => Updater.Install());
                up.ForeColor = Color.FromArgb(0, 102, 204);
                m.Items.Add(up);
                if (notifiedVersion != Updater.Latest)
                {
                    notifiedVersion = Updater.Latest;
                    icon.ShowBalloonTip(6000, "CheckClaude 有新版本 v" + Updater.Latest,
                        "右键托盘图标 →「升级到 v" + Updater.Latest + "」一键更新", ToolTipIcon.Info);
                }
            }
            else
            {
                m.Items.Add(Item("版本 v" + Application.ProductVersion + "（已是最新）"));
                m.Items.Add(Item("检查更新", (s, e) => Task.Run(() => { Updater.Check(); Sync(BuildMenu); })));
            }
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(Item("官方网站",
                (s, e) => { try { Process.Start("https://www.yinso.com/labs/"); } catch { } }));
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(Item("退出", (s, e) => { icon.Visible = false; Application.Exit(); }));
        }

        void DoFix()
        {
            if (report == null) return;
            var r = report;
            Task.Run(() =>
            {
                bool any = false;
                if (r.FixableTz != null) any |= Fixer.FixTimezone(r.FixableTz);
                if (r.FixablePac) any |= Fixer.DisablePac();
                if (r.FixableDns) any |= Fixer.FixDns(r.F.ActiveNic);
                Sync(() => icon.ShowBalloonTip(5000, "CheckClaude",
                    any ? "修复完成，正在重新体检" : "没有修复成功的项（可能取消了授权）", ToolTipIcon.Info));
                RunCheck(false);
            });
        }
    }

    // 开机自启: 注册表 Run 项，不需要管理员
    static class AutoStart
    {
        const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string Name = "CheckClaude";
        public static bool Enabled
        {
            get
            {
                try { using (var k = Registry.CurrentUser.OpenSubKey(Key)) return k != null && k.GetValue(Name) != null; }
                catch { return false; }
            }
        }
        public static void Toggle()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(Key, true))
                {
                    if (k == null) return;
                    if (Enabled) k.DeleteValue(Name, false);
                    else k.SetValue(Name, "\"" + Application.ExecutablePath + "\"");
                }
            }
            catch { }
        }
    }

    static class Program
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        static extern bool AttachConsole(int pid);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        static extern bool AllocConsole();

        // 控制台报告模式: CheckClaude.exe --check
        // winexe 没有控制台，先附到父进程的，附不上就自己开一个
        static int RunConsole()
        {
            if (!AttachConsole(-1)) AllocConsole();
            Console.OutputEncoding = Encoding.UTF8;
            var f = Collector.Collect();
            var r = Report.Build(f);
            var sb = new StringBuilder();
            sb.AppendLine();
            sb.AppendLine("  CheckClaude 运行环境体检");
            sb.AppendLine("  " + new string('-', 54));
            var bar = new string('#', r.Score / 5) + new string('.', 20 - r.Score / 5);
            sb.AppendLine("  得分  " + bar + "  " + r.Score + "/100  【" + r.Grade + "】");
            sb.AppendLine("  结论  " + r.Verdict);
            sb.AppendLine();
            string grp = null;
            foreach (var s2 in r.Signals)
            {
                if (s2.Group != grp) { grp = s2.Group; sb.AppendLine("  -- " + grp + " --"); }
                sb.AppendLine(string.Format("  {0}  {1,-18} {2,-26} {3,2}/{4}",
                    s2.Ok ? "OK" : "!!", s2.Label, s2.Value, s2.Points, s2.Weight));
            }
            sb.AppendLine();
            sb.AppendLine("  出口 " + (f.ProbeIp ?? "?") + " · " + (f.CountryName ?? "?") + " " + (f.City ?? "") + " · " + (f.Isp ?? "?"));
            sb.AppendLine("  系统 " + f.SysTimezone + " · " + f.Locale + " · " + f.ProxyMode + " · " + f.VmHost);
            sb.AppendLine("  DNS  " + f.DnsScope + " · claude.ai -> " + f.DnsVerdict);
            sb.AppendLine("  CLI  " + (f.ClaudeVer ?? "未检测到") + " · 接口 " + (string.IsNullOrEmpty(f.ClaudeBase) ? "官方" : f.ClaudeBase));
            if (r.Gains.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("  还能提 " + (100 - r.Score) + " 分");
                foreach (var g in r.Gains)
                    sb.AppendLine(string.Format("    +{0,-3} {1,-18} {2}", g.Weight - g.Points, g.Label, g.Hint ?? ""));
            }
            if (r.Issues.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("  发现的问题");
                foreach (var i in r.Issues) sb.AppendLine("    * " + i);
            }
            sb.AppendLine();
            Console.WriteLine(sb.ToString());
            Paths.Write(string.Format("体检(命令行): {0}/100 {1} country={2} api={3}",
                r.Score, r.Grade, f.Country ?? "?", f.ApiCode));
            return r.Score >= 70 ? 0 : 1;
        }

        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length > 0 && (args[0] == "--check" || args[0] == "-c")) return RunConsole();
            if (args.Length > 0 && args[0] == "--version") { if (!AttachConsole(-1)) AllocConsole(); Console.WriteLine(Application.ProductVersion); return 0; }
            return RunTray();
        }

        static int RunTray()
        {
            bool created;
            using (new Mutex(true, "CheckClaude.SingleInstance", out created))
            {
                if (!created) return 0;               // 已经在跑就别开第二个托盘图标
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
            }
            return 0;
        }
    }
}
