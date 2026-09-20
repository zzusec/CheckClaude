// Package check: report.go renders a Report as text, JSON or tray TSV.
package check

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Details mirrors the raw facts exposed in JSON output.
type Details struct {
	IP           string `json:"ip"`
	CountryName  string `json:"countryName"`
	ISP          string `json:"isp"`
	ASN          string `json:"asn"`
	IPType       string `json:"ipType"`
	APICode      int    `json:"apiCode"`
	WebCode      int    `json:"webCode"`
	SiteCode     int    `json:"siteCode"`
	DNSScope     string `json:"dnsScope"`
	DNSResult    string `json:"dnsResult"`
	DNSServers   string `json:"dnsServers"`
	SysTz        string `json:"sysTz"`
	IPTz         string `json:"ipTz"`
	Locale       string `json:"locale"`
	ProxyMode    string `json:"proxyMode"`
	VMHost       string `json:"vmHost"`
	WebRTC       string `json:"webrtc"`
	WebRTCStatus string `json:"webrtcStatus"`
	IPChanges    int    `json:"ipChanges"`
}

type jsonOut struct {
	*Report
	Details Details `json:"details"`
}

func ipTypeName(f *Facts) string {
	switch {
	case f.Proxy:
		return "代理/VPN"
	case f.Hosting == 1:
		return "机房"
	case f.Hosting == 0:
		return "住宅"
	default:
		return "未知"
	}
}

func webrtcStatus(f *Facts) string {
	switch {
	case !f.BrOK:
		return "未采集"
	case f.BrRTC == "":
		return "无公网候选"
	case f.ProbeIP != "" && strings.Contains(f.BrRTC, f.ProbeIP):
		return "ok"
	default:
		return "泄漏"
	}
}

// JSON renders the report as indented JSON.
func JSON(f *Facts, r *Report) ([]byte, error) {
	out := jsonOut{Report: r, Details: Details{
		IP:           f.ProbeIP,
		CountryName:  f.CountryName,
		ISP:          f.ISP,
		ASN:          f.ASN,
		IPType:       ipTypeName(f),
		APICode:      f.APICode,
		WebCode:      f.WebCode,
		SiteCode:     f.SiteCode,
		DNSScope:     f.DNSScope,
		DNSResult:    f.DNSVerdict,
		DNSServers:   f.DNSResult,
		SysTz:        f.SysTimezone,
		IPTz:         f.IPTimezone,
		Locale:       f.SysLocale,
		ProxyMode:    f.ProxyMode,
		VMHost:       f.VMHost,
		WebRTC:       f.BrRTC,
		WebRTCStatus: webrtcStatus(f),
		IPChanges:    f.IPChanges,
	}}
	return json.MarshalIndent(out, "", "  ")
}

// TrayStatus renders the single-line TSV consumed by the tray applet:
// score<TAB>riskLevel<TAB>country<TAB>verdict<TAB>fixList
func TrayStatus(r *Report) string {
	clean := func(s string) string {
		return strings.NewReplacer("\t", " ", "\n", " ").Replace(s)
	}
	country := r.Country
	if country == "" {
		country = "??"
	}
	return strings.Join([]string{
		strconv.Itoa(r.Score),
		clean(r.RiskLevel),
		clean(country),
		clean(r.Verdict),
		clean(strings.Join(r.Fixable, "; ")),
	}, "\t")
}

var groupOrder = []string{"出口", "质量", "画像", "DNS", "稳定", "浏览器"}

// Render returns the human-readable console report.
func Render(f *Facts, r *Report) string {
	var b strings.Builder

	fmt.Fprintf(&b, "CheckClaude v%s — Claude 运行环境体检\n", r.Version)
	b.WriteString(strings.Repeat("─", 56) + "\n")

	loc := f.CountryName
	if loc == "" {
		loc = r.Country
	}
	if f.City != "" {
		loc += " " + f.City
	}
	fmt.Fprintf(&b, "出口 IP   %s  %s\n", orNA(f.ProbeIP), loc)
	fmt.Fprintf(&b, "运营商    %s %s\n", orNA(f.ISP), f.ASN)
	fmt.Fprintf(&b, "代理形态  %s    时区 %s    区域 %s\n",
		orNA(f.ProxyMode), orNA(f.SysTimezone), orNA(f.SysLocale))
	b.WriteString("\n")

	byGroup := map[string][]Signal{}
	for _, s := range r.Signals {
		byGroup[s.Group] = append(byGroup[s.Group], s)
	}
	groups := append([]string{}, groupOrder...)
	for g := range byGroup {
		if !contains(groups, g) {
			groups = append(groups, g)
		}
	}
	sort.SliceStable(groups, func(i, j int) bool {
		return idx(groupOrder, groups[i]) < idx(groupOrder, groups[j])
	})

	for _, g := range groups {
		sigs := byGroup[g]
		if len(sigs) == 0 {
			continue
		}
		got, total := 0, 0
		for _, s := range sigs {
			got += s.Points
			total += s.Weight
		}
		fmt.Fprintf(&b, "【%s】%d/%d\n", g, got, total)
		for _, s := range sigs {
			mark := "✓"
			switch {
			case s.Points == 0:
				mark = "✗"
			case s.Points < s.Weight:
				mark = "!"
			}
			fmt.Fprintf(&b, "  %s %-14s %2d/%-2d  %s\n", mark, s.Label, s.Points, s.Weight, s.Value)
			if s.Issue != "" {
				fmt.Fprintf(&b, "      ↳ %s\n", s.Issue)
			}
			if s.Fix != "" {
				fmt.Fprintf(&b, "      ↳ 建议：%s\n", s.Fix)
			}
		}
		b.WriteString("\n")
	}

	b.WriteString(strings.Repeat("─", 56) + "\n")
	fmt.Fprintf(&b, "总分 %d/100   %s   %s\n", r.Score, r.Grade, r.RiskLevel)
	fmt.Fprintf(&b, "结论 %s\n", r.Verdict)

	if len(r.Fixable) > 0 {
		b.WriteString("\n可自动修复（checkclaude --fix）:\n")
		for _, s := range r.Fixable {
			fmt.Fprintf(&b, "  • %s\n", s)
		}
	}
	if len(r.Manual) > 0 {
		b.WriteString("\n需手动处理:\n")
		for _, s := range r.Manual {
			fmt.Fprintf(&b, "  • %s\n", s)
		}
	}
	if !f.BrOK {
		b.WriteString("\n浏览器项未采集，按中性分计。运行 checkclaude --browser 采集。\n")
	}
	return b.String()
}

func orNA(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

func contains(ss []string, s string) bool {
	for _, v := range ss {
		if v == s {
			return true
		}
	}
	return false
}

func idx(ss []string, s string) int {
	for i, v := range ss {
		if v == s {
			return i
		}
	}
	return len(ss)
}
