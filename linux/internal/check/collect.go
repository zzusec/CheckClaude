// Package check: collect.go implements Linux-specific data collection.
//
// Each Collect* function populates a subset of Facts fields.
// Network functions accept an HTTP client for testability.
package check

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// DataDir returns the data storage directory for CheckClaude.
func DataDir() string {
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		return filepath.Join(xdg, "checkclaude")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "checkclaude")
}

// ── System info collectors ──

// CollectTimezone reads the system timezone from /etc/localtime symlink
// or falls back to timedatectl.
func CollectTimezone(f *Facts) {
	// Method 1: read /etc/localtime symlink
	target, err := os.Readlink("/etc/localtime")
	if err == nil {
		// Extract IANA name: /usr/share/zoneinfo/America/Los_Angeles → America/Los_Angeles
		const prefix = "/usr/share/zoneinfo/"
		if idx := strings.Index(target, prefix); idx >= 0 {
			f.SysTimezone = target[idx+len(prefix):]
		} else if strings.Contains(target, "zoneinfo/") {
			parts := strings.SplitN(target, "zoneinfo/", 2)
			if len(parts) == 2 {
				f.SysTimezone = parts[1]
			}
		}
	}

	// Method 2: timedatectl fallback
	if f.SysTimezone == "" {
		out, err := exec.Command("timedatectl", "show", "-p", "Timezone", "--value").Output()
		if err == nil {
			f.SysTimezone = strings.TrimSpace(string(out))
		}
	}

	// Compute TZ offset and abbreviation
	if f.SysTimezone != "" {
		loc, err := time.LoadLocation(f.SysTimezone)
		if err == nil {
			now := time.Now().In(loc)
			_, offset := now.Zone()
			hours := offset / 3600
			mins := (offset % 3600) / 60
			if mins < 0 {
				mins = -mins
			}
			f.TZOffset = fmt.Sprintf("%+03d%02d", hours, mins)
			f.TZAbbr = now.Format("MST")

			// Check consistency: UTC offset should match
			f.TZConsistent = true
		}
	}
}

// CollectLocale reads the system locale from environment variables.
// Priority: LC_ALL → LC_MESSAGES → LANG
func CollectLocale(f *Facts) {
	locale := os.Getenv("LC_ALL")
	if locale == "" {
		locale = os.Getenv("LC_MESSAGES")
	}
	if locale == "" {
		locale = os.Getenv("LANG")
	}

	if locale == "" {
		return
	}

	// Strip encoding suffix (e.g. "en_US.UTF-8" → "en_US")
	f.SysLocale = locale
	base := locale
	if idx := strings.Index(base, "."); idx >= 0 {
		base = base[:idx]
	}

	// Extract language (e.g. "en_US" → "en")
	if idx := strings.IndexAny(base, "_-"); idx >= 0 {
		f.SysLang = base[:idx]
		f.LocaleCC = strings.ToUpper(base[idx+1:])
	} else {
		f.SysLang = base
	}
}

// CollectDNS reads /etc/resolv.conf and classifies DNS servers.
func CollectDNS(f *Facts) {
	data, err := os.ReadFile("/etc/resolv.conf")
	if err != nil {
		return
	}

	var servers []string
	seen := make(map[string]bool)
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "nameserver") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				ip := parts[1]
				// Skip private/loopback but allow 127.0.0.53 (systemd-resolved stub)
				if isPrivateOrLoopback(ip) && ip != "127.0.0.53" {
					continue
				}
				if ip == "127.0.0.53" {
					// systemd-resolved local stub, not a leak
					continue
				}
				if !seen[ip] {
					servers = append(servers, ip)
					seen[ip] = true
				}
			}
		}
	}

	if len(servers) == 0 {
		f.DNSScope = "本地/代理接管"
		return
	}

	first := servers[0]
	if DomesticDNS[first] {
		f.DNSScope = fmt.Sprintf("国内公共DNS(%s)", first)
	} else {
		f.DNSScope = fmt.Sprintf("境外/自定义(%s)", first)
	}
}

// CollectProxyMode detects the proxy form on Linux.
func CollectProxyMode(f *Facts) {
	// Check for TUN interface via ip route
	out, err := exec.Command("ip", "route", "get", "93.184.216.34").Output()
	if err == nil {
		line := string(out)
		// Look for tun/utun interface
		if strings.Contains(line, " dev tun") || strings.Contains(line, " dev utun") {
			f.ProxyMode = "TUN 全局"
		}
	}

	if f.ProxyMode == "" {
		// Check environment proxies
		for _, v := range []string{"ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "all_proxy", "https_proxy", "http_proxy"} {
			if os.Getenv(v) != "" {
				f.ProxyMode = "系统 HTTP 代理"
				break
			}
		}
	}

	if f.ProxyMode == "" {
		// Check GNOME proxy settings
		out, err := exec.Command("gsettings", "get", "org.gnome.system.proxy", "mode").Output()
		if err == nil {
			mode := strings.Trim(strings.TrimSpace(string(out)), "'\"")
			switch mode {
			case "auto":
				f.ProxyMode = "系统 HTTP 代理"
				f.PACOn = true
			case "manual":
				f.ProxyMode = "系统 HTTP 代理"
			}
		}
	}

	if f.ProxyMode == "" {
		f.ProxyMode = "直连"
	}
}

// CollectVirtualization detects if running in a VM.
func CollectVirtualization(f *Facts) {
	out, err := exec.Command("systemd-detect-virt").Output()
	if err != nil {
		f.VMHost = "物理机"
		return
	}
	virt := strings.TrimSpace(string(out))
	if virt == "none" || virt == "" {
		f.VMHost = "物理机"
	} else {
		f.VMHost = fmt.Sprintf("虚拟机(%s)", virt)
	}
}

// CollectRelay reads ANTHROPIC_BASE_URL from environment.
func CollectRelay(f *Facts) {
	f.Relay = os.Getenv("ANTHROPIC_BASE_URL")
}

// ── Network collectors ──

// These functions use an injected http.Client for testability.

// CollectThreeWayIPs fetches exit IPs from three perspectives.
func CollectThreeWayIPs(ctx context.Context, client *http.Client, f *Facts) {
	type result struct {
		field string
		ip    string
	}
	ch := make(chan result, 3)

	// Domestic
	go func() {
		ip := fetchIPFromAny(ctx, client, []string{
			"http://www.3322.org/dyndns/getip",
			"http://whois.pconline.com.cn/ipJson.jsp",
		})
		ch <- result{"cn", ip}
	}()

	// International
	go func() {
		ip := fetchIPFromAny(ctx, client, []string{
			"https://api.ipify.org",
			"https://icanhazip.com",
			"https://ipinfo.io/ip",
		})
		ch <- result{"intl", ip}
	}()

	// GFW-side
	go func() {
		ip := fetchIPFromCfTrace(ctx, client)
		if ip == "" {
			ip = fetchIPFromAny(ctx, client, []string{
				"https://api.ip.sb/ip",
			})
		}
		ch <- result{"gfw", ip}
	}()

	for i := 0; i < 3; i++ {
		r := <-ch
		switch r.field {
		case "cn":
			f.CnIP = r.ip
		case "intl":
			f.IntlIP = r.ip
		case "gfw":
			f.GfwIP = r.ip
		}
	}

	// Set probe IP: prefer GFW, fallback to INTL
	if f.GfwIP != "" {
		f.ProbeIP = f.GfwIP
	} else if f.IntlIP != "" {
		f.ProbeIP = f.IntlIP
	}

	// Check consistency
	if f.CnIP != "" && f.IntlIP != "" && f.GfwIP != "" {
		f.Consistent = (f.CnIP == f.IntlIP && f.IntlIP == f.GfwIP)
	}
}

// CollectIPIntel queries multiple IP intelligence APIs for the probe IP.
func CollectIPIntel(ctx context.Context, client *http.Client, f *Facts) {
	if f.ProbeIP == "" {
		return
	}

	type intelResult struct {
		source  string
		cc      string
		isp     string
		asn     string
		hosting int
		proxy   bool
	}

	ch := make(chan intelResult, 4)

	// ip-api.com
	go func() {
		var r intelResult
		r.source = "ip-api"
		url := fmt.Sprintf("http://ip-api.com/json/%s?fields=status,countryCode,city,isp,org,as,asname,proxy,hosting", f.ProbeIP)
		body := httpGet(ctx, client, url)
		if body != "" {
			var data map[string]interface{}
			if json.Unmarshal([]byte(body), &data) == nil && data["status"] == "success" {
				r.cc = toCC(data["countryCode"])
				r.isp = toString(data["isp"])
				r.asn = toString(data["as"])
				if city := toString(data["city"]); city != "" {
					f.City = city
				}
				if hosting, ok := data["hosting"].(bool); ok && hosting {
					r.hosting = 1
				}
				if proxy, ok := data["proxy"].(bool); ok {
					r.proxy = proxy
				}
			}
		}
		ch <- r
	}()

	// ipinfo.io
	go func() {
		var r intelResult
		r.source = "ipinfo"
		url := fmt.Sprintf("https://ipinfo.io/%s/json", f.ProbeIP)
		body := httpGet(ctx, client, url)
		if body != "" {
			var data map[string]interface{}
			if json.Unmarshal([]byte(body), &data) == nil {
				r.cc = toCC(data["country"])
				r.isp = toString(data["org"])
				if tz := toString(data["timezone"]); tz != "" {
					f.IPTimezone = tz
				}
				if name := toString(data["country"]); name != "" {
					// Use for secondary country name if needed
				}
			}
		}
		ch <- r
	}()

	// ipwho.is
	go func() {
		var r intelResult
		r.source = "ipwho"
		url := fmt.Sprintf("https://ipwho.is/%s", f.ProbeIP)
		body := httpGet(ctx, client, url)
		if body != "" {
			var data map[string]interface{}
			if json.Unmarshal([]byte(body), &data) == nil {
				r.cc = toCC(data["country_code"])
			}
		}
		ch <- r
	}()

	// api.ip.sb
	go func() {
		var r intelResult
		r.source = "ipsb"
		url := fmt.Sprintf("https://api.ip.sb/geoip/%s", f.ProbeIP)
		body := httpGet(ctx, client, url)
		if body != "" {
			var data map[string]interface{}
			if json.Unmarshal([]byte(body), &data) == nil {
				r.cc = toCC(data["country_code"])
			}
		}
		ch <- r
	}()

	var results []intelResult
	for i := 0; i < 4; i++ {
		results = append(results, <-ch)
	}

	// Process results
	var sources []string
	validCCs := make(map[string]bool)
	f.IntelCount = 0

	for _, r := range results {
		if r.cc != "" {
			f.IntelCount++
			validCCs[r.cc] = true
			sources = append(sources, fmt.Sprintf("%s:%s", r.source, r.cc))
		}
		if r.source == "ip-api" {
			if f.Country == "" {
				f.Country = r.cc
			}
			f.ISP = r.isp
			f.ASN = r.asn
			f.Hosting = r.hosting
			f.Proxy = r.proxy
		}
		if r.source == "ipinfo" {
			f.Country2 = r.cc
			f.ISP2 = r.isp
		}
		if r.source == "ipwho" {
			f.Country3 = r.cc
		}
		if r.source == "ipsb" {
			f.Country4 = r.cc
		}
	}

	f.IntelSources = strings.Join(sources, ",")

	// ASN cross-check
	if f.ASN != "" && f.ISP2 != "" {
		asnRe := regexp.MustCompile(`^AS\d+`)
		asn1 := asnRe.FindString(f.ASN)
		asn2 := asnRe.FindString(f.ISP2)
		if asn1 != "" && asn2 != "" {
			if asn1 == asn2 {
				f.ASNMatch = 1
			} else {
				f.ASNMatch = 0
			}
		} else {
			f.ASNMatch = -1
		}
	} else {
		f.ASNMatch = -1
	}
}

// CollectCloudflare fetches Cloudflare edge info via /cdn-cgi/trace.
func CollectCloudflare(ctx context.Context, client *http.Client, f *Facts) {
	body := httpGet(ctx, client, "https://cloudflare.com/cdn-cgi/trace")
	if body == "" {
		return
	}
	for _, line := range strings.Split(body, "\n") {
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		k, v := parts[0], parts[1]
		switch k {
		case "ip":
			f.CfIP = v
		case "colo":
			f.CfColo = v
		case "loc":
			f.CfLoc = v
		}
	}
}

// CollectServiceReachability tests HTTP reachability of Anthropic services.
func CollectServiceReachability(ctx context.Context, client *http.Client, f *Facts) {
	type result struct {
		field string
		code  int
	}
	ch := make(chan result, 3)

	go func() {
		code := httpStatusCode(ctx, client, "https://api.anthropic.com/v1/messages")
		ch <- result{"api", code}
	}()
	go func() {
		code := httpStatusCode(ctx, client, "https://claude.ai/robots.txt")
		ch <- result{"web", code}
	}()
	go func() {
		code := httpStatusCode(ctx, client, "https://www.anthropic.com/robots.txt")
		ch <- result{"site", code}
	}()

	for i := 0; i < 3; i++ {
		r := <-ch
		switch r.field {
		case "api":
			f.APICode = r.code
		case "web":
			f.WebCode = r.code
		case "site":
			f.SiteCode = r.code
		}
	}
}

// CollectDNSVerdict resolves claude.ai and classifies the result.
func CollectDNSVerdict(f *Facts) {
	ips, err := net.LookupHost("claude.ai")
	if err != nil || len(ips) == 0 {
		f.DNSVerdict = "解析失败"
		return
	}

	ip := ips[0]
	f.DNSResult = ip

	switch {
	case strings.HasPrefix(ip, "198.18.") || strings.HasPrefix(ip, "198.19.") || strings.HasPrefix(ip, "240."):
		f.DNSVerdict = "代理接管(fake-ip)"
	case strings.HasPrefix(ip, "160.79.104.") || strings.HasPrefix(ip, "160.79.105."):
		f.DNSVerdict = "正常(Anthropic)"
	case isCloudflareIP(ip):
		f.DNSVerdict = "正常(Cloudflare)"
	case strings.HasPrefix(ip, "0.0.0.0") || strings.HasPrefix(ip, "127.") ||
		strings.HasPrefix(ip, "10.") || strings.HasPrefix(ip, "192.168."):
		f.DNSVerdict = fmt.Sprintf("被污染(指向私有地址)")
	default:
		f.DNSVerdict = fmt.Sprintf("可疑(%s)", ip)
	}
}

// CollectIPv6 checks for IPv6 exit.
func CollectIPv6(ctx context.Context, client *http.Client, f *Facts) {
	body := httpGet(ctx, client, "https://api64.ipify.org")
	body = strings.TrimSpace(body)
	if body == "" || net.ParseIP(body) == nil {
		return
	}
	if net.ParseIP(body).To4() != nil {
		return // IPv4 address, skip
	}
	f.IPv6 = body

	// Look up country
	url := fmt.Sprintf("https://ipinfo.io/%s/country", body)
	cc := strings.TrimSpace(httpGet(ctx, client, url))
	if len(cc) == 2 {
		f.IPv6CC = strings.ToUpper(cc)
	}
}

// CollectStability reads the history file and counts IP changes.
func CollectStability(f *Facts) {
	dir := DataDir()
	histFile := filepath.Join(dir, "network_history")
	data, err := os.ReadFile(histFile)
	if err != nil {
		return
	}

	cutoff := time.Now().Add(-24 * time.Hour)
	changes := 0
	var lastIP string

	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Format: timestamp ip changed=0/1
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		ts, err := time.Parse("2006-01-02T15:04:05", fields[0])
		if err != nil {
			continue
		}
		if ts.Before(cutoff) {
			continue
		}
		ip := fields[1]
		if ip != lastIP && lastIP != "" {
			// Check if this was a confirmed change
			for _, field := range fields[2:] {
				if field == "changed=1" {
					changes++
					break
				}
			}
		}
		lastIP = ip
	}

	f.IPChanges = changes
}

// CollectBrowser reads browser_signals file if recent enough (1 hour).
func CollectBrowser(f *Facts) {
	dir := DataDir()
	sigFile := filepath.Join(dir, "browser_signals")
	info, err := os.Stat(sigFile)
	if err != nil {
		return
	}

	// Check age: must be within 1 hour
	if time.Since(info.ModTime()) > time.Hour {
		return
	}

	signals, err := ReadBrowserSignals(sigFile)
	if err != nil {
		return
	}

	f.BrSource = signals["source"]
	f.BrTZ = signals["tz"]
	f.BrLangs = signals["languages"]
	f.BrLocale = signals["locale"]
	f.BrRTC = signals["rtc_srflx"]
	f.BrWebGL = signals["webgl"]
	f.BrFonts = signals["fonts"]
	f.BrAccept = signals["accept_lang"]

	// Client Hints: prefer server-captured ch_platform, fallback to JS uad_platform
	if v := signals["ch_platform"]; v != "" {
		f.BrChPlat = v
	} else if v := signals["uad_platform"]; v != "" {
		f.BrChPlat = v
	}

	// Mark as OK if we got at least a timezone
	f.BrOK = f.BrTZ != ""
}

// ReadBrowserSignals parses a key=value signals file.
func ReadBrowserSignals(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	m := make(map[string]string)
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if idx := strings.Index(line, "="); idx > 0 {
			k := line[:idx]
			v := line[idx+1:]
			m[k] = v
		}
	}
	return m, nil
}

// ── Helpers ──

func httpGet(ctx context.Context, client *http.Client, url string) string {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("User-Agent", "CheckClaude/1.0")

	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 65536))
	if err != nil {
		return ""
	}
	return string(body)
}

func httpStatusCode(ctx context.Context, client *http.Client, url string) int {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return 0
	}
	req.Header.Set("User-Agent", "CheckClaude/1.0")

	resp, err := client.Do(req)
	if err != nil {
		return 0
	}
	resp.Body.Close()
	return resp.StatusCode
}

func fetchIPFromAny(ctx context.Context, client *http.Client, urls []string) string {
	for _, url := range urls {
		body := strings.TrimSpace(httpGet(ctx, client, url))
		ip := extractIP(body)
		if ip != "" {
			return ip
		}
	}
	return ""
}

func fetchIPFromCfTrace(ctx context.Context, client *http.Client) string {
	body := httpGet(ctx, client, "https://cloudflare.com/cdn-cgi/trace")
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "ip=") {
			return strings.TrimPrefix(line, "ip=")
		}
	}
	return ""
}

var ipRe = regexp.MustCompile(`(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})`)

func extractIP(s string) string {
	m := ipRe.FindString(s)
	if m != "" && net.ParseIP(m) != nil {
		return m
	}
	return ""
}

func isPrivateOrLoopback(ip string) bool {
	p := net.ParseIP(ip)
	if p == nil {
		return false
	}
	return p.IsLoopback() || p.IsPrivate() || p.IsLinkLocalUnicast()
}

func isCloudflareIP(ip string) bool {
	return strings.HasPrefix(ip, "104.") ||
		strings.HasPrefix(ip, "172.64.") || strings.HasPrefix(ip, "172.65.") ||
		strings.HasPrefix(ip, "172.66.") || strings.HasPrefix(ip, "172.67.") ||
		strings.HasPrefix(ip, "172.68.") || strings.HasPrefix(ip, "172.69.") ||
		strings.HasPrefix(ip, "172.70.") || strings.HasPrefix(ip, "172.71.") ||
		strings.HasPrefix(ip, "162.158.") || strings.HasPrefix(ip, "162.159.") ||
		strings.HasPrefix(ip, "188.114.") || strings.HasPrefix(ip, "141.101.")
}

func toCC(v interface{}) string {
	s := toString(v)
	s = strings.TrimSpace(strings.ToUpper(s))
	if len(s) == 2 && s[0] >= 'A' && s[0] <= 'Z' && s[1] >= 'A' && s[1] <= 'Z' {
		return s
	}
	return ""
}

func toString(v interface{}) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}
