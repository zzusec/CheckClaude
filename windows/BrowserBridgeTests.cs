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
            Console.WriteLine(failures == 0 ? "ALL PASS" : (failures + " FAILED"));
            return failures == 0 ? 0 : 1;
        }
    }
}
