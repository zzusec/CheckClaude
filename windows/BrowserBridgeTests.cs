using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

namespace CheckClaude
{
    static class BrowserBridgeTests
    {
        static int failures;

        static void Check(string name, bool ok)
        {
            Console.WriteLine((ok ? "  PASS " : "  FAIL ") + name);
            if (!ok) failures++;
        }

        static int Request(string url, string method, string body, out string responseBody)
        {
            responseBody = "";
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = method;
                req.Timeout = 3000;
                req.UserAgent = "CheckClaude-Bridge-Test";
                req.Headers[HttpRequestHeader.AcceptLanguage] = "en-US,en;q=0.9";
                if (body != null)
                {
                    var bytes = Encoding.UTF8.GetBytes(body);
                    req.ContentType = "text/plain; charset=utf-8";
                    req.ContentLength = bytes.Length;
                    using (var stream = req.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
                }
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var reader = new StreamReader(resp.GetResponseStream()))
                {
                    responseBody = reader.ReadToEnd();
                    return (int)resp.StatusCode;
                }
            }
            catch (WebException e)
            {
                var resp = e.Response as HttpWebResponse;
                if (resp == null) return 0;
                int status = (int)resp.StatusCode;
                using (resp)
                using (var reader = new StreamReader(resp.GetResponseStream()))
                    responseBody = reader.ReadToEnd();
                return status;
            }
        }

        static void TestNormalCollectionAndAuth()
        {
            var dir = Path.Combine(Path.GetTempPath(), "CheckClaude-bridge-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "browser_signals");
            string openedUrl = null;
            bool doneOk = false;
            int doneCount = 0;
            var opened = new ManualResetEvent(false);
            var done = new ManualResetEvent(false);
            var bridge = new BrowserBridge(path, ok =>
            {
                doneOk = ok;
                Interlocked.Increment(ref doneCount);
                done.Set();
            }, 1000, url => { openedUrl = url; opened.Set(); });

            bridge.Start();
            Check("调用默认浏览器启动器", opened.WaitOne(2000) && !string.IsNullOrEmpty(openedUrl));
            if (string.IsNullOrEmpty(openedUrl)) return;

            string text;
            var badUrl = openedUrl.Substring(0, openedUrl.IndexOf("?t=", StringComparison.Ordinal)) + "?t=bad";
            Check("错误 token 返回 403", Request(badUrl, "GET", null, out text) == 403);
            Check("正确 token 返回采集页", Request(openedUrl, "GET", null, out text) == 200 && text.Contains("CheckClaude 浏览器指纹检测"));
            Check("超大回传返回 413", Request(openedUrl.Replace("/c?", "/r?"), "POST", new string('x', 140000), out text) == 413);

            var body = "tz=America/Los_Angeles\nlanguages=en-US,en\nlocale=en-US\n" +
                       "rtc_srflx=1.2.3.4\nwebgl=Test GPU\nfonts=Microsoft YaHei";
            Check("正常回传返回 200", Request(openedUrl.Replace("/c?", "/r?"), "POST", body, out text) == 200);
            Check("成功回调", done.WaitOne(2000) && doneOk);
            Check("信号文件已写入", File.Exists(path));
            if (File.Exists(path))
            {
                var saved = File.ReadAllText(path);
                Check("保存真实浏览器来源", saved.Contains("source=browser"));
                Check("保存浏览器时区", saved.Contains("tz=America/Los_Angeles"));
                Check("保存 HTTP 语言首标", saved.Contains("accept_lang=en-US,en;q=0.9"));
                Check("保存 User-Agent", saved.Contains("ua=CheckClaude-Bridge-Test"));
            }
            Thread.Sleep(1200);
            Check("成功后超时任务不重复回调", doneCount == 1);
            try { Directory.Delete(dir, true); } catch { }
        }

        static void TestRealBrowserPage()
        {
            var browserPath = Environment.GetEnvironmentVariable("CHECKCLAUDE_TEST_BROWSER");
            if (string.IsNullOrEmpty(browserPath) || !File.Exists(browserPath))
            {
                Check("真实浏览器端到端（未配置浏览器，跳过）", true);
                return;
            }

            var dir = Path.Combine(Path.GetTempPath(), "CheckClaude-browser-e2e-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "browser_signals");
            var profile = Path.Combine(dir, "profile");
            bool doneOk = false;
            var done = new ManualResetEvent(false);
            Process browser = null;
            var bridge = new BrowserBridge(path, ok => { doneOk = ok; done.Set(); }, 25000, url =>
            {
                var args = "--headless=new --disable-gpu --no-first-run --no-default-browser-check " +
                           "--user-data-dir=\"" + profile + "\" --virtual-time-budget=12000 --dump-dom \"" + url + "\"";
                browser = Process.Start(new ProcessStartInfo(browserPath, args)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                });
            });

            bridge.Start();
            Check("真实 Edge 执行采集页并回传", done.WaitOne(30000) && doneOk && File.Exists(path));
            if (File.Exists(path))
            {
                var saved = File.ReadAllText(path);
                Check("真实 Edge 回传时区", saved.Contains("tz=") && !saved.Contains("tz=\r\n"));
                Check("真实 Edge 回传语言", saved.Contains("languages="));
                Check("真实 Edge 回传 Client Hints", saved.Contains("ch_platform=Windows") || saved.Contains("uad_platform=Windows"));
            }
            try { if (browser != null && !browser.HasExited) browser.Kill(); } catch { }
            try { Directory.Delete(dir, true); } catch { }
        }

        static void TestTimeout()
        {
            bool doneOk = true;
            int doneCount = 0;
            var done = new ManualResetEvent(false);
            var bridge = new BrowserBridge(Path.GetTempFileName(), ok =>
            {
                doneOk = ok;
                Interlocked.Increment(ref doneCount);
                done.Set();
            }, 150, url => { });
            bridge.Start();
            Check("采集超时回调失败", done.WaitOne(2000) && !doneOk);
            Check("超时只回调一次", doneCount == 1);
        }

        static void TestBrowserLaunchFailure()
        {
            bool doneOk = true;
            int doneCount = 0;
            var done = new ManualResetEvent(false);
            var bridge = new BrowserBridge(Path.GetTempFileName(), ok =>
            {
                doneOk = ok;
                Interlocked.Increment(ref doneCount);
                done.Set();
            }, 1000, url => { throw new InvalidOperationException("no browser"); });
            bridge.Start();
            Check("浏览器启动失败时安全回退", done.WaitOne(2000) && !doneOk);
            Check("启动失败只回调一次", doneCount == 1);
        }

        static Signal FindSignal(Report report, string label)
        {
            foreach (var signal in report.Signals)
                if (signal.Label == label) return signal;
            return null;
        }

        static bool Full(Report report, string label)
        {
            var signal = FindSignal(report, label);
            return signal != null && signal.Points == signal.Weight;
        }

        static Facts LanguageFacts(string country, string country2, bool countriesAgree,
                                   string systemLocale, string browserLocale)
        {
            return new Facts
            {
                CnIp = "203.0.113.10",
                IntlIp = "203.0.113.10",
                GfwIp = "203.0.113.10",
                ProbeIp = "203.0.113.10",
                GoogleReachable = true,
                Consistent = true,
                Country = country,
                Country2 = country2,
                CountrySourcesAgree = countriesAgree,
                CountryName = country,
                City = "Test",
                Isp = "Test ISP",
                Asn = "AS64500",
                Isp2 = "AS64500 Test ISP",
                AsnMatch = 1,
                Hosting = 0,
                ApiCode = 401,
                WebCode = 200,
                SiteCode = 200,
                Locale = systemLocale,
                LangName = systemLocale.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh" : "en",
                DnsServers = "1.1.1.1",
                DnsScope = "本地/代理接管",
                DnsResult = "160.79.104.10",
                DnsVerdict = "正常(Anthropic)",
                ProxyMode = "TUN 全局",
                VmHost = "物理机",
                IpChanges = 0,
                BrOk = true,
                BrSource = "browser",
                BrTz = TimeZoneInfo.Local.Id,
                BrLangs = browserLocale + ",en-US",
                BrLocale = browserLocale,
                BrRtc = "",
                BrWebgl = "Test GPU",
                BrFonts = "",
                BrChPlat = "Windows",
                BrUa = "Mozilla/5.0 Chrome/140.0.0.0 Safari/537.36",
                BrAccept = browserLocale + ",en-US;q=0.8"
            };
        }

        static void TestLocaleScoring()
        {
            Check("TW zh-TW 规则兼容", LocalePolicy.Evaluate("zh-TW", "TW").Kind == LocaleMatchKind.Compatible);
            Check("TW 英语全局兼容", LocalePolicy.Evaluate("en-US", "TW").Kind == LocaleMatchKind.Compatible);
            Check("TW zh-CN 判定简繁冲突", LocalePolicy.Evaluate("zh-CN", "TW").Kind == LocaleMatchKind.Conflict);
            Check("SG zh-CN 判定兼容", LocalePolicy.Evaluate("zh-CN", "SG").Kind == LocaleMatchKind.Compatible);
            Check("SG zh-TW 判定简繁冲突", LocalePolicy.Evaluate("zh-TW", "SG").Kind == LocaleMatchKind.Conflict);
            Check("US zh-CN 仍判定明确冲突", LocalePolicy.Evaluate("zh-CN", "US").Kind == LocaleMatchKind.Conflict);
            Check("裸 zh 无法确定且不误报", LocalePolicy.Evaluate("zh", "TW").Kind == LocaleMatchKind.Unknown);
            Check("未知非中文语言不误报", LocalePolicy.Evaluate("ja-JP", "TW").Kind == LocaleMatchKind.Unknown);

            var tw = Report.Build(LanguageFacts("TW", "TW", true, "zh-TW", "zh-TW"));
            Check("TW zh-TW 浏览器语言满分", Full(tw, "浏览器语言"));
            Check("TW zh-TW Intl 满分", Full(tw, "Intl 区域设置"));
            Check("TW zh-TW HTTP 语言满分", Full(tw, "HTTP 语言首标"));
            Check("TW zh-TW 系统语言变体满分", Full(tw, "语言变体一致"));
            var twHeaderConflictFacts = LanguageFacts("TW", "TW", true, "zh-TW", "zh-TW");
            twHeaderConflictFacts.BrAccept = "zh-CN,zh;q=0.8";
            var twHeaderConflict = Report.Build(twHeaderConflictFacts);
            Check("HTTP 与 JavaScript 中文变体不同仍扣满", FindSignal(twHeaderConflict, "HTTP 语言首标").Points == 0);

            var twEnglish = Report.Build(LanguageFacts("TW", "TW", true, "zh-TW", "en-US"));
            Check("TW en-US 浏览器语言不扣分", Full(twEnglish, "浏览器语言"));
            Check("TW en-US Intl 不扣分", Full(twEnglish, "Intl 区域设置"));
            Check("TW en-US HTTP 语言不扣分", Full(twEnglish, "HTTP 语言首标"));

            var twConflict = Report.Build(LanguageFacts("TW", "TW", true, "zh-CN", "zh-CN"));
            var twBrowser = FindSignal(twConflict, "浏览器语言");
            var twHttp = FindSignal(twConflict, "HTTP 语言首标");
            Check("TW zh-CN 浏览器语言扣分", twBrowser != null && twBrowser.Points < twBrowser.Weight);
            Check("TW zh-CN HTTP 语言扣分", twHttp != null && twHttp.Points < twHttp.Weight);
            Check("TW 语言建议使用 zh-TW", twBrowser != null && twBrowser.Hint.Contains("zh-TW") && !twBrowser.Hint.Contains("en-US"));
            Check("TW 区域格式可自动修复", twConflict.FixableCulture == "zh-TW");
            Check("自动修复项不混入手动清单", !twConflict.ManualGains.Contains(FindSignal(twConflict, "系统区域匹配出口")));
            Check("浏览器语言仍是手动项", twConflict.ManualGains.Contains(twBrowser));

            var sg = Report.Build(LanguageFacts("SG", "SG", true, "zh-SG", "zh-CN"));
            Check("SG 简体浏览器语言满分", Full(sg, "浏览器语言"));
            Check("SG 简体 Intl 满分", Full(sg, "Intl 区域设置"));
            var sgConflict = Report.Build(LanguageFacts("SG", "SG", true, "zh-SG", "zh-TW"));
            var sgBrowser = FindSignal(sgConflict, "浏览器语言");
            Check("SG 繁体浏览器语言扣分", sgBrowser != null && sgBrowser.Points < sgBrowser.Weight);
            Check("SG 语言建议使用 zh-SG", sgBrowser != null && sgBrowser.Hint.Contains("zh-SG"));

            var disputed = Report.Build(LanguageFacts("TW", "US", false, "zh-CN", "zh-CN"));
            Check("国家码多源不一致时禁止自动改区域", disputed.FixableCulture == null);
            var unsupported = Report.Build(LanguageFacts("HK", "HK", true, "en-US", "en-US"));
            Check("不支持地区禁止自动改区域", unsupported.FixableCulture == null);
            var unsupportedTimezoneFacts = LanguageFacts("HK", "HK", true, "en-US", "en-US");
            unsupportedTimezoneFacts.IpTimezone = Tz.Matches("Asia/Tokyo") ? "America/New_York" : "Asia/Tokyo";
            Check("不支持地区禁止自动改时区", Report.Build(unsupportedTimezoneFacts).FixableTz == null);
            twConflict.FixableDns = true;
            Check("DNS 文案使用 DNS设置", twConflict.FixList.Contains("DNS设置"));
            Check("DNS 文案不再误称加密", twConflict.FixList.IndexOf("DNS加密", StringComparison.Ordinal) < 0);
        }

        static void Run(string name, Action test)
        {
            try { test(); }
            catch (Exception e)
            {
                failures++;
                string message;
                try { message = e.Message; } catch { message = "message unavailable"; }
                Console.WriteLine("  ERROR " + name + ": " + e.GetType().FullName + " - " + message);
            }
        }

        public static int Main()
        {
            Console.OutputEncoding = Encoding.UTF8;
            Console.WriteLine("BrowserBridge tests");
            Run("normal collection", TestNormalCollectionAndAuth);
            Run("real browser page", TestRealBrowserPage);
            Run("timeout", TestTimeout);
            Run("browser launch failure", TestBrowserLaunchFailure);
            Run("locale scoring", TestLocaleScoring);
            Console.WriteLine(failures == 0 ? "ALL PASS" : (failures + " FAILED"));
            return failures == 0 ? 0 : 1;
        }
    }
}
