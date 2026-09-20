// Package check: fix.go implements safe, reversible auto-repair for Linux.
package check

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// FixResult describes the outcome of a fix attempt.
type FixResult struct {
	Label   string
	Success bool
	Message string
}

// Fix executes all safe auto-repairs based on the report.
// It returns a list of results and a list of manual steps.
func Fix(r *Report, f *Facts) (results []FixResult, manual []string) {
	// 1. Timezone fix
	if r.FixableTZ != "" {
		res := fixTimezone(r.FixableTZ)
		results = append(results, res)
	}

	// 2. PAC fix (GNOME only)
	if r.FixablePAC {
		res := fixPAC()
		results = append(results, res)
	}

	// 3. Locale fix (only with explicit opt-in via fixLocale flag)
	// Note: locale fix is separate because it affects date/number display.
	// It is only triggered by --fix-locale, not --fix.

	// Collect manual steps from signals
	for _, s := range r.Signals {
		if s.Fix != "" && s.Points < s.Weight {
			manual = append(manual, fmt.Sprintf("• %s: %s", s.Label, s.Fix))
		}
	}

	return results, manual
}

// FixLocale writes locale environment overrides for the current user.
// Only modifies LC_TIME/LC_NUMERIC/etc., never LANG or display language.
func FixLocale(targetCC string) FixResult {
	if targetCC == "" {
		return FixResult{Label: "系统区域", Success: false, Message: "目标区域为空"}
	}

	// Check if target locale is installed
	targetLocale := findInstalledLocale(targetCC)
	if targetLocale == "" {
		return FixResult{
			Label:   "系统区域",
			Success: false,
			Message: fmt.Sprintf("目标区域 %s 的 locale 未安装，请先运行: sudo locale-gen %s", targetCC, guessLocale(targetCC)),
		}
	}

	// Write to ~/.config/environment.d/90-checkclaude-locale.conf
	confDir := filepath.Join(os.Getenv("HOME"), ".config", "environment.d")
	if err := os.MkdirAll(confDir, 0755); err != nil {
		return FixResult{Label: "系统区域", Success: false, Message: err.Error()}
	}

	confFile := filepath.Join(confDir, "90-checkclaude-locale.conf")
	backupFile := confFile + ".bak"

	// Backup existing
	if data, err := os.ReadFile(confFile); err == nil {
		_ = os.WriteFile(backupFile, data, 0644)
	}

	// Write locale override (only format-related LC_ vars, not LANG)
	content := fmt.Sprintf(`# Written by CheckClaude --fix-locale
# Backup: %s
LC_TIME=%s
LC_NUMERIC=%s
LC_MONETARY=%s
LC_PAPER=%s
LC_MEASUREMENT=%s
`, backupFile, targetLocale, targetLocale, targetLocale, targetLocale, targetLocale)

	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		return FixResult{Label: "系统区域", Success: false, Message: err.Error()}
	}

	return FixResult{
		Label:   "系统区域",
		Success: true,
		Message: fmt.Sprintf("已写入 %s，重新登录桌面会话生效", confFile),
	}
}

// ── Internal fix functions ──

func fixTimezone(target string) FixResult {
	// Validate timezone
	if _, err := os.Stat(filepath.Join("/usr/share/zoneinfo", target)); err != nil {
		return FixResult{
			Label:   "系统时区",
			Success: false,
			Message: fmt.Sprintf("无效时区: %s", target),
		}
	}

	// Try timedatectl first (works with polkit)
	cmd := exec.Command("timedatectl", "set-timezone", target)
	if err := cmd.Run(); err != nil {
		// Try pkexec
		cmd = exec.Command("pkexec", "timedatectl", "set-timezone", target)
		if err := cmd.Run(); err != nil {
			return FixResult{
				Label:   "系统时区",
				Success: false,
				Message: fmt.Sprintf("无法修改时区，请手动执行: sudo timedatectl set-timezone %s", target),
			}
		}
	}

	return FixResult{
		Label:   "系统时区",
		Success: true,
		Message: fmt.Sprintf("已将系统时区设置为 %s", target),
	}
}

func fixPAC() FixResult {
	// Only fix GNOME PAC
	out, err := exec.Command("gsettings", "get", "org.gnome.system.proxy", "mode").Output()
	if err != nil {
		return FixResult{
			Label:   "PAC 分流",
			Success: false,
			Message: "无法读取 GNOME 代理设置",
		}
	}

	mode := strings.Trim(strings.TrimSpace(string(out)), "'\"")
	if mode != "auto" {
		return FixResult{
			Label:   "PAC 分流",
			Success: true,
			Message: "PAC 未启用，无需修复",
		}
	}

	if err := exec.Command("gsettings", "set", "org.gnome.system.proxy", "mode", "'none'").Run(); err != nil {
		return FixResult{
			Label:   "PAC 分流",
			Success: false,
			Message: "无法关闭 PAC，请手动在系统设置中关闭自动代理",
		}
	}

	return FixResult{
		Label:   "PAC 分流",
		Success: true,
		Message: "已关闭 GNOME 自动代理(PAC)",
	}
}

// findInstalledLocale checks if a locale matching the target CC is installed.
func findInstalledLocale(cc string) string {
	out, err := exec.Command("locale", "-a").Output()
	if err != nil {
		return ""
	}

	cc = strings.ToLower(cc)
	target := "_" + cc

	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		lower := strings.ToLower(line)
		if strings.Contains(lower, target) && strings.Contains(lower, "utf") {
			return line
		}
	}
	return ""
}

// guessLocale returns a reasonable locale name for a country code.
func guessLocale(cc string) string {
	m := map[string]string{
		"US": "en_US.UTF-8", "GB": "en_GB.UTF-8", "CA": "en_CA.UTF-8",
		"AU": "en_AU.UTF-8", "NZ": "en_NZ.UTF-8", "IE": "en_IE.UTF-8",
		"DE": "de_DE.UTF-8", "FR": "fr_FR.UTF-8", "ES": "es_ES.UTF-8",
		"IT": "it_IT.UTF-8", "PT": "pt_PT.UTF-8", "NL": "nl_NL.UTF-8",
		"SE": "sv_SE.UTF-8", "NO": "nb_NO.UTF-8", "DK": "da_DK.UTF-8",
		"FI": "fi_FI.UTF-8", "PL": "pl_PL.UTF-8", "CZ": "cs_CZ.UTF-8",
		"AT": "de_AT.UTF-8", "CH": "de_CH.UTF-8", "BE": "fr_BE.UTF-8",
		"JP": "ja_JP.UTF-8", "KR": "ko_KR.UTF-8", "SG": "en_SG.UTF-8",
		"TW": "zh_TW.UTF-8", "IL": "he_IL.UTF-8", "AE": "ar_AE.UTF-8",
		"MX": "es_MX.UTF-8", "BR": "pt_BR.UTF-8", "IN": "en_IN.UTF-8",
		"TH": "th_TH.UTF-8", "MY": "ms_MY.UTF-8", "ID": "id_ID.UTF-8",
		"VN": "vi_VN.UTF-8", "ZA": "en_ZA.UTF-8", "TR": "tr_TR.UTF-8",
		"SA": "ar_SA.UTF-8", "AR": "es_AR.UTF-8", "CL": "es_CL.UTF-8",
	}
	if v, ok := m[strings.ToUpper(cc)]; ok {
		return v
	}
	return fmt.Sprintf("en_%s.UTF-8", strings.ToUpper(cc))
}
