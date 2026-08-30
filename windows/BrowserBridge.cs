using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace CheckClaude
{
    // 真实浏览器指纹采集: 起一个只听 127.0.0.1 的 HttpListener，用系统默认浏览器访问它。
    // 服务端读到 UA / Accept-Language / Sec-CH-UA / Sec-Fetch，页面 JS 拿 WebRTC / 字体 /
    // Canvas / userAgentData —— 这才是登录 claude.ai 时 Anthropic 实际看到的那套指纹。
    // 安全: 只绑 127.0.0.1(不需要管理员)、随机端口、URL 带一次性 token、拿到结果或超时立即关。
    class BrowserBridge
    {
        const int MaxBodyChars = 131072;
        HttpListener listener;
        readonly string token = Guid.NewGuid().ToString("N").Substring(0, 12);
        readonly string outPath;
        readonly Action<bool> done;
        readonly int timeoutMs;
        readonly Action<string> openUrl;
        int finished;

        public BrowserBridge(string outPath, Action<bool> done)
            : this(outPath, done, 90000, OpenBrowser) { }

        // 测试入口：可替换浏览器启动器并缩短超时，不影响生产调用。
        internal BrowserBridge(string outPath, Action<bool> done, int timeoutMs, Action<string> openUrl)
        {
            this.outPath = outPath;
            this.done = done;
            this.timeoutMs = Math.Max(100, timeoutMs);
            this.openUrl = openUrl ?? OpenBrowser;
        }

        static void OpenBrowser(string url)
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }

        static int FreePort()
        {
            var l = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
            l.Start();
            int p = ((IPEndPoint)l.LocalEndpoint).Port;
            l.Stop();
            return p;
        }

        public void Start()
        {
            try
            {
                int port = FreePort();
                listener = new HttpListener();
                listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
                listener.Start();
                Task.Run(() => Loop());
                Task.Run(() => { Thread.Sleep(timeoutMs); Finish(false); });
                openUrl("http://127.0.0.1:" + port + "/c?t=" + token);
            }
            catch (Exception e) { Paths.Write("浏览器桥接启动失败: " + e.Message); Finish(false); }
        }

        void Loop()
        {
            while (Volatile.Read(ref finished) == 0 && listener != null && listener.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = listener.GetContext(); } catch { return; }
                try
                {
                    if (ctx.Request.QueryString["t"] != token) { Reply(ctx, 403, "text/plain", "forbidden"); continue; }
                    if (ctx.Request.HttpMethod == "POST")
                    {
                        string body = ReadLimitedBody(ctx.Request.InputStream);
                        Save(ctx.Request, body);
                        Reply(ctx, 200, "text/plain", "ok");
                        Finish(true);
                        return;
                    }
                    Reply(ctx, 200, "text/html; charset=utf-8", PAGE.Replace("__TOKEN__", token));
                }
                catch (InvalidDataException)
                {
                    try { Reply(ctx, 413, "text/plain", "payload too large"); } catch { }
                }
                catch (Exception e)
                {
                    Paths.Write("浏览器桥接请求失败: " + e.Message);
                    try { Reply(ctx, 500, "text/plain", "error"); } catch { }
                }
            }
        }

        static string ReadLimitedBody(Stream input)
        {
            using (var sr = new StreamReader(input, Encoding.UTF8))
            {
                var sb = new StringBuilder();
                var buf = new char[4096];
                int n;
                while ((n = sr.Read(buf, 0, buf.Length)) > 0)
                {
                    if (sb.Length + n > MaxBodyChars) throw new InvalidDataException("browser payload too large");
                    sb.Append(buf, 0, n);
                }
                return sb.ToString();
            }
        }

        static void Reply(HttpListenerContext ctx, int code, string type, string body)
        {
            var b = Encoding.UTF8.GetBytes(body);
            ctx.Response.StatusCode = code;
            ctx.Response.ContentType = type;
            ctx.Response.ContentLength64 = b.Length;
            ctx.Response.OutputStream.Write(b, 0, b.Length);
            ctx.Response.Close();
        }

        // 请求头本身就是指纹的一部分，JS 拿不到自己发出去的这些头
        void Save(HttpListenerRequest req, string body)
        {
            var o = new SortedDictionary<string, string> { { "source", "browser" } };
            var want = new Dictionary<string, string> {
                {"user-agent","ua"}, {"accept-language","accept_lang"}, {"sec-ch-ua","ch_ua"},
                {"sec-ch-ua-platform","ch_platform"}, {"sec-ch-ua-mobile","ch_mobile"},
                {"sec-fetch-site","sf_site"}, {"sec-fetch-mode","sf_mode"}, {"sec-fetch-dest","sf_dest"} };
            foreach (string h in req.Headers)
            {
                string key;
                if (h != null && want.TryGetValue(h.ToLowerInvariant(), out key))
                    o[key] = (req.Headers[h] ?? "").Replace("\"", "");
            }
            foreach (var kv in (body ?? "").Split('\n'))
            {
                var i = kv.IndexOf('=');
                if (i > 0) o[kv.Substring(0, i)] = Clean(kv.Substring(i + 1), 4096);
            }
            var sb = new StringBuilder("time=" + DateTimeOffset.Now.ToUnixTimeSeconds() + "\n");
            foreach (var kv in o) sb.Append(kv.Key + "=" + Clean(kv.Value, 4096) + "\n");
            Paths.Ensure();
            var tmp = outPath + ".tmp";
            File.WriteAllText(tmp, sb.ToString(), Encoding.UTF8);
            if (File.Exists(outPath)) File.Delete(outPath);
            File.Move(tmp, outPath);
        }

        static string Clean(string value, int maxLength)
        {
            var s = (value ?? "").Replace("\r", " ").Replace("\n", " ").Trim();
            return s.Length <= maxLength ? s : s.Substring(0, maxLength);
        }

        void Finish(bool ok)
        {
            if (Interlocked.Exchange(ref finished, 1) != 0) return;
            try { if (listener != null) { listener.Stop(); listener.Close(); } } catch { }
            listener = null;
            try { if (done != null) done(ok); }
            catch (Exception e) { Paths.Write("浏览器桥接回调失败: " + e.Message); }
        }

        const string PAGE = @"<!doctype html><meta charset='utf-8'><title>CheckClaude 浏览器指纹检测</title>
<style>body{font:15px/1.8 -apple-system,'Segoe UI',system-ui,sans-serif;max-width:32rem;margin:14vh auto;padding:0 1.5rem;color:#1a1a2e}
h1{font-size:1.3rem;margin:0 0 .6rem}p{color:#5c5c70;margin:.4rem 0}.ok{color:#2f855a;font-weight:500}.err{color:#c53030}
table{border-collapse:collapse;width:100%;margin:1rem 0 1.4rem;font-size:.92rem}
th{text-align:left;font-weight:400;color:#8a8a9a;padding:.45rem .9rem .45rem 0;white-space:nowrap;vertical-align:top;width:7.5rem}
td{padding:.45rem 0;color:#1a1a2e;word-break:break-all}tr+tr th,tr+tr td{border-top:1px solid #ececf3}
.mute{font-size:.86rem;color:#8a8a9a}
#keep{font:inherit;font-size:.86rem;margin-left:.5rem;padding:.2rem .7rem;cursor:pointer;border:1px solid #ddd8ff;border-radius:6px;background:#f0eeff;color:#4e4aaf}</style>
<h1>CheckClaude 浏览器指纹检测</h1>
<p id='s'>正在采集…</p><div id='d'></div>
<div id='f' style='display:none'>
<p>这些信号已回传到本机的 CheckClaude，用于评估 claude.ai 网页端登录时的环境画像。<b>完整体检结果请看托盘图标。</b></p>
<p class='mute'>检测在本机完成，数据不经过任何服务器。</p>
<p class='mute'><span id='cd'></span> <button id='keep'>保持打开</button></p></div>
<script>
(async () => {
  var o = {}, set = function (k, v) { o[k] = String(v == null ? '' : v).replace(/\n/g, ' '); };
  try {
    set('languages', (navigator.languages || []).join(','));
    var ro = Intl.DateTimeFormat().resolvedOptions();
    set('tz', ro.timeZone); set('locale', ro.locale);
    set('tzoffset', -new Date().getTimezoneOffset() / 60);
    set('platform', navigator.platform); set('hw', navigator.hardwareConcurrency);
    if (navigator.userAgentData) {
      set('uad_mobile', navigator.userAgentData.mobile);
      set('uad_platform', navigator.userAgentData.platform);
      try {
        var h = await navigator.userAgentData.getHighEntropyValues(['platformVersion','architecture','fullVersionList']);
        set('uad_platform_version', h.platformVersion); set('uad_arch', h.architecture);
        set('uad_brands', (h.fullVersionList || []).map(function (b) { return b.brand + ' ' + b.version; }).join('; '));
      } catch (e) {}
    }
    try {
      var c = document.createElement('canvas'), x = c.getContext('2d');
      x.textBaseline = 'top'; x.font = '14px Arial'; x.fillText('Claude环境检测', 2, 2);
      var d = c.toDataURL(), hh = 0;
      for (var i = 0; i < d.length; i++) hh = (hh * 31 + d.charCodeAt(i)) | 0;
      set('canvas', (hh >>> 0).toString(16));
    } catch (e) {}
    try {
      var gl = document.createElement('canvas').getContext('webgl');
      var dbg = gl.getExtension('WEBGL_debug_renderer_info');
      set('webgl', gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL));
    } catch (e) {}
    try {
      var probe = ['Microsoft YaHei','SimSun','SimHei','KaiTi','FangSong','PingFang SC','Noto Sans CJK SC'];
      var sp = document.createElement('span');
      sp.style.cssText = 'position:absolute;left:-9999px;font-size:72px';
      sp.textContent = 'mmmmmmmmmmlli测试';
      document.body.appendChild(sp);
      sp.style.fontFamily = 'monospace'; var base = sp.offsetWidth;
      set('fonts', probe.filter(function (f) { sp.style.fontFamily = ""'"" + f + ""',monospace""; return sp.offsetWidth !== base; }).join(','));
      sp.parentNode.removeChild(sp);
    } catch (e) {}
    try {
      var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }, { urls: 'stun:stun.l.google.com:19302' }] });
      pc.createDataChannel('p');
      var hosts = {}, srflx = {};
      pc.onicecandidate = function (e) {
        if (!e.candidate) return;
        var cc = e.candidate.candidate, m = cc.match(/([0-9]{1,3}(?:\.[0-9]{1,3}){3})/);
        if (!m) return;
        if (cc.indexOf('typ host') >= 0) hosts[m[1]] = 1;
        if (cc.indexOf('typ srflx') >= 0) srflx[m[1]] = 1;
      };
      var off = await pc.createOffer(); await pc.setLocalDescription(off);
      await new Promise(function (r) { setTimeout(r, 4500); });
      set('rtc_host', Object.keys(hosts).join(',')); set('rtc_srflx', Object.keys(srflx).join(','));
      pc.close();
    } catch (e) {}
  } catch (e) { set('error', e); }
  try {
    await fetch('/r?t=__TOKEN__', { method: 'POST', body: Object.keys(o).map(function (k) { return k + '=' + o[k]; }).join('\n') });
    document.getElementById('s').innerHTML = '<span class=""ok"">✓ 采集完成</span>';
    var rows = [
      ['浏览器', o.uad_brands || navigator.userAgent],
      ['平台', (o.uad_platform || navigator.platform) + (o.uad_platform_version ? ' ' + o.uad_platform_version : '')],
      ['Client Hints', navigator.userAgentData ? '已获取（Chromium）' : '该浏览器不提供（Firefox 等）'],
      ['时区 / 语言', o.tz + ' · ' + o.languages],
      ['WebRTC 出口', o.rtc_srflx ? o.rtc_srflx : '无泄漏（未拿到公网候选）'],
      ['渲染环境', o.webgl || '未取到'],
      ['中文字体', o.fonts ? o.fonts.split(',').length + ' 种' : '无']
    ];
    document.getElementById('d').innerHTML = '<table>' + rows.map(function (r) { return '<tr><th>' + r[0] + '</th><td>' + r[1] + '</td></tr>'; }).join('') + '</table>';
    document.getElementById('f').style.display = 'block';
    var n = 10, stopped = false;
    var cd = document.getElementById('cd'), keep = document.getElementById('keep');
    keep.onclick = function () { stopped = true; cd.textContent = '已取消自动关闭，可手动关闭本页。'; keep.style.display = 'none'; };
    var t = setInterval(function () {
      if (stopped) { clearInterval(t); return; }
      if (n <= 0) {
        clearInterval(t); window.close();
        setTimeout(function () { cd.textContent = '可以关闭这个标签页了。'; keep.style.display = 'none'; }, 500);
        return;
      }
      cd.textContent = '本页将在 ' + n + ' 秒后自动关闭'; n--;
    }, 1000);
  } catch (e) { document.getElementById('s').innerHTML = '<span class=""err"">回传失败：' + e + '</span>'; }
})();
</script>";
    }
}
