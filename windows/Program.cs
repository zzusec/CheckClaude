// CheckClaude for Windows —— 检查这台机器适不适合跑 Claude，能修的直接修。
// 与 macOS 版同一套评分模型（26 项加权信号，合计 100），这里是 .NET Framework 4.8 实现：
// 用系统自带 csc.exe 编译，产物是单个 exe，不需要安装第三方运行时。
//
// 浏览器 7 项由 BrowserBridge 调起系统默认浏览器采集；命令行单跑时没有浏览器上下文，
// 与 macOS 命令行模式保持同一口径，按中性分计入。

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
        public string Country, CountryName, City, Isp, Asn, Country2, Isp2;
        public bool CountrySourcesAgree; // 两家 IP 情报都返回国家码且结论一致
        public int AsnMatch = -1;   // -1 数据不足 0 两家 ASN 归属不一致 1 一致
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
        // 浏览器指纹(由 BrowserBridge 采集后写文件，这里读回来)
        public bool BrOk; public string BrSource, BrTz, BrLangs, BrLocale, BrRtc, BrWebgl, BrFonts, BrChPlat, BrAccept, BrUa;
        public int BrAgeMin = -1;                 // 这份浏览器数据采集于几分钟前，-1 表示没有
        // 采的是系统默认浏览器，不一定是用户刚改过设置的那个，所以要把来源摆出来
        public string BrFrom
        {
            get
            {
                if (!BrOk) return null;
                var who = string.IsNullOrEmpty(BrUa)
                    ? (BrSource == "browser" ? "默认浏览器" : "内置引擎")
                    : LocalePolicy.BrowserName(BrUa);
                return who + " · " + (BrAgeMin <= 0 ? "刚刚" : BrAgeMin + " 分钟前") + "采集";
            }
        }
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

        // 重点地区的具体情况，比笼统一句"不在服务范围"有用
        public static string RegionNote(string cc)
        {
            switch ((cc ?? "").ToUpperInvariant())
            {
                case "CN": return "中国大陆：Anthropic 未在此开放服务，登录、订阅与 API 申请均会被拒";
                case "HK": case "MO": return "港澳：不在 Anthropic 支持地区列表内，与大陆同样不可用";
                case "RU": case "BY": return "俄罗斯/白俄罗斯：受制裁限制，服务与订阅不可用";
                case "IR": case "KP": case "CU": case "SY": return "受美国制裁地区，Anthropic 服务完全不可用";
                case "VE": return "委内瑞拉：不在支持地区列表内";
                default: return "该地区不在 Anthropic 支持列表内";
            }
        }

        public static bool IsUnsupported(string cc) { return cc != null && UnsupportedCc.Contains(cc.ToUpperInvariant()); }
        public static bool IsSupported(string cc) { return cc != null && SupportedCc.Contains(cc.ToUpperInvariant()); }

        // 定时器只跑这组轻量探测。完整 Claude 体检只在首次启动、手动点击、
        // 出口变化或一致性变化时运行，避免每分钟请求 Anthropic。
        public static Facts CollectExit()
        {
            var f = new Facts();
            var tCn = Task.Run(() => Net.FirstIp(
                "http://members.3322.org/dyndns/getip",
                "https://whois.pconline.com.cn/ipJson.jsp?json=true",
                "http://www.taobao.com/help/getip.php"));
            var tIntl = Task.Run(() => Net.FirstIp(
                "https://api.ipify.org", "https://icanhazip.com", "https://ipinfo.io/ip"));
            var tGfw = Task.Run(() => Net.FirstIp(
                "https://www.cloudflare.com/cdn-cgi/trace", "https://api.ip.sb/ip", "https://api.myip.com"));
            var tGoogle = Task.Run(() => Net.Status("https://www.google.com/generate_204"));
            Task.WaitAll(new Task[] { tCn, tIntl, tGfw, tGoogle }, 22000);

            f.CnIp = tCn.Result;
            f.IntlIp = tIntl.Result;
            f.GfwIp = tGfw.Result;
            int gcode = tGoogle.Result;
            f.GoogleReachable = gcode == 204 || gcode == 200;
            f.Consistent = !string.IsNullOrEmpty(f.CnIp) && f.CnIp == f.IntlIp && f.IntlIp == f.GfwIp;
            f.ProbeIp = f.GfwIp ?? f.IntlIp;
            return f;
        }

        public static Facts Collect()
        {
            var f = CollectExit();
            var tCf = Task.Run(() => Net.Get("https://www.cloudflare.com/cdn-cgi/trace"));
            var tApi = Task.Run(() => Net.Status("https://api.anthropic.com/v1/messages", "POST", "{}"));
            var tWeb = Task.Run(() => Net.Status("https://claude.ai/robots.txt"));
            var tSite = Task.Run(() => Net.Status("https://www.anthropic.com/robots.txt"));
            var tV6 = Task.Run(() => Ipv6Exit());
            Task.WaitAll(new Task[] { tCf, tApi, tWeb, tSite, tV6 }, 22000);

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
                f.CountrySourcesAgree = !string.IsNullOrEmpty(f.Country) && !string.IsNullOrEmpty(f.Country2)
                    && string.Equals(f.Country, f.Country2, StringComparison.OrdinalIgnoreCase);
                f.Isp2 = Net.Json(b, "org");
                // ASN 交叉比对: 国家码一致不等于归属一致。同一个 IP 在 ip-api 报 AS5065 住宅 ISP、
                // 在 ipinfo 报 AS3257 GTT(骨干/IDC)，说明这段 IP 的归属登记本身有分歧 ——
                // 风控侧按哪一家判都有可能，只比国家码会把这种 IP 当成干净住宅放过去。
                var an1 = Regex.Match(f.Asn ?? "", @"^AS\d+").Value;
                var an2 = Regex.Match(f.Isp2 ?? "", @"^AS\d+").Value;
                f.AsnMatch = (an1.Length > 0 && an2.Length > 0)
                    ? (string.Equals(an1, an2, StringComparison.OrdinalIgnoreCase) ? 1 : 0) : -1;
                if (f.Country == null && f.Country2 != null)
                {
                    f.Country = f.Country2; f.CountryName = f.Country2;
                    f.Isp = Net.Json(b, "org"); f.IpTimezone = Net.Json(b, "timezone");
                }
            }

            CollectDns(f);
            CollectSystem(f);
            CollectStability(f);
            CollectBrowser(f);
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
            f.Locale = LocalePolicy.CurrentUserCultureName();         // 如 zh-CN / en-US
            try { f.LangName = CultureInfo.GetCultureInfo(f.Locale).TwoLetterISOLanguageName; }
            catch { f.LangName = CultureInfo.CurrentCulture.TwoLetterISOLanguageName; }

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

        // 浏览器指纹: 1 小时内采集的才算数
        static void CollectBrowser(Facts f)
        {
            f.BrOk = false;
            f.BrAgeMin = -1;
            var path = Path.Combine(Paths.Dir, "browser_signals");
            if (!File.Exists(path)) return;
            var age = DateTime.Now - File.GetLastWriteTime(path);
            if (age.TotalHours > 1) return;
            f.BrAgeMin = age.TotalMinutes < 0 ? 0 : (int)age.TotalMinutes;
            foreach (var line in File.ReadAllLines(path))
            {
                var i = line.IndexOf('=');
                if (i <= 0) continue;
                var k = line.Substring(0, i); var v = line.Substring(i + 1);
                switch (k)
                {
                    case "source": f.BrSource = v; break;
                    case "ua": f.BrUa = v; break;
                    case "tz": f.BrTz = v; break;
                    case "languages": f.BrLangs = v; break;
                    case "locale": f.BrLocale = v; break;
                    case "rtc_srflx": f.BrRtc = v; break;
                    case "webgl": f.BrWebgl = v; break;
                    case "fonts": f.BrFonts = v; break;
                    case "ch_platform": f.BrChPlat = v; break;
                    case "uad_platform": if (string.IsNullOrEmpty(f.BrChPlat)) f.BrChPlat = v; break;
                    case "accept_lang": f.BrAccept = v; break;
                }
            }
            f.BrOk = !string.IsNullOrEmpty(f.BrTz);
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

    enum LocaleMatchKind
    {
        Compatible,
        Conflict,
        Unknown
    }

    class LocaleMatch
    {
        public LocaleMatchKind Kind;
        public string Tag, Variant, Recommended;
    }

    // 语言是个人偏好，不能从 IP 唯一推导。这里只识别高置信的中文简繁冲突；
    // 英语在所有地区都兼容，其他无法确定的语言不扣分。
    static class LocalePolicy
    {
        static readonly string[] TraditionalCc = { "TW", "HK", "MO" };
        static readonly string[] SimplifiedCc = { "CN", "SG", "MY" };
        static readonly Dictionary<string, string> Recommended = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "US", "en-US" }, { "CA", "en-CA" }, { "GB", "en-GB" }, { "IE", "en-IE" },
            { "DE", "de-DE" }, { "FR", "fr-FR" }, { "NL", "nl-NL" }, { "SE", "sv-SE" },
            { "NO", "nb-NO" }, { "DK", "da-DK" }, { "FI", "fi-FI" }, { "IT", "it-IT" },
            { "ES", "es-ES" }, { "PT", "pt-PT" }, { "PL", "pl-PL" }, { "CZ", "cs-CZ" },
            { "AT", "de-AT" }, { "CH", "de-CH" }, { "BE", "nl-BE" }, { "LU", "fr-LU" },
            { "JP", "ja-JP" }, { "KR", "ko-KR" }, { "SG", "zh-SG" }, { "TW", "zh-TW" },
            { "HK", "zh-HK" }, { "MO", "zh-MO" }, { "CN", "zh-CN" },
            { "AU", "en-AU" }, { "NZ", "en-NZ" }, { "IL", "he-IL" }, { "AE", "ar-AE" },
            { "MX", "es-MX" }, { "BR", "pt-BR" }, { "IN", "hi-IN" }, { "PH", "fil-PH" },
            { "TH", "th-TH" }, { "MY", "ms-MY" }, { "ID", "id-ID" }, { "VN", "vi-VN" },
            { "ZA", "en-ZA" }, { "TR", "tr-TR" }, { "SA", "ar-SA" }, { "AR", "es-AR" },
            { "CL", "es-CL" }
        };

        public static string CurrentUserCultureName()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Control Panel\International"))
                {
                    var name = k == null ? null : k.GetValue("LocaleName") as string;
                    if (!string.IsNullOrEmpty(name)) return name;
                }
            }
            catch { }
            return CultureInfo.CurrentCulture.Name;
        }

        public static string PrimaryTag(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;
            var tag = raw.Split(',')[0].Split(';')[0].Trim().Replace('_', '-');
            return tag.Length == 0 ? null : tag;
        }

        public static string RegionCode(string raw)
        {
            var tag = PrimaryTag(raw);
            if (tag == null) return null;
            var parts = tag.Split('-');
            for (int i = parts.Length - 1; i >= 1; i--)
            {
                var part = parts[i];
                if (part.Length == 2 && part.All(char.IsLetter)) return part.ToUpperInvariant();
            }
            return null;
        }

        public static string LanguageCode(string raw)
        {
            var tag = PrimaryTag(raw);
            if (tag == null) return null;
            return tag.Split('-')[0].ToLowerInvariant();
        }

        public static string ChineseVariant(string raw)
        {
            if (LanguageCode(raw) != "zh") return null;
            var tag = PrimaryTag(raw).ToLowerInvariant();
            if (tag.Split('-').Contains("hant")) return "繁体";
            if (tag.Split('-').Contains("hans")) return "简体";
            var cc = RegionCode(tag);
            if (cc != null && TraditionalCc.Contains(cc)) return "繁体";
            if (cc != null && SimplifiedCc.Contains(cc)) return "简体";
            return null;
        }

        public static string RecommendedLocale(string country)
        {
            if (string.IsNullOrEmpty(country)) return null;
            string locale;
            return Recommended.TryGetValue(country, out locale) ? locale : null;
        }

        public static string TargetCulture(string currentLocale, string country)
        {
            var language = LanguageCode(currentLocale);
            if (!string.IsNullOrEmpty(language) && !string.IsNullOrEmpty(country))
            {
                var candidate = language + "-" + country.ToUpperInvariant();
                try
                {
                    CultureInfo.GetCultureInfo(candidate);
                    if (string.Equals(RegionCode(candidate), country, StringComparison.OrdinalIgnoreCase)) return candidate;
                }
                catch { }
            }
            return RecommendedLocale(country);
        }

        static string RecommendedLanguage(string country)
        {
            switch ((country ?? "").ToUpperInvariant())
            {
                case "TW": return "zh-TW";
                case "HK": return "zh-HK";
                case "MO": return "zh-MO";
                case "CN": return "zh-CN";
                case "SG": return "zh-SG";
                case "MY": return "zh-MY";
                default: return RecommendedLocale(country);
            }
        }

        public static LocaleMatch Evaluate(string raw, string country)
        {
            var result = new LocaleMatch
            {
                Kind = LocaleMatchKind.Unknown,
                Tag = PrimaryTag(raw),
                Recommended = RecommendedLocale(country)
            };
            if (result.Tag == null || string.IsNullOrEmpty(country)) return result;

            var language = LanguageCode(result.Tag);
            var region = RegionCode(result.Tag);
            if (string.Equals(region, country, StringComparison.OrdinalIgnoreCase) || language == "en")
            {
                result.Kind = LocaleMatchKind.Compatible;
                return result;
            }
            if (language != "zh") return result;

            result.Variant = ChineseVariant(result.Tag);
            string expected = TraditionalCc.Contains(country.ToUpperInvariant()) ? "繁体"
                            : SimplifiedCc.Contains(country.ToUpperInvariant()) ? "简体" : null;
            if (result.Variant == null) return result;
            result.Kind = expected == null || result.Variant != expected
                ? LocaleMatchKind.Conflict : LocaleMatchKind.Compatible;
            return result;
        }

        public static string BrowserName(string ua)
        {
            ua = ua ?? "";
            if (ua.IndexOf("Edg/", StringComparison.OrdinalIgnoreCase) >= 0) return "Microsoft Edge";
            if (ua.IndexOf("Firefox/", StringComparison.OrdinalIgnoreCase) >= 0) return "Firefox";
            if (ua.IndexOf("Chrome/", StringComparison.OrdinalIgnoreCase) >= 0) return "Google Chrome";
            return "浏览器";
        }

        public static string LanguageHint(string country, string target)
        {
            var locale = RecommendedLanguage(country);
            if (string.IsNullOrEmpty(locale)) return target + "使用你实际需要的语言即可；当前信息不足，不建议仅按 IP 猜测";
            if (target.StartsWith("Windows", StringComparison.Ordinal))
                return "Windows 设置 → 时间和语言 → 语言和区域，将 " + locale
                    + " 设为首选语言；按系统提示注销或重开应用后重新体检";
            return "浏览器设置 → 语言，将 " + locale + " 设为首选；完全退出并重开浏览器后点「重新体检（含浏览器采集）」";
        }

        public static string BrowserLanguageHint(string country, string ua)
        {
            var locale = RecommendedLanguage(country) ?? "与出口兼容的语言";
            switch (BrowserName(ua))
            {
                case "Google Chrome":
                    return "Chrome 设置 → 语言；添加 " + locale + " 并移到首位；完全退出后重开 Chrome，再点「重新体检（含浏览器采集）」";
                case "Microsoft Edge":
                    return "Edge 设置 → 语言；添加 " + locale + " 并移到首位；完全退出后重开 Edge，再点「重新体检（含浏览器采集）」";
                case "Firefox":
                    return "Firefox 设置 → 常规 → 语言；把 " + locale + " 调到首位；重启 Firefox，再点「重新体检（含浏览器采集）」";
                default:
                    return "浏览器设置 → 语言；把 " + locale + " 调到首位；重启浏览器后点「重新体检（含浏览器采集）」";
            }
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
        public string FixableCulture;     // 待修的当前用户区域格式，如 zh-TW
        public bool FixableDns, FixablePac;
        public Facts F;

        public List<Signal> Gains
        {
            get { return Signals.Where(s => s.Points < s.Weight).OrderByDescending(s => s.Weight - s.Points).ToList(); }
        }
        public bool IsAutoFixable(Signal s)
        {
            if (s == null) return false;
            if (s.Label == "系统时区匹配出口") return FixableTz != null;
            if (s.Label == "系统区域匹配出口") return FixableCulture != null;
            if (s.Label == "代理形态") return FixablePac;
            if (s.Label == "claude.ai 解析" || s.Label == "DNS 出口") return FixableDns;
            return false;
        }
        public List<Signal> ManualGains
        {
            get { return Gains.Where(s => !IsAutoFixable(s)).ToList(); }
        }
        public string FixList
        {
            get
            {
                var l = new List<string>();
                if (FixableTz != null) l.Add("时区");
                if (FixableCulture != null) l.Add("区域格式");
                if (FixablePac) l.Add("关PAC分流");
                if (FixableDns) l.Add("DNS设置");
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
                r.Sig("出口", "出口国家", 14, 50, "未知", "换到 US / JP / SG 等支持地区的节点",
                    "出口 IP 归属地未知(IP 情报接口不可达)", "检查网络后重新体检");
            else if (Collector.IsUnsupported(f.Country))
                r.Sig("出口", "出口国家", 14, 0, f.Country + " 不支持", "换到 US / JP / SG 等支持地区的节点",
                    "出口国家 " + f.Country + " 不在 Anthropic 服务范围，登录/订阅/API 均有封号风险",
                    "切到美国/日本/新加坡等支持地区节点，并长期固定");
            else if (Collector.IsSupported(f.Country))
                r.Sig("出口", "出口国家", 14, 100, f.Country + " " + (f.City ?? ""), null);
            else
                r.Sig("出口", "出口国家", 14, 66, f.Country + " 支持未知", "换到 US / JP / SG 等已知支持地区的节点",
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
                if (string.Equals(f.Country, f.Country2, StringComparison.OrdinalIgnoreCase) && f.AsnMatch == 0)
                    // 国家码一致但 ASN 归属分歧，风控按不同库判会得到不同结论，不能算"完全一致"
                    r.Sig("出口", "多源情报一致", 3, 50, f.Country + " = " + f.Country2 + " · ASN 分歧",
                        "换一个 ASN 归属明确、各情报库口径一致的节点",
                        "同一出口 " + f.ProbeIp + " 的 ASN 归属不一致(ip-api: " + f.Asn + " / ipinfo: " + f.Isp2 + ")，这段 IP 的登记信息本身有争议",
                        "换一个 ASN 归属明确、各情报库口径一致的节点");
                else if (string.Equals(f.Country, f.Country2, StringComparison.OrdinalIgnoreCase))
                    r.Sig("出口", "多源情报一致", 3, 100, f.Country + " = " + f.Country2, null);
                else
                    r.Sig("出口", "多源情报一致", 3, 0, f.Country + " ≠ " + f.Country2, "换一个归属明确、情报干净的节点",
                        "两家 IP 情报库对该出口判定不一致(" + f.Country + " vs " + f.Country2 + ")", "换归属明确的节点");
            }
            else r.Sig("出口", "多源情报一致", 3, 50, "数据不足", "重新体检");

            // B. 出口质量 (12)
            if (f.Proxy)
                r.Sig("质量", "IP 类型", 4, 25, "公开代理/VPN", "换独享节点或住宅 IP",
                    "出口 IP 被标记为公开代理/VPN 出口，属高风控段", "换独享节点或住宅 IP");
            else if (f.Hosting == 1)
                r.Sig("质量", "IP 类型", 4, 50, "机房 IDC", "换住宅 / 家宽节点",
                    "出口是机房(IDC) IP: " + f.Isp + "，风控强度高于住宅", "有条件换住宅/家宽节点");
            else if (f.Hosting == 0 && f.AsnMatch == 0)
                // 只有 ip-api 说它是住宅；另一家把同一段登记成骨干/IDC 运营商。
                // 这种"住宅"经不起风控交叉核对，不给满分。
                r.Sig("质量", "IP 类型", 4, 70, "住宅(归属存疑)", "换各情报库口径一致的住宅节点",
                    "ip-api 判该出口为住宅(" + f.Isp + ")，但 ipinfo 归到 " + f.Isp2 + " —— 可能是机房段被标成住宅",
                    "优先选各情报库一致认定为住宅/家宽的节点");
            else if (f.Hosting == 0) r.Sig("质量", "IP 类型", 4, 100, "住宅", null);
            else r.Sig("质量", "IP 类型", 4, 70, "未知", "重新体检");

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
                if (Collector.IsUnsupported(f.Country))
                    r.Sig("画像", "系统时区匹配出口", 5, 0, f.SysTimezone + " ≠ " + f.IpTimezone,
                        "先换到支持地区且归属明确的节点，再按新出口修复时区",
                        "系统时区 " + f.SysTimezone + " 与不支持地区出口时区 " + f.IpTimezone + " 不一致");
                else
                {
                    r.Sig("画像", "系统时区匹配出口", 5, 0, f.SysTimezone + " ≠ " + f.IpTimezone,
                        target != null ? "点「一键修复」即可自动改" : "手动把系统时区改成 " + f.IpTimezone,
                        "系统时区 " + f.SysTimezone + " 与出口时区 " + f.IpTimezone + " 不一致，是典型的环境矛盾信号",
                        target != null ? "可一键修复: 把系统时区改为 " + f.IpTimezone : "手动改系统时区");
                    r.FixableTz = target;
                }
            }

            // Windows 上时区偏移由系统统一管理，没有 macOS 那种 TZ 环境变量覆盖的情况，
            // 这项只校验当前偏移与时区定义自洽。
            bool offsetOk = TimeZoneInfo.Local.GetUtcOffset(DateTime.Now) == DateTimeOffset.Now.Offset;
            r.Sig("画像", "时区偏移自洽", 2, offsetOk ? 100 : 0,
                DateTimeOffset.Now.ToString("zzz"), "检查系统日期时间设置",
                offsetOk ? null : "当前 UTC 偏移与时区定义不符");

            string localeCc = LocalePolicy.RegionCode(f.Locale);
            if (string.IsNullOrEmpty(f.Country) || localeCc == null)
                r.Sig("画像", "系统区域匹配出口", 4, 50, "数据不足", "重新体检");
            else if (string.Equals(localeCc, f.Country, StringComparison.OrdinalIgnoreCase))
                r.Sig("画像", "系统区域匹配出口", 4, 100, f.Locale, null);
            else
            {
                var targetCulture = LocalePolicy.TargetCulture(f.Locale, f.Country);
                bool canAutoFixCulture = Collector.IsSupported(f.Country) && f.CountrySourcesAgree
                    && !string.IsNullOrEmpty(targetCulture);
                string localeHint;
                if (canAutoFixCulture)
                    localeHint = "点「一键修复」把当前用户区域格式改为 " + targetCulture + "（不改显示语言和键盘）";
                else if (!Collector.IsSupported(f.Country))
                    localeHint = "当前出口不适合自动改区域；先更换到受支持地区并重新体检";
                else if (!f.CountrySourcesAgree)
                    localeHint = "IP 情报国家码未达成多源一致，暂不自动改区域；先换归属明确的节点";
                else
                    localeHint = "手动把当前用户区域格式改成与出口 " + f.Country + " 一致";

                int pct = f.LangName == "zh" ? 50 : 70;
                r.Sig("画像", "系统区域匹配出口", 4, pct, f.Locale + " vs " + f.Country, localeHint,
                    "系统区域 " + localeCc + " 与出口 " + f.Country + " 不一致",
                    canAutoFixCulture ? "可一键修复: 当前用户区域格式改为 " + targetCulture : localeHint);
                if (canAutoFixCulture) r.FixableCulture = targetCulture;
            }

            var systemLanguage = LocalePolicy.Evaluate(f.Locale, f.Country);
            if (systemLanguage.Kind == LocaleMatchKind.Conflict)
                r.Sig("画像", "语言变体一致", 2, 50, systemLanguage.Variant + " vs " + f.Country,
                    LocalePolicy.LanguageHint(f.Country, "Windows 首选语言"),
                    "系统使用" + systemLanguage.Variant + "中文，但出口 " + f.Country + " 对应另一种中文变体");
            else
                r.Sig("画像", "语言变体一致", 2, 100,
                    systemLanguage.Kind == LocaleMatchKind.Unknown ? "无法确认（不扣分）" : (systemLanguage.Tag ?? "非中文"), null);

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

            // F. 浏览器画像 (17) —— 与 macOS 版同一套判定
            if (!f.BrOk)
            {
                // 没采集到就按中性计分，不能因为"没测"判环境有问题，也不白送满分
                r.Sig("浏览器", "WebRTC 出口", 6, 70, "未采集", "菜单里点「重新体检（含浏览器采集）」会自动采集");
                r.Sig("浏览器", "浏览器时区", 3, 70, "未采集", "菜单里点「重新体检（含浏览器采集）」会自动采集");
                r.Sig("浏览器", "浏览器语言", 2, 70, "未采集", "菜单里点「重新体检（含浏览器采集）」会自动采集");
                r.Sig("浏览器", "渲染环境", 2, 70, "未采集", "菜单里点「重新体检（含浏览器采集）」会自动采集");
                r.Sig("浏览器", "Intl 区域设置", 1, 100, "未采集", null);
                r.Sig("浏览器", "Client Hints", 2, 70, "未采集", "菜单里点「重新体检（含浏览器采集）」会自动采集");
                r.Sig("浏览器", "HTTP 语言首标", 1, 100, "未采集", null);
            }
            else
            {
                bool real = f.BrSource == "browser";
                string src = real ? "（真实浏览器）" : "";
                // WebRTC 走 UDP，不经 HTTP 代理，能暴露代理没兜住的真实出口
                if (string.IsNullOrEmpty(f.BrRtc))
                    r.Sig("浏览器", "WebRTC 出口", 6, 100, "无泄漏（未拿到公网候选）", null);
                else if (f.BrRtc.Contains(f.ProbeIp ?? "\u0000"))
                    r.Sig("浏览器", "WebRTC 出口", 6, 100, f.BrRtc + " = 出口", null);
                else
                {
                    var first = f.BrRtc.Split(',')[0];
                    var cc = Net.Json(Net.Get("http://ip-api.com/json/" + first + "?fields=countryCode"), "countryCode");
                    r.Sig("浏览器", "WebRTC 出口", 6, 0,
                        f.BrRtc.Split(',').Length + " 个泄漏 · " + (cc ?? "?") + " ≠ " + f.Country,
                        "代理开 TUN 模式接管 UDP，或在浏览器里禁用 WebRTC",
                        "WebRTC 暴露了非代理出口(首个 " + first + (cc != null ? "，归属 " + cc : "") + ")，UDP 绕过了代理",
                        "代理开 TUN 全局或浏览器禁用 WebRTC");
                }

                if (f.BrTz == f.SysTimezone || Tz.ToWindows(f.BrTz) == f.SysTimezone)
                    r.Sig("浏览器", "浏览器时区", 3, 100, f.BrTz + src, null);
                else
                    r.Sig("浏览器", "浏览器时区", 3, 25, f.BrTz + " ≠ " + f.SysTimezone,
                        "重启浏览器，让它重新读系统时区",
                        "浏览器时区 " + f.BrTz + " 与系统时区不一致", "重启浏览器");

                var browserLanguage = LocalePolicy.Evaluate(f.BrLangs, f.Country);
                if (browserLanguage.Kind == LocaleMatchKind.Conflict)
                    r.Sig("浏览器", "浏览器语言", 2, 40, f.BrLangs + " vs " + f.Country,
                        LocalePolicy.BrowserLanguageHint(f.Country, f.BrUa),
                        "浏览器语言 " + f.BrLangs + " 与出口地区 " + f.Country + " 的中文变体矛盾（网页端登录时直接可见）");
                else
                    r.Sig("浏览器", "浏览器语言", 2, 100, f.BrLangs ?? "?", null);

                var rd = (f.BrWebgl ?? "");
                if (!string.IsNullOrEmpty(f.BrFonts)) rd += " · " + f.BrFonts.Split(',').Length + " 中文字体";
                r.Sig("浏览器", "渲染环境", 2, string.IsNullOrEmpty(f.BrWebgl) ? 50 : 100,
                    string.IsNullOrEmpty(f.BrWebgl) ? "未取到 GPU 信息" : rd, "从托盘点「重新体检」重新采集");

                var intlLocale = LocalePolicy.Evaluate(f.BrLocale, f.Country);
                if (intlLocale.Kind == LocaleMatchKind.Conflict)
                    r.Sig("浏览器", "Intl 区域设置", 1, 50, f.BrLocale + " vs " + f.Country,
                        LocalePolicy.BrowserLanguageHint(f.Country, f.BrUa));
                else
                    r.Sig("浏览器", "Intl 区域设置", 1, 100, f.BrLocale ?? "?", null);

                // Client Hints(Chromium 独有): 平台标识要和真实系统对得上
                if (!real) r.Sig("浏览器", "Client Hints", 2, 70, "内置引擎未采集", null);
                else if (string.IsNullOrEmpty(f.BrChPlat)) r.Sig("浏览器", "Client Hints", 2, 100, "Safari/Firefox 不提供", null);
                else if (f.BrChPlat.IndexOf("Windows", StringComparison.OrdinalIgnoreCase) >= 0)
                    r.Sig("浏览器", "Client Hints", 2, 100, f.BrChPlat, null);
                else
                    r.Sig("浏览器", "Client Hints", 2, 0, f.BrChPlat + " ≠ Windows",
                        "关掉浏览器里改 UA 的插件，用原生浏览器打开 claude.ai",
                        "浏览器上报的平台 " + f.BrChPlat + " 与真实系统不符，UA 被改过或运行在异常容器中");

                if (!real || string.IsNullOrEmpty(f.BrAccept))
                    r.Sig("浏览器", "HTTP 语言首标", 1, 100, f.BrAccept ?? "未采集", null);
                else
                {
                    var acceptFirst = LocalePolicy.PrimaryTag(f.BrAccept);
                    var browserFirst = LocalePolicy.PrimaryTag(f.BrLangs);
                    var httpLanguage = LocalePolicy.Evaluate(f.BrAccept, f.Country);
                    if (!string.IsNullOrEmpty(acceptFirst) && !string.IsNullOrEmpty(browserFirst)
                        && !string.Equals(acceptFirst, browserFirst, StringComparison.OrdinalIgnoreCase))
                        r.Sig("浏览器", "HTTP 语言首标", 1, 0, acceptFirst + " ≠ " + browserFirst,
                            "统一浏览器首选语言，并关闭修改请求头的扩展",
                            "HTTP Accept-Language 与 navigator.languages 首选语言不一致，浏览器画像存在矛盾");
                    else if (httpLanguage.Kind == LocaleMatchKind.Conflict)
                        r.Sig("浏览器", "HTTP 语言首标", 1, 0, f.BrAccept + " vs " + f.Country,
                            LocalePolicy.BrowserLanguageHint(f.Country, f.BrUa),
                            "请求头 Accept-Language: " + f.BrAccept + " 与出口 " + f.Country + " 的中文变体矛盾，服务端第一眼就能看到");
                    else
                        r.Sig("浏览器", "HTTP 语言首标", 1, 100,
                            f.BrAccept.Length > 24 ? f.BrAccept.Substring(0, 24) : f.BrAccept, null);
                }
            }

            // 关键项一票否决: 这几项任一不满分，总分再高也不能算"可用"。
            // 90 分可能是"丢了 10 分轻微项"，也可能是"WebRTC 泄漏 6 分 + 时区不符 5 分"，
            // 后者真实出口已经暴露，风险天差地别。
            var critical = new[] { "出口国家", "Anthropic API 可达", "系统时区匹配出口",
                                   "WebRTC 出口", "IPv6 出口", "三路出口一致" };
            var critFail = string.Join("、", r.Signals
                .Where(x => critical.Contains(x.Label) && x.Points < x.Weight)
                .Select(x => x.Label).ToArray());

            if (Collector.IsUnsupported(f.Country))
            { r.Grade = "高风险"; r.Verdict = Collector.RegionNote(f.Country); }
            // 三路出口不一致 = 分流模式，账号画像在多地区间跳变，是风控最敏感的信号之一。
            // 只按扣分算(才 5 分)会让 80 多分的环境显示"良好"，与红色图标自相矛盾 —— 硬降级。
            else if (!f.Consistent)
            {
                r.Grade = "风险";
                r.Verdict = "出口 IP 分流(国内 " + (f.CnIp ?? "?") + " / 国外 " + (f.IntlIp ?? "?")
                          + ")，账号画像会在多地区间跳变，不建议使用";
            }
            // 档位措辞按二元标准: 只有绿档说"可用"，其余一律明说"不建议使用"
            else if (r.Score >= 90 && critFail.Length == 0) { r.Grade = "优秀"; r.Verdict = "环境适合运行 Claude"; }
            else if (critFail.Length > 0)
            {
                r.Grade = r.Score < 50 ? "危险" : r.Score < 70 ? "高风险" : "有风险";
                r.Verdict = "关键项未达标（" + critFail + "），不建议使用 Claude";
            }
            else if (r.Score >= 70) { r.Grade = "有风险"; r.Verdict = "存在矛盾信号，不建议使用 Claude，先按提示修复"; }
            else if (r.Score >= 50) { r.Grade = "高风险"; r.Verdict = "多项信号冲突，不建议在当前环境登录或使用 Claude"; }
            else { r.Grade = "危险"; r.Verdict = "环境画像严重冲突，使用 Claude 有较高封号风险"; }
            return r;
        }
    }

    // ── 修复 ────────────────────────────────────────────────────
    class FixOutcome
    {
        public string Label, Detail;
        public bool Success;
    }

    static class Fixer
    {
        // 改时区和 DNS 都要管理员，用 runas 提权跑一条命令；失败原因必须回传给用户。
        static bool RunElevated(string exe, string args, out string error)
        {
            error = null;
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
                    if (p == null) { error = "无法启动修复命令"; return false; }
                    if (!p.WaitForExit(30000)) { error = "执行超时，设置可能尚未生效"; return false; }
                    if (p.ExitCode != 0) { error = "命令退出码 " + p.ExitCode; return false; }
                    return true;
                }
            }
            catch (Exception e)
            {
                error = e.Message; // 包括用户取消 UAC
                return false;
            }
        }

        public static FixOutcome FixTimezone(string windowsTzId)
        {
            var result = new FixOutcome { Label = "系统时区" };
            if (string.IsNullOrEmpty(windowsTzId))
            { result.Detail = "没有可用的 Windows 时区映射"; return result; }
            string error;
            result.Success = RunElevated("cmd.exe", "/c tzutil /s \"" + windowsTzId + "\"", out error);
            result.Detail = result.Success ? "已改为 " + windowsTzId : "修改失败：" + (error ?? "未知错误");
            Paths.Write("fix: 时区 -> " + windowsTzId + (result.Success ? " 成功" : " 失败: " + error));
            return result;
        }

        // Set-Culture 只修改当前用户的区域格式，不修改 Windows 显示语言、键盘或语言包。
        public static FixOutcome FixCulture(string cultureName)
        {
            var result = new FixOutcome { Label = "当前用户区域格式" };
            try { CultureInfo.GetCultureInfo(cultureName); }
            catch
            {
                result.Detail = "修改失败：Windows 不识别区域 " + (cultureName ?? "?");
                return result;
            }

            try
            {
                var escaped = cultureName.Replace("'", "''");
                var args = "-NoProfile -NonInteractive -Command \"$ErrorActionPreference='Stop'; Set-Culture -CultureInfo '"
                         + escaped + "'\"";
                var psi = new ProcessStartInfo("powershell.exe", args)
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using (var p = Process.Start(psi))
                {
                    if (p == null) throw new InvalidOperationException("无法启动 PowerShell");
                    if (!p.WaitForExit(30000))
                    {
                        result.Detail = "修改失败：执行超时";
                        return result;
                    }
                    var stdout = p.StandardOutput.ReadToEnd().Trim();
                    var stderr = p.StandardError.ReadToEnd().Trim();
                    if (p.ExitCode != 0)
                    {
                        result.Detail = "修改失败：" + (stderr.Length > 0 ? stderr : (stdout.Length > 0 ? stdout : "PowerShell 退出码 " + p.ExitCode));
                        return result;
                    }
                }

                var actual = LocalePolicy.CurrentUserCultureName();
                result.Success = string.Equals(actual, cultureName, StringComparison.OrdinalIgnoreCase);
                result.Detail = result.Success
                    ? "已改为 " + cultureName + "（显示语言和键盘未改）"
                    : "命令已执行，但当前用户区域仍为 " + actual + "；请注销后检查";
                Paths.Write("fix: 当前用户区域 -> " + cultureName + (result.Success ? " 成功" : " 未验证: " + actual));
                return result;
            }
            catch (Exception e)
            {
                result.Detail = "修改失败：" + e.Message;
                Paths.Write("fix: 当前用户区域 -> " + cultureName + " 失败: " + e.Message);
                return result;
            }
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

        public static FixOutcome FixDns(string nic)
        {
            var result = new FixOutcome { Label = "DNS 设置" };
            if (string.IsNullOrEmpty(nic))
            { result.Detail = "修改失败：未找到活动网络适配器"; return result; }
            var good = VerifyDns("1.1.1.1", "8.8.8.8", "9.9.9.9");
            if (good.Count == 0)
            {
                result.Detail = "修改失败：候选 DNS 均未通过 claude.ai 解析验证";
                Paths.Write("fix: 候选 DNS 全部解析异常，放弃");
                return result;
            }

            var sb = new StringBuilder();
            sb.Append("/c netsh interface ipv4 set dnsservers name=\"" + nic + "\" static " + good[0] + " primary validate=no");
            for (int i = 1; i < good.Count; i++)
                sb.Append(" && netsh interface ipv4 add dnsservers name=\"" + nic + "\" " + good[i] + " index=" + (i + 1) + " validate=no");
            sb.Append(" && ipconfig /flushdns");
            string error;
            result.Success = RunElevated("cmd.exe", sb.ToString(), out error);
            result.Detail = result.Success
                ? nic + " 已改为 " + string.Join(", ", good.ToArray())
                : "修改失败：" + (error ?? "未知错误");
            Paths.Write("fix: DNS " + nic + " -> " + string.Join(",", good.ToArray()) + (result.Success ? " 成功" : " 失败: " + error));
            return result;
        }

        public static FixOutcome DisablePac()
        {
            var result = new FixOutcome { Label = "PAC 自动分流" };
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Internet Settings", true))
                {
                    if (k == null) { result.Detail = "关闭失败：无法打开当前用户代理设置"; return result; }
                    k.DeleteValue("AutoConfigURL", false);
                }
                result.Success = true;
                result.Detail = "已关闭";
                Paths.Write("fix: 已关闭 PAC 自动分流");
                return result;
            }
            catch (Exception e)
            {
                result.Detail = "关闭失败：" + e.Message;
                Paths.Write("fix: 关闭 PAC 失败: " + e.Message);
                return result;
            }
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
                // 原来死等 2 秒就覆盖：本进程没退干净时单实例 Mutex 还占着，新实例会被
                // 静默挡掉，升级完 App 就再也不出现了。改成轮询——正在运行的 exe 是锁住的，
                // copy 能成功本身就证明旧进程已经退干净。最多等 30 秒，等不到也要把旧版拉回来，
                // 不能让用户落到「没有 App」的状态。
                File.WriteAllText(bat,
                    "@echo off\r\n" +
                    "set /a n=0\r\n" +
                    ":wait\r\n" +
                    "copy /Y \"" + newExe + "\" \"" + self + "\" >nul 2>&1\r\n" +
                    "if not errorlevel 1 goto ok\r\n" +
                    "set /a n+=1\r\n" +
                    "if %n% geq 30 goto giveup\r\n" +
                    "ping 127.0.0.1 -n 2 >nul\r\n" +
                    "goto wait\r\n" +
                    ":ok\r\n" +
                    ":giveup\r\n" +
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
        DateTime notifiedAt = DateTime.MinValue;
        bool promptingUpgrade;

        // MessageBox 会阻塞消息循环，不能在 BuildMenu 里同步弹
        void BeginInvokeSoon(Action a)
        {
            var t = new System.Windows.Forms.Timer { Interval = 200 };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); a(); };
            t.Start();
        }
        bool busy, probeBusy, fixing;
        BrowserBridge bridge;
        // 检测间隔存注册表，重启后保持
        int ScanInterval
        {
            get
            {
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(@"Software\CheckClaude"))
                    {
                        var v = k == null ? null : k.GetValue("scanInterval");
                        if (v != null)
                        {
                            int seconds = Convert.ToInt32(v);
                            if (seconds >= 30 && seconds <= 86400) return seconds;
                        }
                    }
                }
                catch { }
                return 60;
            }
            set
            {
                try
                {
                    using (var k = Registry.CurrentUser.CreateSubKey(@"Software\CheckClaude"))
                        if (k != null) k.SetValue("scanInterval", value);
                }
                catch { }
            }
        }
        volatile bool phase;   // true = 正在检测(内部分两步，不暴露给用户)

        public TrayApp()
        {
            Paths.Ensure();
            icon = new NotifyIcon { Visible = true, Text = "CheckClaude", Icon = MakeIcon(Color.Gray) };
            icon.ContextMenuStrip = new ContextMenuStrip();
            icon.MouseUp += (s, e) => { if (e.Button == MouseButtons.Left) icon.ContextMenuStrip.Show(Cursor.Position); };
            BuildMenu();

            scanTimer = new System.Windows.Forms.Timer { Interval = ScanInterval * 1000 };
            scanTimer.Tick += (s, e) => RunExitProbe();
            scanTimer.Start();

            updTimer = new System.Windows.Forms.Timer { Interval = 2 * 3600 * 1000 };    // 每 2 小时查一次新版本
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

        // 用户的标准是二元的: 不是绿色就别用 Claude。
        // 绿=可用(>=85 分且三路一致)，橙=有隐患，红=不建议使用。
        static Color ScoreColor(int score, bool consistent)
        {
            if (score < 0) return Color.Gray;
            if (score >= 90 && consistent) return Color.FromArgb(52, 199, 89);
            if (score >= 70 && consistent) return Color.FromArgb(255, 149, 0);
            return Color.FromArgb(255, 59, 48);
        }

        // 掉档时主动弹气泡 —— 用户不会一直盯着托盘图标。同一档不重复打扰。
        string lastSafetyTier = "";
        void AlertIfUnsafe(int score, bool consistent, string verdict)
        {
            if (score < 0) return;
            string tier = (score >= 90 && consistent) ? "safe"
                        : (score >= 70 && consistent) ? "warn" : "unsafe";
            string prev = lastSafetyTier;
            lastSafetyTier = tier;
            if (string.IsNullOrEmpty(prev) || tier == prev) return;

            if (tier == "safe")
                icon.ShowBalloonTip(6000, "Claude 环境已恢复", score + " 分，可以正常使用", ToolTipIcon.Info);
            else if (tier == "warn")
                icon.ShowBalloonTip(8000, "⚠️ 不建议使用 Claude",
                    "环境 " + score + " 分存在隐患，右键托盘查看还差哪几项", ToolTipIcon.Warning);
            else
                icon.ShowBalloonTip(10000, "⚠️ 不建议使用 Claude",
                    string.IsNullOrEmpty(verdict) ? "环境 " + score + " 分，存在安全风险" : verdict,
                    ToolTipIcon.Warning);
        }

        void RunExitProbe()
        {
            if (busy || phase || probeBusy || fixing) return;
            probeBusy = true;
            Task.Run(() =>
            {
                Facts latest = null;
                try { latest = Collector.CollectExit(); }
                catch (Exception e) { Paths.Write("出口探测异常: " + e.Message); }
                Sync(() =>
                {
                    probeBusy = false;
                    if (latest == null || string.IsNullOrEmpty(latest.ProbeIp)) return;
                    if (report == null)
                    {
                        RunCheck(false, true);
                        return;
                    }
                    bool ipChanged = !string.IsNullOrEmpty(lastExitIp) && latest.ProbeIp != lastExitIp;
                    bool consistencyChanged = report.F.Consistent != latest.Consistent;
                    if (ipChanged)
                    {
                        icon.ShowBalloonTip(6000, "CheckClaude 出口 IP 变化",
                            lastExitIp + " → " + latest.ProbeIp + "，正在重新体检", ToolTipIcon.Warning);
                        RunCheck(false, true);
                    }
                    else if (consistencyChanged)
                    {
                        icon.ShowBalloonTip(6000,
                            latest.Consistent ? "CheckClaude 出口已恢复正常" : "CheckClaude 出口 IP 异常",
                            latest.Consistent ? "国内、国外、谷歌三路出口已恢复一致" : "三路出口不一致，正在重新体检",
                            latest.Consistent ? ToolTipIcon.Info : ToolTipIcon.Warning);
                        RunCheck(false, false);
                    }
                    else
                    {
                        // 完整体检无需重跑，但菜单里的三路明细与 Google 可达性要保持最新。
                        report.F.CnIp = latest.CnIp;
                        report.F.IntlIp = latest.IntlIp;
                        report.F.GfwIp = latest.GfwIp;
                        report.F.ProbeIp = latest.ProbeIp;
                        report.F.GoogleReachable = latest.GoogleReachable;
                        report.F.Consistent = latest.Consistent;
                        BuildMenu();
                    }
                });
            });
        }

        // 体检两步: ① 系统检测(本地信号) ② 浏览器指纹采集(打开浏览器，采完自动关)
        // 对用户是一次点击，内部分几步不暴露。
        void RunCheck(bool manual, bool withBrowser = true)
        {
            if (busy || phase || fixing) return;
            busy = true;
            phase = true;
            Task.Run(() =>
            {
                Facts f = null;
                bool browserRequested = withBrowser;
                try { f = Collector.Collect(); } catch (Exception e) { Paths.Write("体检异常: " + e.Message); }
                if (f != null)
                {
                    // 出口 IP 变了才记一笔，"出口稳定性"就是数这些行；同时重采浏览器信号，
                    // 避免浏览器画像还挂着上一个出口的数据。
                    var cur = f.ProbeIp ?? "none";
                    bool exitChanged = !string.IsNullOrEmpty(lastExitIp) && lastExitIp != cur;
                    if (exitChanged)
                    {
                        Paths.Write("出口 IP 变化: " + lastExitIp + " -> " + cur);
                        browserRequested = true;
                    }
                    lastExitIp = cur;
                    report = Report.Build(f);
                    Paths.Write(string.Format("体检: {0}/100 {1} country={2} api={3}",
                        report.Score, report.Grade, f.Country ?? "?", f.ApiCode));
                }
                busy = false;
                Sync(BuildMenu);

                // 第二步：手动完整体检、首次启动或出口变化时采集真实浏览器指纹。
                // 最终分数通知要等浏览器结果写回并重新评分后再显示。
                bool shouldStartBrowser = browserRequested && bridge == null;
                if (shouldStartBrowser)
                {
                    Sync(() =>
                    {
                        bridge = new BrowserBridge(Path.Combine(Paths.Dir, "browser_signals"), ok =>
                        {
                            bridge = null;
                            phase = false;
                            if (ok)
                            {
                                RunCheck(manual, false);
                            }
                            else
                            {
                                Sync(BuildMenu);
                                if (manual && report != null)
                                    Sync(() => icon.ShowBalloonTip(4000, "CheckClaude",
                                        report.Score + " 分 · " + report.Grade + "（浏览器信号未更新）",
                                        ToolTipIcon.Warning));
                            }
                        });
                        bridge.Start();
                    });
                }
                else
                {
                    phase = false;
                    Sync(BuildMenu);
                    if (manual && report != null)
                        Sync(() => icon.ShowBalloonTip(4000, "CheckClaude",
                            report.Score + " 分 · " + report.Grade, ToolTipIcon.Info));
                }
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
            bool consistent = report != null && report.F.Consistent;
            AlertIfUnsafe(score, consistent, report == null ? "" : report.Verdict);
            icon.Icon = MakeIcon(ScoreColor(score, consistent));
            icon.Text = (report == null ? "CheckClaude 检测中…" : ("CheckClaude " + score + " 分 · " + report.Grade))
                      + (Updater.HasUpdate ? "（有新版 v" + Updater.Latest + "）" : "");

            if (report == null) { m.Items.Add(Item("正在检测…")); }
            else
            {
                var f = report.F;
                var r = report;
                bool highRisk = report.Grade == "高风险" || report.Grade == "危险" || report.Grade == "风险";
                var head = new ToolStripMenuItem("Claude 环境 " + score + " 分 · " + report.Grade);
                if (highRisk) head.ForeColor = Color.FromArgb(200, 30, 30);
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
                    if (highRisk && !s.Ok) li.ForeColor = Color.FromArgb(200, 30, 30);
                    head.DropDownItems.Add(li);
                }
                head.DropDownItems.Add(new ToolStripSeparator());
                head.DropDownItems.Add(Item("出口: " + (f.ProbeIp ?? "?") + " · " + (f.City ?? "") + " · " + (f.Asn ?? "?")));
                head.DropDownItems.Add(Item("系统: " + f.SysTimezone + " · " + f.Locale + " · " + f.ProxyMode));
                head.DropDownItems.Add(Item("浏览器画像: " + (f.BrFrom ?? "未采集（点「重新体检（含浏览器采集）」）")));
                head.DropDownItems.Add(Item("DNS: " + f.DnsScope + " · claude.ai → " + f.DnsVerdict));
                head.DropDownItems.Add(Item("CLI: " + (f.ClaudeVer ?? "未检测到") + " · 接口 " +
                    (string.IsNullOrEmpty(f.ClaudeBase) ? "官方" : f.ClaudeBase)));
                m.Items.Add(head);

                if (phase || fixing) m.Items.Add(Item(fixing ? "正在修复…" : "正在检测…"));
                else m.Items.Add(Item("重新体检（含浏览器采集）", (s, e) => RunCheck(true)));
                // 始终摆在这儿；只有手动项时仍可点击查看完整方案。
                if (fixing)
                    m.Items.Add(Item("⚡ 一键修复（执行中…）", null, false));
                else if (!string.IsNullOrEmpty(report.FixList))
                    m.Items.Add(Item("⚡ 一键修复：" + report.FixList, (s, e) => DoFix()));
                else if (score >= 100)
                    m.Items.Add(Item("⚡ 一键修复（已满分，无需修复）", null, false));
                else
                    m.Items.Add(Item("⚡ 一键修复 / 查看方案（剩余项需手动处理）", (s, e) => DoFix()));

                // 手动处理步骤常驻菜单: 修复弹窗是一次性的，关掉就找不回来了
                var manual = r.ManualGains;
                if (manual.Count > 0)
                {
                    var mm = new ToolStripMenuItem("📋 手动处理步骤（" + manual.Count + " 项）");
                    foreach (var g in manual)
                    {
                        mm.DropDownItems.Add(Item(g.Label + "   +" + (g.Weight - g.Points) + " 分"));
                        foreach (var part in (g.Hint ?? "").Split('；'))
                            if (part.Trim().Length > 0) mm.DropDownItems.Add(Item("      " + part.Trim()));
                        mm.DropDownItems.Add(new ToolStripSeparator());
                    }
                    if (manual.Any(IsBrowserLanguageSignal))
                        mm.DropDownItems.Add(Item("打开浏览器语言设置", (s2, e2) => OpenBrowserLanguageSettings(r.F)));
                    mm.DropDownItems.Add(Item("重新体检（含浏览器采集）", (s2, e2) => RunCheck(true)));
                    m.Items.Add(mm);
                }

                m.Items.Add(new ToolStripSeparator());
                // 三路视角明细，与 macOS 版菜单对齐
                m.Items.Add(Item("国内视角: " + (f.CnIp ?? "?")));
                m.Items.Add(Item("国外视角: " + (f.IntlIp ?? "?")));
                m.Items.Add(Item("谷歌/被封: " + (f.GfwIp ?? "?") + "  (Google: " + (f.GoogleReachable ? "可达" : "不可达") + ")"));
                m.Items.Add(new ToolStripSeparator());
                m.Items.Add(Item("出口侧时区: " + (f.IpTimezone ?? "?")));
                m.Items.Add(Item("系统时区: " + f.SysTimezone));
                // 时间戳跟着系统时区走，而系统时区跟着出口走
                m.Items.Add(Item((f.Country == "CN" ? "本地时间: " : "海外时间: ") + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")));
            }

            m.Items.Add(new ToolStripSeparator());
            // 名字必须和「重新体检」分得开：这个入口不重采浏览器，改完浏览器设置点它没用
            m.Items.Add(Item("立即检测（不含浏览器）", (s, e) => RunCheck(true, false)));
            var iv = new ToolStripMenuItem("检测间隔");
            foreach (var opt in new[] { new { L = "1 分钟", V = 60 }, new { L = "2 分钟", V = 120 },
                                        new { L = "5 分钟", V = 300 }, new { L = "10 分钟", V = 600 } })
            {
                var it = new ToolStripMenuItem(opt.L) { Checked = ScanInterval == opt.V };
                int v = opt.V;
                it.Click += (s, e) => { ScanInterval = v; scanTimer.Interval = v * 1000; BuildMenu(); };
                iv.DropDownItems.Add(it);
            }
            m.Items.Add(iv);
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
                // 有新版就持续提醒，但每天最多一次 —— 只弹一次的话，错过就再也不提了
                // 发现新版直接弹窗问要不要装 —— 气泡只是告知，用户还得自己去托盘找入口，太绕。
                // 每天最多弹一次: 只弹一次会错过，每次重画菜单都弹会烦死人。
                if (!promptingUpgrade &&
                    (notifiedVersion != Updater.Latest || (DateTime.Now - notifiedAt).TotalHours >= 24))
                {
                    notifiedVersion = Updater.Latest;
                    notifiedAt = DateTime.Now;
                    promptingUpgrade = true;
                    var latest = Updater.Latest;
                    BeginInvokeSoon(() =>
                    {
                        try
                        {
                            var r = MessageBox.Show(
                                "当前 v" + Application.ProductVersion + "。\r\n\r\n" +
                                "点「是」自动下载、安装并重启，无需其它操作。",
                                "CheckClaude 有新版本 v" + latest,
                                MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                            if (r == DialogResult.Yes)
                            {
                                icon.ShowBalloonTip(5000, "正在升级到 v" + latest,
                                    "下载完成后会自动重启", ToolTipIcon.Info);
                                Updater.Install();
                            }
                        }
                        finally { promptingUpgrade = false; }
                    });
                }
            }
            else
            {
                m.Items.Add(Item("版本 v" + Application.ProductVersion + "（已是最新）"));
                // 点了必须有回音 —— 之前静默执行，已是最新时看着就像"点了没反应"
                m.Items.Add(Item("检查更新", (s, e) => Task.Run(() =>
                {
                    Sync(() => icon.ShowBalloonTip(3000, "CheckClaude", "正在检查更新…", ToolTipIcon.Info));
                    Updater.Check();
                    Sync(() =>
                    {
                        BuildMenu();
                        if (Updater.HasUpdate)
                            icon.ShowBalloonTip(8000, "发现新版本 v" + Updater.Latest,
                                "右键托盘 →「⬆ 升级到 v" + Updater.Latest + "」一键更新", ToolTipIcon.Info);
                        else
                            icon.ShowBalloonTip(5000, "已经是最新版本",
                                "v" + Application.ProductVersion, ToolTipIcon.Info);
                    });
                })));
            }
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(Item("官方网站",
                (s, e) => { try { Process.Start("https://www.yinso.com/labs/"); } catch { } }));
            m.Items.Add(new ToolStripSeparator());
            // 必须 Dispose：只设 Visible=false 会把图标留在托盘里直到鼠标划过，
            // 用户以为没退掉。退出后 Main 里还有一道 Environment.Exit 兜底，
            // 保证进程真正终止、单实例 Mutex 真正释放。
            m.Items.Add(Item("退出", (s, e) => { icon.Visible = false; icon.Dispose(); Application.Exit(); }));
        }

        static void AppendManualPlan(StringBuilder sb, List<Signal> manual)
        {
            if (manual.Count == 0) return;
            sb.AppendLine("需要手动处理：");
            int i = 1;
            foreach (var g in manual)
                sb.AppendLine("  " + i++ + ". " + g.Label + "（+" + (g.Weight - g.Points) + " 分）\r\n     " + (g.Hint ?? "查看检测详情"));
        }

        static bool IsBrowserLanguageSignal(Signal signal)
        {
            return signal != null && (signal.Label == "浏览器语言" || signal.Label == "Intl 区域设置"
                || signal.Label == "HTTP 语言首标");
        }

        static void OpenBrowserLanguageSettings(Facts facts)
        {
            string browser = LocalePolicy.BrowserName(facts == null ? null : facts.BrUa);
            string exe = null, url = null;
            if (browser == "Google Chrome") { exe = "chrome.exe"; url = "chrome://settings/languages"; }
            else if (browser == "Microsoft Edge") { exe = "msedge.exe"; url = "edge://settings/languages"; }
            else if (browser == "Firefox") { exe = "firefox.exe"; url = "about:preferences#general"; }
            try
            {
                if (exe == null) throw new InvalidOperationException("未识别浏览器");
                Process.Start(new ProcessStartInfo(exe, url) { UseShellExecute = true });
            }
            catch
            {
                try { Process.Start(new ProcessStartInfo("ms-settings:regionlanguage") { UseShellExecute = true }); }
                catch { MessageBox.Show("请按“手动处理步骤”进入浏览器语言设置。", "CheckClaude", MessageBoxButtons.OK, MessageBoxIcon.Information); }
            }
        }

        static List<string> AutoFixPlan(Report r)
        {
            var plan = new List<string>();
            if (r.FixableTz != null)
                plan.Add("系统时区：" + r.F.SysTimezone + " → " + (r.F.IpTimezone ?? r.FixableTz) + "（" + r.FixableTz + "）");
            if (r.FixableCulture != null)
                plan.Add("当前用户区域格式：" + (r.F.Locale ?? "?") + " → " + r.FixableCulture + "（不改显示语言和键盘）");
            if (r.FixablePac)
                plan.Add("PAC 自动分流：开启 → 关闭");
            if (r.FixableDns)
                plan.Add("DNS 设置：" + (string.IsNullOrEmpty(r.F.DnsServers) ? "当前配置" : r.F.DnsServers)
                    + " → 经 claude.ai 验证通过的公共 DNS");
            return plan;
        }

        void DoFix()
        {
            if (report == null || fixing) return;
            var r = report;
            var autoPlan = AutoFixPlan(r);
            var manual = r.ManualGains;

            if (autoPlan.Count == 0)
            {
                var onlyManual = new StringBuilder("当前没有可安全自动修改的项目。\r\n\r\n");
                AppendManualPlan(onlyManual, manual);
                onlyManual.AppendLine("\r\n完成后请从托盘菜单点「重新体检」。");
                MessageBox.Show(onlyManual.ToString(), "CheckClaude 手动处理方案",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var confirm = new StringBuilder("将按顺序执行以下自动修改：\r\n");
            for (int i = 0; i < autoPlan.Count; i++)
                confirm.AppendLine("  " + (i + 1) + ". " + autoPlan[i]);
            if (manual.Count > 0)
            {
                confirm.AppendLine();
                AppendManualPlan(confirm, manual);
            }
            confirm.AppendLine("\r\n每项独立执行；失败不会回滚已成功项目，并会显示具体原因。是否开始？");
            if (MessageBox.Show(confirm.ToString(), "确认一键修复",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;

            fixing = true;
            BuildMenu();
            Task.Run(() =>
            {
                var outcomes = new List<FixOutcome>();
                try
                {
                    if (r.FixableTz != null) outcomes.Add(Fixer.FixTimezone(r.FixableTz));
                    if (r.FixableCulture != null) outcomes.Add(Fixer.FixCulture(r.FixableCulture));
                    if (r.FixablePac) outcomes.Add(Fixer.DisablePac());
                    if (r.FixableDns) outcomes.Add(Fixer.FixDns(r.F.ActiveNic));
                }
                catch (Exception e)
                {
                    outcomes.Add(new FixOutcome { Label = "修复流程", Detail = "执行失败：" + e.Message, Success = false });
                    Paths.Write("fix: 修复流程异常: " + e.Message);
                }

                Sync(() =>
                {
                    fixing = false;
                    BuildMenu();
                    int succeeded = outcomes.Count(x => x.Success);
                    var result = new StringBuilder();
                    result.AppendLine("自动修复结果（" + succeeded + "/" + outcomes.Count + " 成功）：\r\n");
                    foreach (var outcome in outcomes)
                        result.AppendLine((outcome.Success ? "✓ " : "✗ ") + outcome.Label + "：" + outcome.Detail);
                    if (manual.Count > 0)
                    {
                        result.AppendLine();
                        AppendManualPlan(result, manual);
                    }
                    result.AppendLine("\r\n关闭此窗口后会重新体检；浏览器语言等手动项不会被程序直接修改。");
                    MessageBox.Show(result.ToString(), "CheckClaude 修复结果",
                        MessageBoxButtons.OK, succeeded == outcomes.Count ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
                    icon.ShowBalloonTip(5000, "CheckClaude", "修复步骤已执行，正在重新体检", ToolTipIcon.Info);
                    RunCheck(false);
                });
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
            using (new Mutex(true, @"Local\CheckClaude.SingleInstance", out created))
            {
                if (!created)
                {
                    // 原来是静默 return 0：用户双击后屏幕上什么都不发生，体感就是「打不开」。
                    // 托盘图标此刻归另一个实例所有，这里只能用对话框告诉用户去哪找。
                    MessageBox.Show("CheckClaude 已经在运行了，图标在任务栏右下角的托盘区。",
                        "CheckClaude", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
            }
            // 兜底：有前台线程残留时进程不会自己结束，Mutex 就一直占着，
            // 下次启动会被自己挡在门外。
            Environment.Exit(0);
            return 0;
        }
    }
}
