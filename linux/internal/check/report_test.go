package check

import (
	"strings"
	"testing"
)

// The tray parses this line by splitting on tabs, so the column count and the
// absence of embedded tabs/newlines are a hard contract.
func TestTrayStatusShape(t *testing.T) {
	r := &Report{
		Score: 83, RiskLevel: RiskMedium, Country: "US",
		Verdict: "关键项未达标\n不建议使用",
		Fixable: []string{"系统时区 → America/Los_Angeles", "关闭\tPAC 分流"},
	}
	line := TrayStatus(r)
	cols := strings.Split(line, "\t")
	if len(cols) != 5 {
		t.Fatalf("want 5 columns, got %d: %q", len(cols), line)
	}
	if strings.Contains(line, "\n") {
		t.Fatalf("tray line must stay single-line: %q", line)
	}
	if cols[0] != "83" || cols[1] != RiskMedium || cols[2] != "US" {
		t.Fatalf("unexpected columns: %q", cols)
	}
}

func TestTrayStatusUnknownCountry(t *testing.T) {
	if cols := strings.Split(TrayStatus(&Report{}), "\t"); cols[2] != "??" {
		t.Fatalf("missing country should render as ??, got %q", cols[2])
	}
}

// A hostile page must not be able to inject extra keys or unbounded values
// into the signals file.
func TestParseSignalsRejectsInjection(t *testing.T) {
	m, _ := parseSignals("tz=Asia/Taipei\nlanguages=zh-TW\nbad line\n=novalue\n" +
		"evil=a\\nsource=spoofed\nlong=" + strings.Repeat("x", 900))
	if m["tz"] != "Asia/Taipei" || m["languages"] != "zh-TW" {
		t.Fatalf("lost good keys: %v", m)
	}
	if _, ok := m[""]; ok {
		t.Fatal("empty key accepted")
	}
	if len(m["long"]) > 512 {
		t.Fatalf("value not truncated: %d", len(m["long"]))
	}
	for k, v := range m {
		if strings.ContainsAny(v, "\n\r") {
			t.Fatalf("newline survived sanitize in %q=%q", k, v)
		}
	}
}

func TestWebRTCStatus(t *testing.T) {
	cases := []struct {
		f    Facts
		want string
	}{
		{Facts{}, "未采集"},
		{Facts{BrOK: true}, "无公网候选"},
		{Facts{BrOK: true, BrRTC: "1.2.3.4", ProbeIP: "1.2.3.4"}, "ok"},
		{Facts{BrOK: true, BrRTC: "9.9.9.9", ProbeIP: "1.2.3.4"}, "泄漏"},
	}
	for _, c := range cases {
		if got := webrtcStatus(&c.f); got != c.want {
			t.Errorf("webrtcStatus(%+v) = %q, want %q", c.f, got, c.want)
		}
	}
}
