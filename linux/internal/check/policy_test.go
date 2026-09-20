package check

import (
	"strings"
	"testing"
)

// baselineFacts returns a perfect-environment baseline scoring 100.
func baselineFacts() *Facts {
	return &Facts{
		ProbeIP:  "1.2.3.4",
		CnIP:     "1.2.3.4",
		IntlIP:   "1.2.3.4",
		GfwIP:    "1.2.3.4",
		Country:  "US",
		Country2: "US",
		Country3: "US",
		Country4: "US",

		CountryName: "美国",
		City:        "Los Angeles",
		ISP:         "Comcast",
		ASN:         "AS7922",
		ISP2:        "Comcast Cable",

		IntelSources: "ip-api:US,ipinfo:US,ipwho:US,ip.sb:US",
		IntelCount:   4,

		Hosting:  0, // residential
		Proxy:    false,
		ASNMatch: 1,

		APICode:  401,
		WebCode:  200,
		SiteCode: 200,

		CfColo: "LAX",
		CfLoc:  "US",
		CfIP:   "1.2.3.4",

		Consistent: true,

		IPv6:   "",
		IPv6CC: "",

		IPTimezone:   "America/Los_Angeles",
		SysTimezone:  "America/Los_Angeles",
		TZOffset:     "-0700",
		TZAbbr:       "PDT",
		TZConsistent: true,

		SysLocale: "en_US",
		SysLang:   "en",
		LocaleCC:  "US",

		ProxyMode: "TUN 全局",
		PACOn:     false,

		DNSVerdict: "正常(Cloudflare)",
		DNSResult:  "104.18.1.1",
		DNSScope:   "本地/代理接管",

		IPChanges: 0,
		VMHost:    "物理机",

		BrOK:     true,
		BrSource: "browser",
		BrTZ:     "America/Los_Angeles",
		BrLangs:  "en-US,en",
		BrLocale: "en-US",
		BrRTC:    "1.2.3.4",
		BrWebGL:  "Test GPU",
		BrFonts:  "PingFang SC",
		BrChPlat: "Linux",
		BrAccept: "en-US,en;q=0.9",

		ClaudeVer: "test",
	}
}

// ──────────────────────────────────────────────────────────────
// Test 1: Perfect baseline = 100 points, 优秀
// ──────────────────────────────────────────────────────────────

func TestBaselinePerfect(t *testing.T) {
	f := baselineFacts()
	r := Evaluate(f)

	if r.Score != 100 {
		t.Errorf("expected score 100, got %d", r.Score)
		for _, s := range r.Signals {
			if s.Points < s.Weight {
				t.Logf("  deduction: %s %d/%d (value=%s issue=%s)", s.Label, s.Points, s.Weight, s.Value, s.Issue)
			}
		}
	}
	if r.Grade != GradeExcellent {
		t.Errorf("expected grade %s, got %s", GradeExcellent, r.Grade)
	}
	if !r.SafeUse {
		t.Error("expected SafeUse=true")
	}
	if r.Verdict != "环境适合运行 Claude" {
		t.Errorf("unexpected verdict: %s", r.Verdict)
	}
	if len(r.CritFails) > 0 {
		t.Errorf("unexpected critical failures: %v", r.CritFails)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 2: Weight sum consistency (all 26 weights sum to 100)
// ──────────────────────────────────────────────────────────────

func TestWeightSumIs100(t *testing.T) {
	f := baselineFacts()
	r := Evaluate(f)

	if len(r.Signals) != 26 {
		t.Fatalf("expected 26 signals, got %d", len(r.Signals))
	}

	sum := 0
	for _, s := range r.Signals {
		sum += s.Weight
	}
	if sum != 100 {
		t.Errorf("weight sum = %d, want 100", sum)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 3: Direct China connection → high risk
// ──────────────────────────────────────────────────────────────

func TestDirectChina(t *testing.T) {
	f := baselineFacts()
	f.Country = "CN"
	f.Country2 = "CN"
	f.Country3 = "CN"
	f.Country4 = "CN"
	f.APICode = 403
	f.WebCode = 403
	f.Consistent = false
	f.SysTimezone = "Asia/Shanghai"
	f.IPTimezone = "America/New_York"
	f.SysLocale = "zh_CN"
	f.SysLang = "zh"
	f.LocaleCC = "CN"
	f.DNSScope = "国内公共DNS(114.114.114.114)"
	f.Hosting = 1
	f.ProxyMode = "直连"

	r := Evaluate(f)

	if r.Score > 50 {
		t.Errorf("China direct should score <= 50, got %d", r.Score)
	}
	if r.Grade != GradeHighRisk {
		// Unsupported region forces 高风险
		t.Errorf("expected grade %s, got %s", GradeHighRisk, r.Grade)
	}
	if r.SafeUse {
		t.Error("SafeUse should be false for China")
	}
	if !strings.Contains(r.Verdict, "中国大陆") {
		t.Errorf("verdict should mention China: %s", r.Verdict)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 4: Typical proxy user (US IDC, China TZ, domestic DNS, IPv6 leak)
// ──────────────────────────────────────────────────────────────

func TestTypicalProxyUser(t *testing.T) {
	f := baselineFacts()
	f.Hosting = 1                             // IDC: -2
	f.SysTimezone = "Asia/Shanghai"           // timezone mismatch: -5
	f.IPTimezone = "America/Los_Angeles"      // target
	f.SysLocale = "zh_CN"                     // locale mismatch: -2
	f.SysLang = "zh"
	f.LocaleCC = "CN"
	f.DNSScope = "国内公共DNS(223.5.5.5)"       // domestic DNS in TUN: -2 (70% of 4 = 2)
	f.IPv6 = "2408:8207::1"
	f.IPv6CC = "CN"                            // IPv6 mismatch: -3

	r := Evaluate(f)

	// Expected deductions: -2 (IDC) -5 (tz) -2 (locale zh) -2 (DNS in TUN)
	// -3 (IPv6) = -14 → 86
	// But wait, with IPv6 as critical fail + timezone as critical fail,
	// grade must be downgraded
	if r.Score > 90 || r.Score < 60 {
		t.Errorf("proxy user score should be 60-90, got %d", r.Score)
	}
	if r.Grade == GradeExcellent {
		t.Error("proxy user should NOT be 优秀 (critical fails)")
	}
	if r.FixableTZ == "" {
		t.Error("timezone should be fixable")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 5: Timezone fix adds exactly 5 points
// ──────────────────────────────────────────────────────────────

func TestTimezoneFixAdds5(t *testing.T) {
	// Case with timezone mismatch (only SysTimezone differs from IPTimezone)
	f1 := baselineFacts()
	f1.SysTimezone = "Asia/Shanghai"
	f1.IPTimezone = "America/Los_Angeles"
	// Set browser TZ = system TZ to isolate the timezone-match signal
	f1.BrTZ = "Asia/Shanghai"
	r1 := Evaluate(f1)

	// Case with timezone fixed
	f2 := baselineFacts()
	f2.SysTimezone = "America/Los_Angeles"
	f2.IPTimezone = "America/Los_Angeles"
	f2.BrTZ = "America/Los_Angeles"
	r2 := Evaluate(f2)

	diff := r2.Score - r1.Score
	if diff != 5 {
		t.Errorf("timezone fix should add exactly 5 points, got %d (before=%d, after=%d)",
			diff, r1.Score, r2.Score)
	}
	if r2.FixableTZ != "" {
		t.Error("FixableTZ should be empty after fix")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 6: PAC + nested proxy + intel conflict
// ──────────────────────────────────────────────────────────────

func TestPACNestedProxy(t *testing.T) {
	f := baselineFacts()
	f.PACOn = true
	f.ProxyMode = "系统 HTTP 代理 + PAC 分流"
	f.CfIP = "9.9.9.9"   // link not single: -3
	f.Country2 = "JP"      // intel mismatch: -3

	r := Evaluate(f)

	// Deductions: PAC 20% of 3=0 (-3), link 0%(-3), intel 0%(-3) = -9 → 91
	// But wait, check the exact scoring:
	// - PAC: weight 3, pct 20 → 3*20/100=0, so -3
	// - CfIP != ProbeIP: weight 3, pct 0 → 0, so -3
	// - Intel: Country=US, Country2=JP disagree → weight 3, pct 0 → 0, so -3
	// Total deduction: -9 → score 91
	// But since PAC is on, grade can still be affected

	foundPACIssue := false
	foundLinkIssue := false
	foundIntelIssue := false
	for _, s := range r.Signals {
		if s.Label == "代理形态" && strings.Contains(s.Issue, "PAC") {
			foundPACIssue = true
		}
		if s.Label == "出口链路单一" && strings.Contains(s.Issue, "一层代理") {
			foundLinkIssue = true
		}
		if s.Label == "多源情报一致" && strings.Contains(s.Issue, "不一致") {
			foundIntelIssue = true
		}
	}
	if !foundPACIssue {
		t.Error("should have PAC issue")
	}
	if !foundLinkIssue {
		t.Error("should have link issue")
	}
	if !foundIntelIssue {
		t.Error("should have intel conflict issue")
	}
	if !r.FixablePAC {
		t.Error("FixablePAC should be true")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 7: DNS pollution → exactly -6 points
// ──────────────────────────────────────────────────────────────

func TestDNSPollution(t *testing.T) {
	f := baselineFacts()
	f.DNSVerdict = "被污染(指向私有地址)"
	f.DNSResult = "127.0.0.1"

	r := Evaluate(f)

	if r.Score != 94 {
		t.Errorf("DNS pollution should score 94, got %d", r.Score)
	}
	if !r.FixableDNS {
		t.Error("FixableDNS should be true")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 8a: API down WITH relay → -5
// ──────────────────────────────────────────────────────────────

func TestAPIDownWithRelay(t *testing.T) {
	f := baselineFacts()
	f.APICode = 0
	f.Relay = "https://relay.example.com"

	r := Evaluate(f)

	if r.Score != 95 {
		t.Errorf("API down with relay should score 95, got %d", r.Score)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 8b: API down WITHOUT relay → -10 (critical)
// ──────────────────────────────────────────────────────────────

func TestAPIDownNoRelay(t *testing.T) {
	f := baselineFacts()
	f.APICode = 0
	f.Relay = ""

	r := Evaluate(f)

	if r.Score != 90 {
		t.Errorf("API down no relay should score 90, got %d", r.Score)
	}
	// Critical fail on API → not 优秀
	if r.Grade == GradeExcellent {
		t.Error("API down should NOT be 优秀 (critical fail)")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 9: Total intel failure → graceful degradation
// ──────────────────────────────────────────────────────────────

func TestTotalIntelFailure(t *testing.T) {
	f := baselineFacts()
	f.Country = ""
	f.Country2 = ""
	f.Country3 = ""
	f.Country4 = ""
	f.IntelSources = ""
	f.IntelCount = 0
	f.CfLoc = ""
	f.CfIP = ""
	f.Hosting = -1

	r := Evaluate(f)

	if r.Score <= 40 {
		t.Errorf("total intel failure should score > 40 (graceful), got %d", r.Score)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 10: WebRTC exposes different IP → -6
// ──────────────────────────────────────────────────────────────

func TestWebRTCLeak(t *testing.T) {
	f := baselineFacts()
	f.BrRTC = "8.8.8.8"

	r := Evaluate(f)

	if r.Score != 94 {
		t.Errorf("WebRTC leak should score 94, got %d", r.Score)
	}
	if r.Grade == GradeExcellent {
		t.Error("WebRTC leak should NOT be 优秀 (critical veto)")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 11: Browser signals missing → neutral 11/17
// ──────────────────────────────────────────────────────────────

func TestBrowserMissing(t *testing.T) {
	f := baselineFacts()
	f.BrOK = false

	r := Evaluate(f)

	// Browser group neutral: WebRTC 70%(4), TZ 70%(2), Lang 70%(1),
	// Intl 100%(1), CH 70%(1), HTTP 100%(1), Render 70%(1) = 11/17
	// So deduction = 17-11 = 6 → score 94
	browserPoints := 0
	for _, s := range r.Signals {
		if s.Group == "浏览器" {
			browserPoints += s.Points
		}
	}
	if browserPoints != 11 {
		t.Errorf("browser neutral should be 11 points, got %d", browserPoints)
	}
	// Score should still allow 优秀 since no critical failure
	if r.Score != 94 {
		t.Errorf("browser missing should score 94, got %d", r.Score)
	}
	if r.Grade != GradeExcellent {
		t.Errorf("browser missing should still be 优秀 (score=%d >= 90), got %s", r.Score, r.Grade)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 12a: Domestic DNS in TUN mode → 2/4 deduction
// ──────────────────────────────────────────────────────────────

func TestDomesticDNSInTUN(t *testing.T) {
	f := baselineFacts()
	f.DNSScope = "国内公共DNS(223.5.5.5)"
	f.ProxyMode = "TUN 全局"

	r := Evaluate(f)

	// DNS exit: weight 4, pct 70 → 4*70/100=2 → deduction -2
	var dnsSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "DNS 出口" {
			dnsSignal = &r.Signals[i]
			break
		}
	}
	if dnsSignal == nil {
		t.Fatal("DNS 出口 signal not found")
	}
	if dnsSignal.Points != 2 {
		t.Errorf("domestic DNS in TUN should get 2/4 points, got %d", dnsSignal.Points)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 12b: Domestic DNS in direct mode → 0/4
// ──────────────────────────────────────────────────────────────

func TestDomesticDNSDirect(t *testing.T) {
	f := baselineFacts()
	f.DNSScope = "国内公共DNS(223.5.5.5)"
	f.ProxyMode = "直连"

	r := Evaluate(f)

	var dnsSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "DNS 出口" {
			dnsSignal = &r.Signals[i]
			break
		}
	}
	if dnsSignal == nil {
		t.Fatal("DNS 出口 signal not found")
	}
	if dnsSignal.Points != 0 {
		t.Errorf("domestic DNS in direct mode should get 0/4, got %d", dnsSignal.Points)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 13a: IPv6 mismatched country → -3 (critical)
// ──────────────────────────────────────────────────────────────

func TestIPv6Mismatch(t *testing.T) {
	f := baselineFacts()
	f.IPv6 = "2408:8207::1"
	f.IPv6CC = "CN"

	r := Evaluate(f)

	if r.Score != 97 {
		t.Errorf("IPv6 mismatch should score 97, got %d", r.Score)
	}
	// Critical fail on IPv6 → not 优秀
	if r.Grade == GradeExcellent {
		t.Error("IPv6 mismatch should NOT be 优秀")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 13b: IPv6 matched country → no deduction
// ──────────────────────────────────────────────────────────────

func TestIPv6Match(t *testing.T) {
	f := baselineFacts()
	f.IPv6 = "2606:4700::1"
	f.IPv6CC = "US"

	r := Evaluate(f)

	if r.Score != 100 {
		t.Errorf("IPv6 match should score 100, got %d", r.Score)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 14: 3-way split route → hard downgrade to "风险"
// ──────────────────────────────────────────────────────────────

func TestThreeWaySplit(t *testing.T) {
	f := baselineFacts()
	f.Consistent = false
	f.CnIP = "1.1.1.1"
	f.IntlIP = "2.2.2.2"

	r := Evaluate(f)

	if r.Grade != GradeRisk {
		t.Errorf("3-way split should force grade=%s, got %s", GradeRisk, r.Grade)
	}
	if r.SafeUse {
		t.Error("3-way split should not be safe")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 15: Score 85-89 boundary → NOT 优秀
// ──────────────────────────────────────────────────────────────

func TestScoreBoundary85_89(t *testing.T) {
	f := baselineFacts()
	f.Hosting = 1                         // IDC: -2
	f.SysTimezone = "Asia/Shanghai"       // tz mismatch: -5
	f.IPTimezone = "America/Los_Angeles"
	f.SysLocale = "zh_CN"                 // locale zh mismatch: -2
	f.SysLang = "zh"
	f.LocaleCC = "CN"
	// Total deduction: -9 → score 91
	// Hmm, that's above 90. Let's add more:
	f.BrLangs = "zh-CN,zh"               // browser lang conflict: -2 (40% of 2 → 0)
	// Now: -11 → score 89

	r := Evaluate(f)

	// Score should be around 87-89
	if r.Score >= 90 {
		t.Errorf("score should be < 90, got %d", r.Score)
	}
	if r.Grade == GradeExcellent {
		t.Error("score < 90 should NOT be 优秀")
	}
}

// ──────────────────────────────────────────────────────────────
// Test 16: WebRTC completed with no public leak → 6/6
// ──────────────────────────────────────────────────────────────

func TestWebRTCNoLeak(t *testing.T) {
	f := baselineFacts()
	f.BrRTC = "" // no public candidate

	r := Evaluate(f)

	var rtcSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "WebRTC 出口" {
			rtcSignal = &r.Signals[i]
			break
		}
	}
	if rtcSignal.Points != 6 {
		t.Errorf("WebRTC no leak should get 6/6, got %d", rtcSignal.Points)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 17: Country code case normalization
// ──────────────────────────────────────────────────────────────

func TestCountryCodeCaseNorm(t *testing.T) {
	f := baselineFacts()
	f.Country = "US"
	f.Country2 = "us"
	f.Country3 = "Us"
	f.Country4 = "uS"

	r := Evaluate(f)

	// Should not flag intel conflict
	var intelSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "多源情报一致" {
			intelSignal = &r.Signals[i]
			break
		}
	}
	if intelSignal.Points != 3 {
		t.Errorf("case-normalized country codes should agree: got %d/3 (issue=%s)",
			intelSignal.Points, intelSignal.Issue)
	}
}

// ──────────────────────────────────────────────────────────────
// Test 18: Accept-Language vs supported region conflict → -1
// ──────────────────────────────────────────────────────────────

func TestHTTPAcceptLangConflict(t *testing.T) {
	f := baselineFacts()
	f.BrAccept = "zh-CN,zh;q=0.9"
	f.BrLangs = "zh-CN,zh"

	r := Evaluate(f)

	var httpSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "HTTP 语言首标" {
			httpSignal = &r.Signals[i]
			break
		}
	}
	if httpSignal.Points != 0 {
		t.Errorf("zh Accept-Language with US exit should get 0/1, got %d", httpSignal.Points)
	}
}

// ──────────────────────────────────────────────────────────────
// Language/Locale Compatibility Tests (from Windows BrowserBridgeTests)
// ──────────────────────────────────────────────────────────────

func TestTaiwanTraditionalFull(t *testing.T) {
	f := baselineFacts()
	f.Country = "TW"
	f.Country2 = "TW"
	f.Country3 = "TW"
	f.Country4 = "TW"
	f.SysLocale = "zh_TW"
	f.SysLang = "zh-TW"
	f.LocaleCC = "TW"
	f.CfLoc = "TW"
	f.CfColo = "TPE"
	f.IPTimezone = "Asia/Taipei"
	f.SysTimezone = "Asia/Taipei"
	f.BrTZ = "Asia/Taipei"
	f.BrLangs = "zh-TW,zh"
	f.BrLocale = "zh-TW"
	f.BrAccept = "zh-TW,zh;q=0.9"

	r := Evaluate(f)

	// TW + zh-TW = full marks on language variant
	var variantSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "语言变体一致" {
			variantSignal = &r.Signals[i]
			break
		}
	}
	if variantSignal.Points != 2 {
		t.Errorf("TW + zh-TW should get 2/2 variant, got %d", variantSignal.Points)
	}

	// Chinese Accept-Language + TW exit is OK
	var httpSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "HTTP 语言首标" {
			httpSignal = &r.Signals[i]
			break
		}
	}
	if httpSignal.Points != 1 {
		t.Errorf("zh Accept-Language with TW exit should get 1/1, got %d", httpSignal.Points)
	}
}

func TestTaiwanEnglishCompat(t *testing.T) {
	f := baselineFacts()
	f.Country = "TW"
	f.Country2 = "TW"
	f.Country3 = "TW"
	f.Country4 = "TW"
	f.SysLocale = "en_US"
	f.SysLang = "en"
	f.LocaleCC = "US"
	f.CfLoc = "TW"
	f.CfColo = "TPE"
	f.IPTimezone = "Asia/Taipei"
	f.SysTimezone = "Asia/Taipei"
	f.BrTZ = "Asia/Taipei"

	r := Evaluate(f)

	// en_US + TW: non-Chinese variant gets full marks
	var variantSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "语言变体一致" {
			variantSignal = &r.Signals[i]
			break
		}
	}
	if variantSignal.Points != 2 {
		t.Errorf("TW + en should get 2/2 variant (non-Chinese), got %d", variantSignal.Points)
	}
}

func TestTaiwanSimplifiedConflict(t *testing.T) {
	f := baselineFacts()
	f.Country = "TW"
	f.Country2 = "TW"
	f.Country3 = "TW"
	f.Country4 = "TW"
	f.SysLocale = "zh_CN"
	f.SysLang = "zh-CN"
	f.LocaleCC = "CN"
	f.CfLoc = "TW"
	f.CfColo = "TPE"
	f.IPTimezone = "Asia/Taipei"
	f.SysTimezone = "Asia/Taipei"
	f.BrTZ = "Asia/Taipei"

	r := Evaluate(f)

	// zh_CN + TW: simplified variant should conflict
	var variantSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "语言变体一致" {
			variantSignal = &r.Signals[i]
			break
		}
	}
	if variantSignal.Points != 1 {
		t.Errorf("TW + zh-CN should get 1/2 variant (conflict), got %d", variantSignal.Points)
	}
	if !strings.Contains(variantSignal.Issue, "简体") {
		t.Errorf("should mention 简体 conflict: %s", variantSignal.Issue)
	}
}

func TestSingaporeSimplifiedCompat(t *testing.T) {
	f := baselineFacts()
	f.Country = "SG"
	f.Country2 = "SG"
	f.SysLocale = "zh_SG"
	f.SysLang = "zh-SG"
	f.LocaleCC = "SG"

	r := Evaluate(f)

	var variantSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "语言变体一致" {
			variantSignal = &r.Signals[i]
			break
		}
	}
	if variantSignal.Points != 2 {
		t.Errorf("SG + zh-SG should get 2/2 variant, got %d", variantSignal.Points)
	}
}

func TestSingaporeTraditionalConflict(t *testing.T) {
	f := baselineFacts()
	f.Country = "SG"
	f.Country2 = "SG"
	f.SysLocale = "zh_TW"
	f.SysLang = "zh-TW"
	f.LocaleCC = "TW"

	r := Evaluate(f)

	var variantSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "语言变体一致" {
			variantSignal = &r.Signals[i]
			break
		}
	}
	if variantSignal.Points != 1 {
		t.Errorf("SG + zh-TW should get 1/2 (繁体 conflict), got %d", variantSignal.Points)
	}
}

func TestUSChineseVariantConflict(t *testing.T) {
	f := baselineFacts()
	f.SysLocale = "zh_CN"
	f.SysLang = "zh-CN"
	f.LocaleCC = "CN"

	r := Evaluate(f)

	var variantSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "语言变体一致" {
			variantSignal = &r.Signals[i]
			break
		}
	}
	if variantSignal.Points != 1 {
		t.Errorf("US + zh-CN should get 1/2 (simplified vs US), got %d", variantSignal.Points)
	}
}

// ──────────────────────────────────────────────────────────────
// Test: HTTP vs JS language mismatch
// ──────────────────────────────────────────────────────────────

func TestHTTPvsJSLangMismatch(t *testing.T) {
	f := baselineFacts()
	f.BrAccept = "zh-CN,zh;q=0.9"
	f.BrLangs = "en-US,en"

	r := Evaluate(f)

	var httpSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "HTTP 语言首标" {
			httpSignal = &r.Signals[i]
			break
		}
	}
	if httpSignal.Points != 0 {
		t.Errorf("HTTP/JS lang mismatch should get 0/1, got %d", httpSignal.Points)
	}
	if !strings.Contains(httpSignal.Issue, "矛盾") {
		t.Errorf("should mention contradiction: %s", httpSignal.Issue)
	}
}

// ──────────────────────────────────────────────────────────────
// Test: Multi-source country divergence blocks locale repair
// ──────────────────────────────────────────────────────────────

func TestIntelDivergenceBlocksLocaleRepair(t *testing.T) {
	f := baselineFacts()
	f.Country = "US"
	f.Country2 = "JP" // intel conflict

	r := Evaluate(f)

	var intelSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "多源情报一致" {
			intelSignal = &r.Signals[i]
			break
		}
	}
	if intelSignal.Points != 0 {
		t.Errorf("intel divergence should get 0/3, got %d", intelSignal.Points)
	}
}

// ──────────────────────────────────────────────────────────────
// Test: Unsupported region blocks TZ and locale repair
// ──────────────────────────────────────────────────────────────

func TestUnsupportedBlocksRepair(t *testing.T) {
	f := baselineFacts()
	f.Country = "CN"
	f.Country2 = "CN"
	f.Country3 = "CN"
	f.Country4 = "CN"

	r := Evaluate(f)

	// Grade should be forced to 高风险 regardless of score
	if r.Grade != GradeHighRisk {
		t.Errorf("unsupported region should force 高风险, got %s", r.Grade)
	}
}

// ──────────────────────────────────────────────────────────────
// Test: Browser not collected uses neutral score
// ──────────────────────────────────────────────────────────────

func TestBrowserNeutralNoFalsePositives(t *testing.T) {
	f := baselineFacts()
	f.BrOK = false

	r := Evaluate(f)

	// No browser-related issues should be reported
	for _, s := range r.Signals {
		if s.Group == "浏览器" && s.Issue != "" {
			t.Errorf("browser neutral should not report issues, but %s has: %s",
				s.Label, s.Issue)
		}
	}
}

// ──────────────────────────────────────────────────────────────
// Test: Virtual machine deduction
// ──────────────────────────────────────────────────────────────

func TestVirtualMachine(t *testing.T) {
	f := baselineFacts()
	f.VMHost = "虚拟机(VMware)"

	r := Evaluate(f)

	var vmSignal *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "运行容器" {
			vmSignal = &r.Signals[i]
			break
		}
	}
	// weight 3, pct 30 → 3*30/100=0
	if vmSignal.Points != 0 {
		t.Errorf("VM should get 0/3, got %d", vmSignal.Points)
	}
}

// ──────────────────────────────────────────────────────────────
// Test: IP stability edge cases
// ──────────────────────────────────────────────────────────────

func TestStabilityThresholds(t *testing.T) {
	tests := []struct {
		changes  int
		expected int // expected points
	}{
		{0, 4},
		{1, 4},
		{2, 2},
		{5, 2},
		{6, 0},
		{20, 0},
	}

	for _, tc := range tests {
		f := baselineFacts()
		f.IPChanges = tc.changes
		r := Evaluate(f)

		var sig *Signal
		for i := range r.Signals {
			if r.Signals[i].Label == "出口稳定性" {
				sig = &r.Signals[i]
				break
			}
		}
		if sig.Points != tc.expected {
			t.Errorf("IPChanges=%d: expected %d points, got %d", tc.changes, tc.expected, sig.Points)
		}
	}
}

// ──────────────────────────────────────────────────────────────
// Test: extractPrimaryLang helper
// ──────────────────────────────────────────────────────────────

func TestExtractPrimaryLang(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"en-US,en;q=0.9", "en"},
		{"zh-CN,zh;q=0.9,en;q=0.8", "zh"},
		{"en", "en"},
		{"zh-TW", "zh"},
		{"", ""},
		{"fr-FR,fr;q=0.9,en-US;q=0.8", "fr"},
	}

	for _, tc := range tests {
		got := extractPrimaryLang(tc.input)
		if got != tc.expected {
			t.Errorf("extractPrimaryLang(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

// ──────────────────────────────────────────────────────────────
// Test: detectVariant helper
// ──────────────────────────────────────────────────────────────

func TestDetectVariant(t *testing.T) {
	tests := []struct {
		locale   string
		lang     string
		expected string
	}{
		{"zh_TW", "zh-TW", "繁体"},
		{"zh_HK", "zh-Hant", "繁体"},
		{"zh_CN", "zh-CN", "简体"},
		{"zh_SG", "zh-SG", "简体"},
		{"zh_CN", "zh-Hans", "简体"},
		{"en_US", "en", "非中文"},
		{"ja_JP", "ja", "非中文"},
		{"", "zh", "简体"}, // bare zh defaults to simplified
	}

	for _, tc := range tests {
		got := detectVariant(tc.locale, tc.lang)
		if got != tc.expected {
			t.Errorf("detectVariant(%q, %q) = %q, want %q", tc.locale, tc.lang, got, tc.expected)
		}
	}
}

// ──────────────────────────────────────────────────────────────
// Test: Client Hints platform detection
// ──────────────────────────────────────────────────────────────

func TestClientHintsPlatform(t *testing.T) {
	// Linux platform = OK
	f := baselineFacts()
	f.BrChPlat = "Linux"
	r := Evaluate(f)

	var chSig *Signal
	for i := range r.Signals {
		if r.Signals[i].Label == "Client Hints" {
			chSig = &r.Signals[i]
			break
		}
	}
	if chSig.Points != 2 {
		t.Errorf("Linux platform should get 2/2, got %d", chSig.Points)
	}

	// macOS platform mismatch on Linux
	f2 := baselineFacts()
	f2.BrChPlat = "macOS"
	r2 := Evaluate(f2)

	for i := range r2.Signals {
		if r2.Signals[i].Label == "Client Hints" {
			chSig = &r2.Signals[i]
			break
		}
	}
	if chSig.Points != 0 {
		t.Errorf("macOS platform on Linux should get 0/2, got %d", chSig.Points)
	}
}
