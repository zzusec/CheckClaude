package check

import (
	"fmt"
	"strings"
)

// Country lists -----------------------------------------------------------

// UnsupportedCC lists countries/regions where Anthropic does not operate.
var UnsupportedCC = map[string]bool{
	"CN": true, "HK": true, "MO": true,
	"RU": true, "IR": true, "KP": true,
	"CU": true, "SY": true, "BY": true,
	"VE": true,
}

// SupportedCC lists countries/regions known to be supported by Anthropic.
var SupportedCC = map[string]bool{
	"US": true, "CA": true, "GB": true, "IE": true,
	"DE": true, "FR": true, "NL": true, "SE": true,
	"NO": true, "DK": true, "FI": true, "IT": true,
	"ES": true, "PT": true, "PL": true, "CZ": true,
	"AT": true, "CH": true, "BE": true, "LU": true,
	"JP": true, "KR": true, "SG": true, "TW": true,
	"AU": true, "NZ": true, "IL": true, "AE": true,
	"MX": true, "BR": true, "IN": true, "PH": true,
	"TH": true, "MY": true, "ID": true, "VN": true,
	"ZA": true, "TR": true, "SA": true, "AR": true,
	"CL": true,
}

// TraditionalChinese regions where traditional Chinese script is expected.
var TraditionalCC = map[string]bool{"TW": true, "HK": true, "MO": true}

// SimplifiedChinese regions where simplified Chinese script is expected.
var SimplifiedCC = map[string]bool{"CN": true, "SG": true, "MY": true}

// ChineseAcceptCC: countries where Chinese Accept-Language is not contradictory.
var ChineseAcceptCC = map[string]bool{
	"CN": true, "HK": true, "TW": true, "MO": true, "SG": true,
}

// Domestic DNS servers that indicate DNS leak when used without tunnel.
var DomesticDNS = map[string]bool{
	"114.114.114.114": true, "114.114.115.115": true,
	"223.5.5.5": true, "223.6.6.6": true,
	"119.29.29.29": true, "182.254.116.116": true,
	"180.76.76.76": true, "117.50.10.10": true,
	"1.2.4.8": true, "210.2.4.8": true,
}

// RegionNote returns a Chinese explanation for blocked regions.
func RegionNote(cc string) string {
	switch cc {
	case "CN":
		return "中国大陆：Anthropic 未在此开放服务，登录、订阅与 API 申请均会被拒"
	case "HK", "MO":
		return "港澳：不在 Anthropic 支持地区列表内，与大陆同样不可用"
	case "RU", "BY":
		return "俄罗斯/白俄罗斯：受制裁限制，服务与订阅不可用"
	case "IR", "KP", "CU", "SY":
		return "受美国制裁地区，Anthropic 服务完全不可用"
	case "VE":
		return "委内瑞拉：不在支持地区列表内"
	default:
		return "该地区不在 Anthropic 支持列表内"
	}
}

// Critical signals that trigger veto (cannot achieve "优秀" if any fails).
var CriticalLabels = map[string]bool{
	"出口国家":          true,
	"Anthropic API 可达": true,
	"系统时区匹配出口":     true,
	"WebRTC 出口":       true,
	"IPv6 出口":         true,
	"三路出口一致":        true,
}

// Evaluate runs the 26-signal scoring engine on the given facts.
func Evaluate(f *Facts) *Report {
	r := &Report{
		Version:    f.ClaudeVer,
		Country:    f.Country,
		City:       f.City,
		Consistent: f.Consistent,
	}

	var signals []Signal

	// Helper: add a signal
	add := func(group, label string, weight, pct int, value, issue, fix string) {
		points := weight * pct / 100
		signals = append(signals, Signal{
			Group:  group,
			Label:  label,
			Weight: weight,
			Points: points,
			Value:  value,
			Issue:  issue,
			Fix:    fix,
		})
	}

	cc := strings.ToUpper(f.Country)

	// ── A. Exit & Reachability (6 signals, weight 34) ──

	// 1. 出口国家 (14)
	evalExitCountry(f, cc, add)

	// 2. Anthropic API 可达 (10)
	evalAPIReachable(f, add)

	// 3. claude.ai 可达 (2)
	evalWebReachable(f, add, "claude.ai 可达", f.WebCode, "claude.ai")

	// 4. anthropic.com 可达 (2)
	evalWebReachable(f, add, "anthropic.com 可达", f.SiteCode, "anthropic.com")

	// 5. 多源情报一致 (3)
	evalIntelConsistency(f, add)

	// 6. IPv6 出口 (3)
	evalIPv6(f, cc, add)

	// ── B. Exit Quality (3 signals, weight 10) ──

	// 7. IP 类型 (4)
	evalIPType(f, add)

	// 8. 边缘机房匹配 (3)
	evalEdgeMatch(f, cc, add)

	// 9. 出口链路单一 (3)
	evalLinkSingle(f, add)

	// ── C. Profile Consistency (5 signals, weight 19) ──

	// 10. 三路出口一致 (6)
	evalThreeWay(f, add)

	// 11. 系统时区匹配出口 (5)
	evalTimezone(f, r, add)

	// 12. 时区偏移自洽 (2)
	evalTZOffset(f, add)

	// 13. 系统区域匹配出口 (4)
	evalLocaleMatch(f, cc, r, add)

	// 14. 语言变体一致 (2)
	evalLangVariant(f, cc, add)

	// ── D. DNS (2 signals, weight 10) ──

	// 15. claude.ai 解析 (6)
	evalDNSResolve(f, r, add)

	// 16. DNS 出口 (4)
	evalDNSExit(f, r, add)

	// ── E. Stability & Environment (3 signals, weight 10) ──

	// 17. 代理形态 (3)
	evalProxyForm(f, r, add)

	// 18. 出口稳定性 (4)
	evalStability(f, add)

	// 19. 运行容器 (3)
	evalContainer(f, add)

	// ── F. Browser Fingerprint (7 signals, weight 17) ──

	if !f.BrOK {
		// Browser not collected: use neutral defaults
		addNeutralBrowser(add)
	} else {
		// 20. WebRTC 出口 (6)
		evalWebRTC(f, add)

		// 21. 浏览器时区 (3)
		evalBrowserTZ(f, add)

		// 22. 浏览器语言 (2)
		evalBrowserLang(f, cc, add)

		// 23. Intl 区域设置 (1)
		evalBrowserIntl(f, cc, add)

		// 24. Client Hints (2)
		evalClientHints(f, add)

		// 25. HTTP 语言首标 (1)
		evalHTTPLang(f, cc, add)

		// 26. 渲染环境 (2)
		evalRenderEnv(f, add)
	}

	r.Signals = signals

	// Calculate total score
	totalScore := 0
	for _, s := range signals {
		totalScore += s.Points
	}
	r.Score = totalScore

	// Collect issues, fixes, fixable items, manual items, and critical failures
	for _, s := range signals {
		if s.Issue != "" {
			r.Fixable = appendIfFixable(r.Fixable, s)
			r.Manual = appendIfManual(r.Manual, s)
		}

		// Critical check
		if CriticalLabels[s.Label] && s.Points < s.Weight {
			// WebRTC special: only veto if points == 0
			if s.Label == "WebRTC 出口" && s.Points > 0 {
				continue
			}
			r.CritFails = append(r.CritFails, s.Label)
		}
	}

	// Build fixable/manual lists
	r.Fixable = nil
	r.Manual = nil
	for _, s := range signals {
		if s.Fix == "" {
			continue
		}
		r.Manual = append(r.Manual, fmt.Sprintf("%s: %s", s.Label, s.Fix))
	}
	if r.FixableTZ != "" {
		r.Fixable = append(r.Fixable, "系统时区 → "+r.FixableTZ)
	}
	if r.FixablePAC {
		r.Fixable = append(r.Fixable, "关闭 PAC 分流")
	}
	if r.FixableDNS {
		r.Fixable = append(r.Fixable, "修复 DNS")
	}
	if r.FixableLocale != "" {
		r.Fixable = append(r.Fixable, "系统区域 → "+r.FixableLocale)
	}

	// Determine grade
	determineGrade(f, r, cc)

	return r
}

func appendIfFixable(_ []string, _ Signal) []string { return nil }
func appendIfManual(_ []string, _ Signal) []string  { return nil }

// ── Signal Evaluators ──

type addFn func(group, label string, weight, pct int, value, issue, fix string)

func evalExitCountry(f *Facts, cc string, add addFn) {
	if cc == "" {
		add("出口", "出口国家", 14, 50, "未知",
			"出口 IP 归属地未知(IP 情报接口不可达)", "检查网络后重新体检")
		return
	}
	if UnsupportedCC[cc] {
		add("出口", "出口国家", 14, 0,
			cc+" 不支持",
			fmt.Sprintf("出口国家 %s 不在 Anthropic 服务范围，登录/订阅/API 均有封号风险", cc),
			"切到美国/日本/新加坡等支持地区节点，并长期固定，不要频繁换国家")
		return
	}
	if SupportedCC[cc] {
		val := cc
		if f.City != "" {
			val = cc + " " + f.City
		}
		add("出口", "出口国家", 14, 100, val, "", "")
		return
	}
	// Unknown support status
	add("出口", "出口国家", 14, 66, cc+" 支持未知",
		fmt.Sprintf("出口国家 %s 支持情况未知", cc),
		"建议改用 US/JP/SG 等已知支持地区节点")
}

func evalAPIReachable(f *Facts, add addFn) {
	code := f.APICode
	switch {
	case code == 401 || code == 400:
		add("出口", "Anthropic API 可达", 10, 100,
			fmt.Sprintf("HTTP %d", code), "", "")
	case code == 403:
		add("出口", "Anthropic API 可达", 10, 0,
			"HTTP 403 地区拦截",
			"api.anthropic.com 返回 403，当前出口被地区拦截",
			"更换支持地区节点；确认代理为全局而非 PAC 分流")
	case code == 0 && f.Relay != "":
		add("出口", "Anthropic API 可达", 10, 50,
			"直连不通(已配中转)",
			fmt.Sprintf("api.anthropic.com 直连不通，但你已配置中转 %s", f.Relay),
			"只用中转可忽略；需直连官方则开全局代理")
	case code == 0:
		add("出口", "Anthropic API 可达", 10, 0,
			"连不上",
			"api.anthropic.com 连不上(超时/DNS 污染)",
			"开启全局代理；检查 DNS 是否被污染")
	default:
		add("出口", "Anthropic API 可达", 10, 50,
			fmt.Sprintf("HTTP %d", code),
			fmt.Sprintf("api.anthropic.com 返回异常状态 %d", code),
			"稍后重试；持续异常则换节点")
	}
}

func evalWebReachable(f *Facts, add addFn, label string, code int, host string) {
	switch {
	case code == 200 || code == 301 || code == 302 || code == 307:
		add("出口", label, 2, 100,
			fmt.Sprintf("HTTP %d", code), "", "")
	case code == 403:
		add("出口", label, 2, 20,
			"HTTP 403 被拦",
			fmt.Sprintf("%s 返回 403(Cloudflare 地区拦截或风控挑战)", host),
			"换支持地区的干净节点")
	case code == 0:
		add("出口", label, 2, 0,
			"连不上",
			fmt.Sprintf("%s 连不上", host),
			"开启全局代理")
	default:
		add("出口", label, 2, 60,
			fmt.Sprintf("HTTP %d", code), "", "")
	}
}

func evalIntelConsistency(f *Facts, add addFn) {
	// Unify all country codes to uppercase for comparison
	codes := []string{
		strings.ToUpper(f.Country),
		strings.ToUpper(f.Country2),
		strings.ToUpper(f.Country3),
		strings.ToUpper(f.Country4),
	}

	// Count valid (non-empty) codes
	validCount := 0
	uniqueSet := make(map[string]bool)
	for _, c := range codes {
		if c != "" {
			validCount++
			uniqueSet[c] = true
		}
	}

	switch {
	case validCount >= 2 && len(uniqueSet) == 1:
		// All agree
		cc := codes[0]
		if f.ASNMatch == 0 {
			// ASN divergence
			add("出口", "多源情报一致", 3, 50,
				fmt.Sprintf("%d/4 · %s · ASN 分歧", f.IntelCount, cc),
				fmt.Sprintf("同一出口 %s 的 ASN 归属不一致(ip-api: %s %s / ipinfo: %s)，这段 IP 的登记信息本身有争议",
					f.ProbeIP, f.ASN, f.ISP, f.ISP2),
				"换一个 ASN 归属明确、各情报库口径一致的节点")
		} else {
			add("出口", "多源情报一致", 3, 100,
				fmt.Sprintf("%d/4 · %s", f.IntelCount, cc), "", "")
		}
	case validCount >= 2 && len(uniqueSet) > 1:
		// Disagreement
		ccList := make([]string, 0, len(uniqueSet))
		for c := range uniqueSet {
			ccList = append(ccList, c)
		}
		display := strings.Join(ccList, " / ")
		add("出口", "多源情报一致", 3, 0,
			fmt.Sprintf("%d/4 · %s", f.IntelCount, display),
			fmt.Sprintf("多家 IP 情报库对同一出口 %s 的国家码判定不一致(%s)", f.ProbeIP, f.IntelSources),
			"换一个情报干净、归属明确的节点")
	default:
		// Insufficient data
		val := fmt.Sprintf("%d/4 · 数据不足", validCount)
		if validCount == 1 {
			val = fmt.Sprintf("仅 1/4 来源可用 · %s", codes[0])
		}
		add("出口", "多源情报一致", 3, 50, val, "", "")
	}
}

func evalIPv6(f *Facts, cc string, add addFn) {
	if f.IPv6 == "" {
		add("出口", "IPv6 出口", 3, 100, "无 IPv6(无泄漏面)", "", "")
		return
	}
	v6cc := strings.ToUpper(f.IPv6CC)
	if v6cc == "" {
		// IPv6 present but can't determine country
		ipDisplay := f.IPv6
		if len(ipDisplay) > 20 {
			ipDisplay = ipDisplay[:20] + "…"
		}
		add("出口", "IPv6 出口", 3, 60,
			ipDisplay+" 归属未知",
			"IPv6 出口存在但查不到归属", "")
		return
	}
	if v6cc == cc {
		add("出口", "IPv6 出口", 3, 100,
			v6cc+" 与 IPv4 一致", "", "")
	} else {
		add("出口", "IPv6 出口", 3, 0,
			v6cc+" ≠ "+cc,
			fmt.Sprintf("IPv6 出口在 %s，与 IPv4 出口 %s 不一致 —— 代理没接管 IPv6，真实地区被暴露", v6cc, cc),
			"在代理里开启 IPv6 接管，或在系统网络设置里关掉 IPv6")
	}
}

func evalIPType(f *Facts, add addFn) {
	switch {
	case f.Proxy:
		add("质量", "IP 类型", 4, 25, "公开代理/VPN",
			"出口 IP 被标记为公开代理/VPN 出口，属高风控段",
			"换独享节点或住宅 IP，避免与大量用户共用出口")
	case f.Hosting == 0 && f.ASNMatch == 0:
		add("质量", "IP 类型", 4, 70, "住宅(归属存疑)",
			fmt.Sprintf("ip-api 判该出口为住宅(%s)，但 ipinfo 归到 %s —— 可能是机房段被标成住宅", f.ISP, f.ISP2),
			"优先选各情报库一致认定为住宅/家宽的节点")
	case f.Hosting == 0:
		add("质量", "IP 类型", 4, 100, "住宅", "", "")
	case f.Hosting == 1:
		add("质量", "IP 类型", 4, 50, "机房 IDC",
			fmt.Sprintf("出口是机房(IDC) IP: %s，风控强度高于住宅", f.ISP),
			"有条件换住宅/家宽节点；至少保证独享且长期不变")
	default: // -1 unknown
		add("质量", "IP 类型", 4, 70, "未知", "", "")
	}
}

func evalEdgeMatch(f *Facts, cc string, add addFn) {
	cfLoc := strings.ToUpper(f.CfLoc)
	switch {
	case cfLoc == "" || cc == "":
		val := f.CfColo
		if val == "" {
			val = "未知"
		}
		add("质量", "边缘机房匹配", 3, 50, val, "", "")
	case cfLoc == cc:
		add("质量", "边缘机房匹配", 3, 100,
			fmt.Sprintf("%s (%s)", f.CfColo, cfLoc), "", "")
	default:
		add("质量", "边缘机房匹配", 3, 25,
			fmt.Sprintf("%s(%s) ≠ %s", f.CfColo, cfLoc, cc),
			fmt.Sprintf("Cloudflare 边缘落在 %s，与 IP 库归属 %s 不一致", cfLoc, cc),
			"该 IP 的地理归属可能是伪造的，换归属真实的节点")
	}
}

func evalLinkSingle(f *Facts, add addFn) {
	switch {
	case f.CfIP == "" || f.ProbeIP == "" || f.ProbeIP == "?":
		add("质量", "出口链路单一", 3, 50, "数据不足", "", "")
	case f.CfIP == f.ProbeIP:
		add("质量", "出口链路单一", 3, 100, f.CfIP, "", "")
	default:
		add("质量", "出口链路单一", 3, 0,
			f.CfIP+" ≠ "+f.ProbeIP,
			fmt.Sprintf("Cloudflare 看到的来源 %s 与检测到的出口 %s 不同，链路上还有一层代理", f.CfIP, f.ProbeIP),
			"统一走同一出口，避免多层嵌套代理")
	}
}

func evalThreeWay(f *Facts, add addFn) {
	if f.Consistent {
		add("画像", "三路出口一致", 6, 100, f.ProbeIP, "", "")
	} else {
		val := "不一致"
		add("画像", "三路出口一致", 6, 30, val,
			"三路出口 IP 不一致(分流/PAC/DNS 泄漏)，账号画像会在多地区间跳变",
			"代理切全局模式，让国内/国外/谷歌三路走同一出口")
	}
}

func evalTimezone(f *Facts, r *Report, add addFn) {
	if f.IPTimezone == "" {
		add("画像", "系统时区匹配出口", 5, 50, "出口时区未知",
			"无法解析出口 IP 对应时区", "")
		return
	}
	if f.SysTimezone == f.IPTimezone {
		add("画像", "系统时区匹配出口", 5, 100, f.SysTimezone, "", "")
		return
	}
	// Mismatch
	r.FixableTZ = f.IPTimezone
	add("画像", "系统时区匹配出口", 5, 0,
		f.SysTimezone+" ≠ "+f.IPTimezone,
		fmt.Sprintf("系统时区 %s 与出口时区 %s 不一致，是典型的环境矛盾信号", f.SysTimezone, f.IPTimezone),
		fmt.Sprintf("可一键修复: 把系统时区改为 %s", f.IPTimezone))
}

func evalTZOffset(f *Facts, add addFn) {
	if f.TZConsistent {
		val := f.TZOffset
		if f.TZAbbr != "" {
			val = f.TZOffset + " " + f.TZAbbr
		}
		add("画像", "时区偏移自洽", 2, 100, val, "", "")
	} else {
		add("画像", "时区偏移自洽", 2, 0, "偏移与时区名冲突",
			fmt.Sprintf("当前 UTC 偏移 %s 与时区 %s 不符(可能被 TZ 环境变量覆盖)", f.TZOffset, f.SysTimezone),
			"清掉 shell 里的 TZ 环境变量")
	}
}

func evalLocaleMatch(f *Facts, cc string, r *Report, add addFn) {
	locCC := strings.ToUpper(f.LocaleCC)

	if cc == "" || locCC == "" {
		add("画像", "系统区域匹配出口", 4, 50, "数据不足", "", "")
		return
	}
	if locCC == cc {
		add("画像", "系统区域匹配出口", 4, 100, f.SysLocale, "", "")
		return
	}

	// Mismatch: check if Chinese language (harsher penalty)
	lang := strings.ToLower(f.SysLang)
	if strings.HasPrefix(lang, "zh") {
		r.FixableLocale = cc
		add("画像", "系统区域匹配出口", 4, 50,
			f.SysLocale+" vs "+cc,
			fmt.Sprintf("系统语言中文 + 区域 %s 与出口 %s 不一致(网页端登录会暴露矛盾)", locCC, cc),
			fmt.Sprintf("仅用 Claude Code(CLI) 可忽略；常用网页端可把系统区域改成 %s(不用改显示语言)", cc))
	} else {
		r.FixableLocale = cc
		add("画像", "系统区域匹配出口", 4, 70,
			f.SysLocale+" vs "+cc,
			fmt.Sprintf("系统区域 %s 与出口 %s 不一致", locCC, cc),
			"")
	}
}

func evalLangVariant(f *Facts, cc string, add addFn) {
	variant := detectVariant(f.SysLocale, f.SysLang)

	switch variant {
	case "繁体":
		if TraditionalCC[cc] {
			add("画像", "语言变体一致", 2, 100, "繁体 · "+cc, "", "")
		} else {
			add("画像", "语言变体一致", 2, 50, "繁体 vs "+cc,
				fmt.Sprintf("系统用繁体中文但出口在 %s，语言变体与地区画像不对应", cc),
				"仅用 CLI 可忽略；网页端登录前可把首选语言调成 en-US")
		}
	case "简体":
		if SimplifiedCC[cc] {
			add("画像", "语言变体一致", 2, 100, "简体 · "+cc, "", "")
		} else {
			add("画像", "语言变体一致", 2, 50, "简体 vs "+cc,
				fmt.Sprintf("系统用简体中文但出口在 %s，语言变体与地区画像不对应", cc),
				"仅用 CLI 可忽略；网页端登录前可把首选语言调成 en-US")
		}
	default: // non-Chinese or bare "zh"
		add("画像", "语言变体一致", 2, 100, variant, "", "")
	}
}

// detectVariant determines Chinese script variant from locale/lang.
func detectVariant(locale, lang string) string {
	lower := strings.ToLower(locale + " " + lang)
	// Check for traditional Chinese indicators
	if strings.Contains(lower, "hant") ||
		strings.Contains(lower, "zh-tw") || strings.Contains(lower, "zh_tw") ||
		strings.Contains(lower, "zh-hk") || strings.Contains(lower, "zh_hk") ||
		strings.Contains(lower, "zh-mo") || strings.Contains(lower, "zh_mo") {
		return "繁体"
	}
	// Check for simplified Chinese indicators
	if strings.Contains(lower, "hans") ||
		strings.Contains(lower, "zh-cn") || strings.Contains(lower, "zh_cn") ||
		strings.Contains(lower, "zh-sg") || strings.Contains(lower, "zh_sg") {
		return "简体"
	}
	// Bare "zh" without region
	if strings.HasPrefix(strings.ToLower(lang), "zh") {
		return "简体" // default bare zh to simplified
	}
	return "非中文"
}

func evalDNSResolve(f *Facts, r *Report, add addFn) {
	v := f.DNSVerdict
	switch {
	case strings.Contains(v, "正常") || strings.Contains(v, "代理接管"):
		add("DNS", "claude.ai 解析", 6, 100, v, "", "")
	case strings.Contains(v, "被污染"):
		r.FixableDNS = true
		add("DNS", "claude.ai 解析", 6, 0, v,
			fmt.Sprintf("claude.ai 的 DNS 解析被污染(%s)", f.DNSResult),
			"换 DoH/加密 DNS，或让代理接管 DNS(fake-ip 模式)")
	case strings.Contains(v, "失败") || v == "":
		add("DNS", "claude.ai 解析", 6, 20, "失败",
			"claude.ai 无法解析", "检查 DNS 设置，建议让代理接管 DNS")
	default:
		// Suspicious
		add("DNS", "claude.ai 解析", 6, 40,
			fmt.Sprintf("可疑(%s)", f.DNSResult),
			fmt.Sprintf("claude.ai 解析到非 Cloudflare 地址(%s)，可能被劫持", f.DNSResult),
			"换 DoH/加密 DNS 或由代理接管 DNS")
	}
}

func evalDNSExit(f *Facts, r *Report, add addFn) {
	scope := f.DNSScope
	isTUN := f.ProxyMode == "TUN 全局"
	isDomestic := strings.Contains(scope, "国内公共DNS")

	switch {
	case strings.Contains(scope, "本地/代理接管"):
		add("DNS", "DNS 出口", 4, 100, scope, "", "")
	case isDomestic && isTUN:
		r.FixableDNS = true
		add("DNS", "DNS 出口", 4, 70, scope+" (走隧道)",
			"用的是国内公共 DNS，虽然 TUN 下查询走隧道不算泄漏，但没必要绕这一圈",
			"换成 1.1.1.1 / 8.8.8.8")
	case isDomestic:
		r.FixableDNS = true
		add("DNS", "DNS 出口", 4, 0, scope,
			fmt.Sprintf("正在用%s，DNS 查询泄漏到国内，与国外出口矛盾", scope),
			"改用 1.1.1.1 / 8.8.8.8 或让代理接管 DNS")
	case isTUN:
		add("DNS", "DNS 出口", 4, 100, scope+" (走隧道)", "", "")
	default:
		add("DNS", "DNS 出口", 4, 80, scope, "", "")
	}
}

func evalProxyForm(f *Facts, r *Report, add addFn) {
	if f.PACOn {
		r.FixablePAC = true
		add("稳定", "代理形态", 3, 20, f.ProxyMode,
			"启用了 PAC 自动分流，不同网站会走不同出口，账号画像不稳定",
			"关掉 PAC，改用 TUN 全局模式")
		return
	}
	switch f.ProxyMode {
	case "TUN 全局":
		add("稳定", "代理形态", 3, 100, "TUN 全局", "", "")
	default:
		add("稳定", "代理形态", 3, 70, f.ProxyMode, "", "")
	}
}

func evalStability(f *Facts, add addFn) {
	n := f.IPChanges
	switch {
	case n <= 1:
		add("稳定", "出口稳定性", 4, 100,
			fmt.Sprintf("24h 内 %d 次跳变", n), "", "")
	case n <= 5:
		add("稳定", "出口稳定性", 4, 50,
			fmt.Sprintf("24h 内 %d 次跳变", n),
			fmt.Sprintf("24 小时内出口 IP 变了 %d 次，设备连续性差", n),
			"固定一个节点用，别让代理自动切换线路")
	default:
		add("稳定", "出口稳定性", 4, 0,
			fmt.Sprintf("24h 内 %d 次跳变", n),
			fmt.Sprintf("24 小时内出口 IP 变了 %d 次，账号画像极不稳定", n),
			"关掉代理的自动切换/负载均衡，固定单一落地节点")
	}
}

func evalContainer(f *Facts, add addFn) {
	if f.VMHost == "物理机" || f.VMHost == "" {
		host := f.VMHost
		if host == "" {
			host = "物理机"
		}
		add("稳定", "运行容器", 3, 100, host, "", "")
	} else {
		add("稳定", "运行容器", 3, 30, f.VMHost,
			fmt.Sprintf("运行在%s中，设备指纹异常是风控关注的信号", f.VMHost),
			"尽量在物理机上登录和使用 Claude")
	}
}

// ── Browser signal evaluators ──

func addNeutralBrowser(add addFn) {
	add("浏览器", "WebRTC 出口", 6, 70, "未采集", "", "")
	add("浏览器", "浏览器时区", 3, 70, "未采集", "", "")
	add("浏览器", "浏览器语言", 2, 70, "未采集", "", "")
	add("浏览器", "Intl 区域设置", 1, 100, "未采集", "", "")
	add("浏览器", "Client Hints", 2, 70, "未采集", "", "")
	add("浏览器", "HTTP 语言首标", 1, 100, "未采集", "", "")
	add("浏览器", "渲染环境", 2, 70, "未采集", "", "")
}

func evalWebRTC(f *Facts, add addFn) {
	rtc := strings.TrimSpace(f.BrRTC)
	if rtc == "" {
		// No public candidate found = good
		add("浏览器", "WebRTC 出口", 6, 100,
			"检测完成，无公网候选", "", "")
		return
	}
	// Check if leak IPs match probe IP
	ips := strings.Split(rtc, ",")
	leaks := []string{}
	for _, ip := range ips {
		ip = strings.TrimSpace(ip)
		if ip != "" && ip != f.ProbeIP {
			leaks = append(leaks, ip)
		}
	}
	if len(leaks) == 0 {
		add("浏览器", "WebRTC 出口", 6, 100,
			rtc+" = 出口", "", "")
		return
	}
	// Leak detected
	add("浏览器", "WebRTC 出口", 6, 0,
		fmt.Sprintf("%d 个泄漏", len(leaks)),
		fmt.Sprintf("WebRTC 暴露了 %d 个非代理出口(首个 %s)，UDP 绕过了代理", len(leaks), leaks[0]),
		"代理开 TUN 全局(接管 UDP)，或在浏览器里禁用 WebRTC")
}

func evalBrowserTZ(f *Facts, add addFn) {
	if f.BrTZ == f.SysTimezone {
		add("浏览器", "浏览器时区", 3, 100, f.BrTZ, "", "")
	} else {
		add("浏览器", "浏览器时区", 3, 25,
			f.BrTZ+" ≠ "+f.SysTimezone,
			fmt.Sprintf("浏览器时区 %s 与系统时区 %s 不一致", f.BrTZ, f.SysTimezone),
			"重启浏览器让它重新读系统时区")
	}
}

func evalBrowserLang(f *Facts, cc string, add addFn) {
	langs := f.BrLangs
	if strings.HasPrefix(strings.ToLower(langs), "zh") && SupportedCC[cc] && !ChineseAcceptCC[cc] {
		add("浏览器", "浏览器语言", 2, 40,
			langs+" vs "+cc,
			fmt.Sprintf("浏览器语言 %s 与出口地区 %s 矛盾(网页端登录时直接可见)", langs, cc),
			"网页端登录前把浏览器首选语言调成 en-US")
	} else {
		add("浏览器", "浏览器语言", 2, 100, langs, "", "")
	}
}

func evalBrowserIntl(f *Facts, cc string, add addFn) {
	loc := f.BrLocale
	if loc == "" || cc == "" || strings.HasSuffix(strings.ToUpper(loc), "-"+cc) {
		add("浏览器", "Intl 区域设置", 1, 100, loc, "", "")
	} else {
		add("浏览器", "Intl 区域设置", 1, 50,
			loc+" vs "+cc,
			fmt.Sprintf("浏览器 Intl 区域 %s 与出口 %s 不对应", loc, cc),
			"浏览器设置里把语言/区域调成与出口地区一致")
	}
}

func evalClientHints(f *Facts, add addFn) {
	plat := f.BrChPlat
	if plat == "" {
		// Firefox/Safari don't provide; OK
		add("浏览器", "Client Hints", 2, 100, "该浏览器不提供", "", "")
		return
	}
	// On Linux, we expect "Linux"
	if strings.Contains(plat, "Linux") {
		add("浏览器", "Client Hints", 2, 100, plat, "", "")
		return
	}
	// Non-real browser source
	if f.BrSource != "browser" {
		add("浏览器", "Client Hints", 2, 70, "内置引擎未采集请求头", "", "")
		return
	}
	// Platform mismatch
	add("浏览器", "Client Hints", 2, 0, plat+" ≠ Linux",
		"浏览器请求头平台与系统不一致，可能使用了 UA 伪装扩展",
		"关闭浏览器里改 UA 的插件，用原生浏览器打开 claude.ai")
}

func evalHTTPLang(f *Facts, cc string, add addFn) {
	accept := f.BrAccept
	if accept == "" {
		add("浏览器", "HTTP 语言首标", 1, 100, "", "", "")
		return
	}

	// Check Accept-Language vs navigator.languages consistency
	acceptFirst := extractPrimaryLang(accept)
	jsFirst := extractPrimaryLang(f.BrLangs)
	if acceptFirst != "" && jsFirst != "" && acceptFirst != jsFirst {
		add("浏览器", "HTTP 语言首标", 1, 0,
			acceptFirst+" ≠ "+jsFirst,
			"HTTP Accept-Language 与 navigator.languages 首选语言不一致，浏览器画像存在矛盾",
			"统一浏览器首选语言，并关闭修改请求头的扩展")
		return
	}

	// Check if Chinese Accept-Language conflicts with exit country
	if strings.HasPrefix(strings.ToLower(accept), "zh") && !ChineseAcceptCC[cc] {
		truncated := accept
		if len(truncated) > 24 {
			truncated = truncated[:24]
		}
		add("浏览器", "HTTP 语言首标", 1, 0,
			truncated+" vs "+cc,
			fmt.Sprintf("请求头 Accept-Language: %s 与出口 %s 矛盾，服务端第一眼就能看到", accept, cc),
			"浏览器设置里把首选语言调成 English (United States)")
		return
	}

	truncated := accept
	if len(truncated) > 24 {
		truncated = truncated[:24]
	}
	add("浏览器", "HTTP 语言首标", 1, 100, truncated, "", "")
}

// extractPrimaryLang returns the base language tag from the first entry
// of a comma-separated language list (e.g. "en-US,en;q=0.9" → "en").
func extractPrimaryLang(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	// Take first entry before comma
	if idx := strings.Index(s, ","); idx >= 0 {
		s = s[:idx]
	}
	// Remove quality weight
	if idx := strings.Index(s, ";"); idx >= 0 {
		s = s[:idx]
	}
	s = strings.TrimSpace(s)
	// Extract base language (before hyphen)
	if idx := strings.Index(s, "-"); idx >= 0 {
		s = s[:idx]
	}
	return strings.ToLower(s)
}

func evalRenderEnv(f *Facts, add addFn) {
	if f.BrWebGL == "" {
		add("浏览器", "渲染环境", 2, 50, "未取到 GPU 信息", "", "")
	} else {
		val := f.BrWebGL
		if f.BrFonts != "" {
			fontCount := len(strings.Split(f.BrFonts, ","))
			val = fmt.Sprintf("%s · %d 中文字体", val, fontCount)
		}
		add("浏览器", "渲染环境", 2, 100, val, "", "")
	}
}

// ── Grade Determination ──

func determineGrade(f *Facts, r *Report, cc string) {
	score := r.Score

	// Hard block 1: Unsupported region
	if UnsupportedCC[cc] {
		r.Grade = GradeHighRisk
		r.RiskLevel = RiskHigh
		r.Verdict = RegionNote(cc)
		r.SafeUse = false
		return
	}

	// Hard block 2: Three-way inconsistency
	if !f.Consistent {
		r.Grade = GradeRisk
		r.RiskLevel = RiskHigh
		ipInfo := ""
		if f.CnIP != "" && f.IntlIP != "" {
			ipInfo = fmt.Sprintf("(%s / %s)", f.CnIP, f.IntlIP)
		}
		r.Verdict = fmt.Sprintf("出口分流%s，画像跳变，不建议使用", ipInfo)
		r.SafeUse = false
		return
	}

	// Critical veto check
	hasCritFail := len(r.CritFails) > 0

	if hasCritFail {
		critNames := strings.Join(r.CritFails, "、")
		switch {
		case score >= 70:
			r.Grade = GradeRisky
		case score >= 50:
			r.Grade = GradeHighRisk
		default:
			r.Grade = GradeDanger
		}
		r.RiskLevel = RiskHigh
		r.Verdict = fmt.Sprintf("关键项未达标（%s），不建议使用", critNames)
		r.SafeUse = false
		return
	}

	// Normal grading
	switch {
	case score >= 90:
		r.Grade = GradeExcellent
		r.RiskLevel = RiskSafe
		r.Verdict = "环境适合运行 Claude"
		r.SafeUse = true
	case score >= 70:
		r.Grade = GradeRisky
		r.RiskLevel = RiskMedium
		r.Verdict = "有矛盾信号，先按提示修复"
		r.SafeUse = false
	case score >= 50:
		r.Grade = GradeHighRisk
		r.RiskLevel = RiskHigh
		r.Verdict = "多项信号冲突，不建议登录"
		r.SafeUse = false
	default:
		r.Grade = GradeDanger
		r.RiskLevel = RiskCrit
		r.Verdict = "画像严重冲突，封号风险高"
		r.SafeUse = false
	}
}
