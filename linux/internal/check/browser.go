// Package check: browser.go implements the localhost browser bridge used to
// collect signals that only a real browser can expose (WebRTC, Intl, fonts,
// Client Hints) and to render the full HTML report.
package check

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	maxBody       = 128 << 10
	bridgeTimeout = 90 * time.Second
)

func newToken() string {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("%012x", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

// SaveBrowserSignals atomically writes the key=value signals file.
func SaveBrowserSignals(m map[string]string) error {
	dir := DataDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	var b strings.Builder
	for k, v := range m {
		if v == "" {
			continue
		}
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(sanitize(v))
		b.WriteByte('\n')
	}
	path := filepath.Join(dir, "browser_signals")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// sanitize strips newlines and caps length so a hostile page cannot inject
// extra keys into the signals file.
func sanitize(v string) string {
	v = strings.NewReplacer("\n", " ", "\r", " ").Replace(v)
	if len(v) > 512 {
		v = v[:512]
	}
	return strings.TrimSpace(v)
}

// Bridge starts the localhost bridge, opens the default browser, waits for the
// page to report its signals, then returns the re-evaluated result. It returns
// the pre-bridge result if the browser never reports back.
func Bridge(ctx context.Context, f *Facts, r *Report) (*Facts, *Report, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return f, r, err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	token := newToken()

	var (
		once     sync.Once
		done     = make(chan struct{})
		mu       sync.Mutex
		curF, curR = f, r
	)
	finish := func() { once.Do(func() { close(done) }) }

	mux := http.NewServeMux()
	guard := func(h func(http.ResponseWriter, *http.Request)) http.HandlerFunc {
		return func(w http.ResponseWriter, req *http.Request) {
			if req.URL.Query().Get("t") != token {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("X-Frame-Options", "DENY")
			w.Header().Set("Content-Security-Policy",
				"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'")
			h(w, req)
		}
	}

	mux.HandleFunc("/c", guard(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, collectPage(token))
	}))

	mux.HandleFunc("/r", guard(func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		body, err := io.ReadAll(io.LimitReader(req.Body, maxBody+1))
		if err != nil || len(body) > maxBody {
			http.Error(w, "too large", http.StatusRequestEntityTooLarge)
			return
		}

		signals, _ := parseSignals(string(body))
		signals["source"] = "browser"
		signals["accept_lang"] = req.Header.Get("Accept-Language")
		if p := req.Header.Get("Sec-CH-UA-Platform"); p != "" {
			signals["ch_platform"] = strings.Trim(p, `"`)
		}
		_ = SaveBrowserSignals(signals)

		// Re-score with the browser signals now on disk. Only the browser
		// fields changed, so reuse the facts we already collected instead of
		// making the page wait for another full network sweep.
		nf := *f
		CollectBrowser(&nf)
		nr := Evaluate(&nf)
		mu.Lock()
		curF, curR = &nf, nr
		mu.Unlock()

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, reportPage(&nf, nr))
		finish()
	}))

	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = srv.Serve(ln) }()

	url := fmt.Sprintf("http://127.0.0.1:%d/c?t=%s", port, token)
	if err := exec.Command("xdg-open", url).Start(); err != nil {
		fmt.Fprintf(os.Stderr, "无法自动打开浏览器，请手动访问：%s\n", url)
	}

	select {
	case <-done:
	case <-time.After(bridgeTimeout):
		fmt.Fprintln(os.Stderr, "浏览器未在 90 秒内回报，按未采集计分。")
	case <-ctx.Done():
	}

	// Let the browser finish rendering the response before tearing down.
	time.Sleep(500 * time.Millisecond)
	shutCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)

	mu.Lock()
	defer mu.Unlock()
	return curF, curR, nil
}

// parseSignals reads key=value lines, dropping malformed and oversized keys.
func parseSignals(body string) (map[string]string, error) {
	m := make(map[string]string)
	for _, line := range strings.Split(body, "\n") {
		idx := strings.Index(line, "=")
		if idx <= 0 || idx > 40 {
			continue
		}
		k := strings.TrimSpace(line[:idx])
		if k == "" || strings.ContainsAny(k, " \t") {
			continue
		}
		m[k] = sanitize(line[idx+1:])
	}
	return m, nil
}

const pageCSS = `body{font-family:system-ui,-apple-system,"Noto Sans CJK SC",sans-serif;margin:0;background:#0f1115;color:#e6e8eb}
.wrap{max-width:860px;margin:0 auto;padding:32px 20px}
h1{font-size:20px;margin:0 0 4px}.sub{color:#8b93a1;font-size:13px;margin-bottom:24px}
.score{font-size:52px;font-weight:700;line-height:1}
.badge{display:inline-block;padding:3px 10px;border-radius:99px;font-size:13px;margin-left:10px;vertical-align:middle}
.g{background:#123b22;color:#4ade80}.y{background:#3b3312;color:#facc15}.r{background:#3b1418;color:#f87171}
.card{background:#171a20;border:1px solid #242832;border-radius:10px;padding:16px 18px;margin:14px 0}
table{width:100%;border-collapse:collapse;font-size:14px}
td{padding:6px 4px;border-bottom:1px solid #20242e}
td.n{text-align:right;color:#8b93a1;white-space:nowrap}
.ok{color:#4ade80}.warn{color:#facc15}.bad{color:#f87171}
.issue{color:#8b93a1;font-size:12px}
h2{font-size:14px;color:#8b93a1;margin:0 0 8px;font-weight:600}
li{margin:4px 0;font-size:14px}`

func collectPage(token string) string {
	return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CheckClaude 正在采集</title><style>` + pageCSS + `</style></head>
<body><div class="wrap"><h1>正在采集浏览器环境…</h1>
<div class="sub" id="s">正在探测 WebRTC 出口，约需 5 秒</div></div>
<script>
(async function(){
 var out={};
 function set(k,v){ if(v!==undefined&&v!==null&&v!=="") out[k]=String(v); }
 try{ set("languages",(navigator.languages||[]).join(",")); }catch(e){}
 try{ var o=Intl.DateTimeFormat().resolvedOptions(); set("tz",o.timeZone); set("locale",o.locale); }catch(e){}
 try{ set("tz_offset",new Date().getTimezoneOffset()); }catch(e){}
 try{
  var ua=navigator.userAgentData;
  if(ua){ set("uad_platform",ua.platform);
   var h=await ua.getHighEntropyValues(["platform","platformVersion","architecture"]);
   set("uad_platform_version",h.platformVersion); set("uad_arch",h.architecture); }
 }catch(e){}
 try{
  var c=document.createElement("canvas"),g=c.getContext("webgl")||c.getContext("experimental-webgl");
  if(g){ var d=g.getExtension("WEBGL_debug_renderer_info");
   if(d) set("webgl",g.getParameter(d.UNMASKED_RENDERER_WEBGL)); }
 }catch(e){}
 try{
  var cv=document.createElement("canvas"),cx=cv.getContext("2d");
  cx.textBaseline="top";cx.font="14px 'Arial'";cx.fillText("CheckClaude你好",2,2);
  var s=cv.toDataURL(),hsh=0; for(var i=0;i<s.length;i++){hsh=(hsh*31+s.charCodeAt(i))|0;}
  set("canvas",(hsh>>>0).toString(16));
 }catch(e){}
 try{
  var probe=["微软雅黑","宋体","SimSun","PingFang SC","Noto Sans CJK SC","WenQuanYi Micro Hei","Source Han Sans SC","黑体"];
  var base=["monospace","serif","sans-serif"],span=document.createElement("span");
  span.style.cssText="position:absolute;left:-9999px;font-size:72px";span.textContent="mmmmmmmmmmlli中文";
  document.body.appendChild(span);
  var ref={}; base.forEach(function(b){span.style.fontFamily=b;ref[b]=[span.offsetWidth,span.offsetHeight];});
  var found=[];
  probe.forEach(function(p){
   for(var i=0;i<base.length;i++){ span.style.fontFamily="'"+p+"',"+base[i];
    if(span.offsetWidth!==ref[base[i]][0]||span.offsetHeight!==ref[base[i]][1]){ found.push(p); return; } }
  });
  span.remove(); set("fonts",found.join(","));
 }catch(e){}
 var rtc=await new Promise(function(res){
  var ips={};
  try{
   var pc=new RTCPeerConnection({iceServers:[{urls:"stun:stun.cloudflare.com:3478"},{urls:"stun:stun.l.google.com:19302"}]});
   pc.createDataChannel("x");
   pc.onicecandidate=function(e){
    if(!e.candidate){ try{pc.close();}catch(x){} return res(Object.keys(ips).join(",")); }
    var m=/(\d{1,3}(?:\.\d{1,3}){3})/.exec(e.candidate.candidate);
    if(m&&/ (srflx|prflx) /.test(" "+e.candidate.candidate+" ")) ips[m[1]]=1;
   };
   pc.createOffer().then(function(o){return pc.setLocalDescription(o);}).catch(function(){});
   setTimeout(function(){ try{pc.close();}catch(x){} res(Object.keys(ips).join(",")); },6000);
  }catch(e){ res(""); }
 });
 set("rtc_srflx",rtc);
 document.getElementById("s").textContent="正在生成报告…";
 var body=Object.keys(out).map(function(k){return k+"="+out[k];}).join("\n");
 var resp=await fetch("/r?t=` + token + `",{method:"POST",body:body});
 document.documentElement.innerHTML=await resp.text();
})();
</script></body></html>`
}

func reportPage(f *Facts, r *Report) string {
	cls := "r"
	switch r.RiskLevel {
	case RiskSafe:
		cls = "g"
	case RiskLow, RiskMedium:
		cls = "y"
	}
	e := html.EscapeString

	var b strings.Builder
	b.WriteString(`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CheckClaude 体检报告</title><style>` + pageCSS + `</style></head><body><div class="wrap">`)
	fmt.Fprintf(&b, `<h1>CheckClaude v%s 体检报告</h1><div class="sub">%s</div>`,
		e(r.Version), e(time.Now().Format("2006-01-02 15:04:05")))
	fmt.Fprintf(&b, `<div class="card"><span class="score">%d</span><span class="badge %s">%s · %s</span>
<div class="sub" style="margin:12px 0 0">%s</div></div>`,
		r.Score, cls, e(r.Grade), e(r.RiskLevel), e(r.Verdict))

	loc := f.CountryName
	if f.City != "" {
		loc += " " + f.City
	}
	b.WriteString(`<div class="card"><h2>出口环境</h2><table>`)
	for _, kv := range [][2]string{
		{"出口 IP", f.ProbeIP}, {"归属", loc}, {"运营商", f.ISP + " " + f.ASN},
		{"代理形态", f.ProxyMode}, {"系统时区", f.SysTimezone}, {"系统区域", f.SysLocale},
		{"DNS", f.DNSScope + " " + f.DNSVerdict}, {"运行环境", f.VMHost},
		{"WebRTC", f.BrRTC + " (" + webrtcStatus(f) + ")"},
	} {
		fmt.Fprintf(&b, `<tr><td class="n">%s</td><td>%s</td></tr>`, e(kv[0]), e(strings.TrimSpace(orNA(kv[1]))))
	}
	b.WriteString(`</table></div>`)

	byGroup := map[string][]Signal{}
	for _, s := range r.Signals {
		byGroup[s.Group] = append(byGroup[s.Group], s)
	}
	for _, g := range groupOrder {
		sigs := byGroup[g]
		if len(sigs) == 0 {
			continue
		}
		got, total := 0, 0
		for _, s := range sigs {
			got += s.Points
			total += s.Weight
		}
		fmt.Fprintf(&b, `<div class="card"><h2>%s · %d/%d</h2><table>`, e(g), got, total)
		for _, s := range sigs {
			c := "ok"
			if s.Points == 0 {
				c = "bad"
			} else if s.Points < s.Weight {
				c = "warn"
			}
			fmt.Fprintf(&b, `<tr><td><span class="%s">%s</span> %s`, c, mark(s), e(s.Label))
			if s.Issue != "" {
				fmt.Fprintf(&b, `<div class="issue">%s</div>`, e(s.Issue))
			}
			if s.Fix != "" {
				fmt.Fprintf(&b, `<div class="issue">建议：%s</div>`, e(s.Fix))
			}
			fmt.Fprintf(&b, `</td><td class="n">%d/%d</td></tr>`, s.Points, s.Weight)
		}
		b.WriteString(`</table></div>`)
	}

	if len(r.Fixable) > 0 || len(r.Manual) > 0 {
		b.WriteString(`<div class="card"><h2>修复建议</h2><ul>`)
		for _, s := range r.Fixable {
			fmt.Fprintf(&b, `<li class="warn">%s（可执行 checkclaude --fix）</li>`, e(s))
		}
		for _, s := range r.Manual {
			fmt.Fprintf(&b, `<li>%s</li>`, e(s))
		}
		b.WriteString(`</ul></div>`)
	}
	b.WriteString(`</div></body></html>`)
	return b.String()
}

func mark(s Signal) string {
	switch {
	case s.Points == 0:
		return "✗"
	case s.Points < s.Weight:
		return "!"
	default:
		return "✓"
	}
}
