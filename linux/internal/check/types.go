// Package check implements the CheckClaude scoring engine for Linux.
//
// The engine evaluates 26 weighted signals (total 100 points) across 6 groups
// to determine whether a machine's environment is suitable for running Claude.
package check

// Facts holds all collected data points used by the scoring engine.
// Field names follow the existing macOS/Windows convention.
type Facts struct {
	// Exit & Reachability
	ProbeIP  string // confirmed exit IP (prefer GFW side)
	CnIP     string // domestic exit IP
	IntlIP   string // international exit IP
	GfwIP    string // GFW-side exit IP
	Country  string // primary ISO 3166-1 alpha-2 country code (uppercase)
	Country2 string // secondary source country code
	Country3 string // tertiary source country code
	Country4 string // quaternary source country code

	CountryName string // human-readable country name (Chinese)
	City        string
	ISP         string
	ASN         string // e.g. "AS7922"
	ISP2        string // ipinfo org/ISP for ASN cross-check

	IntelSources string // e.g. "ip-api:US,ipinfo:US,ipwho:US,ip.sb:US"
	IntelCount   int    // number of successful intel sources (0-4)

	Hosting  int  // 0=residential, 1=datacenter, -1=unknown
	Proxy    bool // flagged as public proxy/VPN by intel
	ASNMatch int  // 1=match, 0=mismatch, -1=unknown

	APICode  int // HTTP status from api.anthropic.com
	WebCode  int // HTTP status from claude.ai/robots.txt
	SiteCode int // HTTP status from www.anthropic.com/robots.txt

	Relay string // ANTHROPIC_BASE_URL if configured (non-empty = relay)

	CfColo string // Cloudflare edge colo code (e.g. "LAX")
	CfLoc  string // Cloudflare edge country code
	CfIP   string // IP seen by Cloudflare

	Consistent bool // three-way exit consistency

	// IPv6
	IPv6   string // IPv6 exit address (empty = no IPv6)
	IPv6CC string // IPv6 country code

	// Profile consistency
	IPTimezone  string // IANA timezone from exit IP (e.g. "America/Los_Angeles")
	SysTimezone string // system timezone (IANA on Linux)
	TZOffset    string // current UTC offset string (e.g. "-0700")
	TZAbbr      string // timezone abbreviation (e.g. "PDT")
	TZConsistent bool  // UTC offset matches timezone name

	SysLocale string // system locale (e.g. "en_US.UTF-8", "zh_CN")
	SysLang   string // primary language tag (e.g. "en", "zh")
	LocaleCC  string // country code extracted from locale (e.g. "US", "CN")

	// Proxy & Stability
	ProxyMode string // "TUN 全局", "系统 HTTP 代理", "直连"
	PACOn     bool   // PAC auto-proxy enabled

	DNSVerdict string // e.g. "正常(Cloudflare)", "被污染(指向私有地址)"
	DNSResult  string // raw DNS resolution result
	DNSScope   string // e.g. "本地/代理接管", "国内公共DNS(223.5.5.5)"

	IPChanges int    // confirmed IP changes in last 24h
	VMHost    string // "物理机" or VM hypervisor name

	// Browser signals (from bridge)
	BrOK     bool   // browser signals successfully collected
	BrSource string // "browser" if from real browser
	BrTZ     string // browser Intl timezone
	BrLangs  string // navigator.languages joined
	BrLocale string // Intl.DateTimeFormat locale
	BrRTC    string // WebRTC srflx IPs (comma-separated)
	BrWebGL  string // WebGL renderer string
	BrFonts  string // detected CJK fonts
	BrChPlat string // Client Hints platform (e.g. "Windows", "Linux")
	BrAccept string // Accept-Language header value

	// Version
	ClaudeVer string // checkclaude version
}

// Signal represents a single scored signal in the report.
type Signal struct {
	Group  string `json:"group"`
	Label  string `json:"label"`
	Weight int    `json:"weight"`
	Points int    `json:"points"`
	Value  string `json:"value"`
	Issue  string `json:"issue,omitempty"`
	Fix    string `json:"fix,omitempty"`
}

// Report is the complete evaluation result.
type Report struct {
	Version   string   `json:"version"`
	Score     int      `json:"score"`
	Grade     string   `json:"grade"`
	RiskLevel string   `json:"riskLevel"`
	SafeUse   bool     `json:"safeUse"`
	Verdict   string   `json:"verdict"`
	Country   string   `json:"country"`
	City      string   `json:"city"`
	Consistent bool   `json:"consistent"`
	Fixable   []string `json:"fixable"`
	Manual    []string `json:"manual"`
	Signals   []Signal `json:"signals"`

	// Internal fields for fix logic (not in JSON)
	FixableTZ     string `json:"-"`
	FixableLocale string `json:"-"`
	FixablePAC    bool   `json:"-"`
	FixableDNS    bool   `json:"-"`
	CritFails     []string `json:"-"`
}

// Grade constants
const (
	GradeExcellent = "优秀"
	GradeRisky     = "有风险"
	GradeRisk      = "风险"     // hard block: inconsistent exit
	GradeHighRisk  = "高风险"
	GradeDanger    = "危险"
)

// Risk level constants (for JSON output)
const (
	RiskSafe   = "安全"
	RiskLow    = "低风险"
	RiskMedium = "中风险"
	RiskHigh   = "高风险"
	RiskCrit   = "极高风险"
)
