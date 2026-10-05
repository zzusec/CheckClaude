package check

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func regressionSignal(t *testing.T, r *Report, label string) Signal {
	t.Helper()
	for _, s := range r.Signals {
		if s.Label == label {
			return s
		}
	}
	t.Fatalf("missing signal %s", label)
	return Signal{}
}

func TestBrowserIntlLanguageTags(t *testing.T) {
	for _, tc := range []struct {
		locale, country string
		points          int
	}{
		{"de", "DE", 1},
		{"en", "US", 1},
		{"zh-Hant", "TW", 1},
		{"de-DE-u-ca-gregory", "DE", 1},
		{"de-de", "DE", 1},
		{"de-u-ca-gregory", "DE", 1},
		{"en-US-x-de", "DE", 0},
		{"en-x-de", "DE", 1},
		{"x-de", "US", 1},
		{"es-419", "US", 1},
		{"de-AT", "DE", 0},
		{"zh-Hant-TW-u-ca-chinese", "TW", 1},
	} {
		t.Run(tc.locale+"_"+tc.country, func(t *testing.T) {
			f := baselineFacts()
			f.Country, f.BrLocale = tc.country, tc.locale
			s := regressionSignal(t, Evaluate(f), "Intl 区域设置")
			if s.Points != tc.points {
				t.Errorf("Intl locale %s against %s: points=%d, want %d; issue=%s", tc.locale, tc.country, s.Points, tc.points, s.Issue)
			}
		})
	}
}

func TestThreeWayMissingProbeIsNotSplitRoute(t *testing.T) {
	for _, missing := range []string{"cn", "intl", "gfw", "all"} {
		t.Run(missing, func(t *testing.T) {
			f := baselineFacts()
			f.Consistent = false
			switch missing {
			case "cn":
				f.CnIP = ""
			case "intl":
				f.IntlIP = ""
			case "gfw":
				f.GfwIP = ""
			case "all":
				f.CnIP, f.IntlIP, f.GfwIP = "", "", ""
			}
			r := Evaluate(f)
			s := regressionSignal(t, r, "三路出口一致")
			if s.Points != 3 || strings.Contains(s.Issue, "不一致") || strings.Contains(r.Verdict, "出口分流") {
				t.Errorf("missing probe reported as split route: signal=%+v, verdict=%s", s, r.Verdict)
			}
			if r.SafeUse {
				t.Error("incomplete critical exit evidence must not be reported safe")
			}
		})
	}
}

func TestThreeWayObservedMismatchWithMissingThirdProbe(t *testing.T) {
	f := baselineFacts()
	f.CnIP, f.IntlIP, f.GfwIP = "203.0.113.1", "203.0.113.2", ""
	f.Consistent = false
	r := Evaluate(f)
	if !strings.Contains(r.Verdict, "出口分流") || r.SafeUse {
		t.Fatalf("observed mismatch should still block: %+v", r)
	}
}

func TestIPIntelMissingHostingIsUnknown(t *testing.T) {
	for _, tc := range []struct {
		name, response string
		hosting        int
	}{
		{"failed", `{"status":"fail"}`, -1},
		{"missing", `{"status":"success","countryCode":"US"}`, -1},
		{"residential", `{"status":"success","countryCode":"US","hosting":false}`, 0},
		{"datacenter", `{"status":"success","countryCode":"US","hosting":true}`, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if req.Host == "ip-api.com" {
					fmt.Fprint(w, tc.response)
				} else {
					fmt.Fprint(w, `{}`)
				}
			}))
			defer server.Close()
			endpoint, err := url.Parse(server.URL)
			if err != nil {
				t.Fatal(err)
			}
			client := &http.Client{Transport: reachabilityTestTransport{endpoint: endpoint}}
			f := &Facts{ProbeIP: "203.0.113.10"}
			CollectIPIntel(context.Background(), client, f)
			if f.Hosting != tc.hosting {
				t.Fatalf("Hosting=%d, want %d; ip type=%s", f.Hosting, tc.hosting, ipTypeName(f))
			}
		})
	}
	// Failure to obtain an exit IP must also keep the classification unknown.
	f := &Facts{}
	CollectIPIntel(context.Background(), nil, f)
	if f.Hosting != -1 {
		t.Fatalf("missing exit IP classified as %s", ipTypeName(f))
	}
}

func writeRegressionHistory(t *testing.T, lines []string) string {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	if err := os.MkdirAll(DataDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(DataDir(), "network_history")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestStabilityFreshHistoryDoesNotClaim24Hours(t *testing.T) {
	for _, tc := range []struct {
		name  string
		lines []string
	}{
		{"empty", nil},
		{"invalid", []string{"invalid 203.0.113.1 changed=0"}},
		{"one_sample", []string{time.Now().Format("2006-01-02T15:04:05") + " 203.0.113.1 changed=0"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			writeRegressionHistory(t, tc.lines)
			f := baselineFacts()
			CollectStability(f)
			s := regressionSignal(t, Evaluate(f), "出口稳定性")
			if s.Points != 2 || !strings.Contains(s.Value, "历史不足") {
				t.Errorf("fresh history should be incomplete, got %+v", s)
			}
		})
	}
}

func TestStabilityLegacyTimestampsUseLocalZone(t *testing.T) {
	previous := time.Local
	time.Local = time.FixedZone("legacy-local", 2*60*60)
	t.Cleanup(func() { time.Local = previous })
	now := time.Now()
	writeRegressionHistory(t, []string{
		now.Add(-25*time.Hour-30*time.Minute).Format("2006-01-02T15:04:05") + " 203.0.113.1 changed=0",
		now.Add(-24*time.Hour-30*time.Minute).Format("2006-01-02T15:04:05") + " 203.0.113.2 changed=1",
		now.Add(-time.Hour).Format("2006-01-02T15:04:05") + " 203.0.113.2 changed=0",
	})
	f := &Facts{}
	CollectStability(f)
	if f.IPChanges != 0 {
		t.Fatalf("out-of-window legacy change counted: %d", f.IPChanges)
	}
}

func TestStabilityCountsFirstChangeInsideWindow(t *testing.T) {
	previous := time.Local
	time.Local = time.UTC
	t.Cleanup(func() { time.Local = previous })
	now := time.Now()
	writeRegressionHistory(t, []string{
		now.Add(-25*time.Hour).Format("2006-01-02T15:04:05") + " 203.0.113.1 changed=0",
		now.Add(-23*time.Hour).Format("2006-01-02T15:04:05") + " 203.0.113.2 changed=1",
		now.Add(-time.Hour).Format("2006-01-02T15:04:05") + " 203.0.113.2 changed=0",
	})
	f := &Facts{}
	CollectStability(f)
	if f.IPChanges != 1 {
		t.Fatalf("first confirmed change in window lost: %d", f.IPChanges)
	}
}

func TestRecordIPUsesTimestampWithOffset(t *testing.T) {
	path := writeRegressionHistory(t, nil)
	RecordIP("203.0.113.1")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	fields := strings.Fields(string(data))
	if len(fields) < 3 {
		t.Fatalf("invalid recorded line: %s", data)
	}
	if _, err := time.Parse(time.RFC3339, fields[0]); err != nil {
		t.Fatalf("timestamp must preserve UTC offset: %s", fields[0])
	}
}

func TestRecordIPRetains24HourWindow(t *testing.T) {
	now := time.Now()
	var lines []string
	for i := 1500; i >= 0; i-- {
		lines = append(lines, now.Add(-time.Duration(i)*time.Minute).Format("2006-01-02T15:04:05")+" 203.0.113.1 changed=0")
	}
	path := writeRegressionHistory(t, lines)
	RecordIP("203.0.113.1")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(strings.Split(strings.TrimSpace(string(data)), "\n")); n < 1441 {
		t.Fatalf("minute samples do not cover 24 hours after pruning: %d entries", n)
	}
}

func TestStabilityRequiresRecentContinuousCoverage(t *testing.T) {
	for _, tc := range []struct {
		name     string
		omit     int
		complete bool
	}{
		{"minute_samples", -1, true},
		{"gap_over_two_minutes", 720, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			var lines []string
			for i := 1441; i >= 0; i-- {
				if tc.omit >= 0 && i >= tc.omit && i <= tc.omit+1 {
					continue
				}
				lines = append(lines, now.Add(-time.Duration(i)*time.Minute).Format(time.RFC3339)+" 203.0.113.1 changed=0")
			}
			writeRegressionHistory(t, lines)
			f := &Facts{}
			CollectStability(f)
			if f.IPHistoryComplete != tc.complete {
				t.Fatalf("history completeness=%v, want %v", f.IPHistoryComplete, tc.complete)
			}
		})
	}
}

func TestStabilityIgnoresFutureHistory(t *testing.T) {
	now := time.Now()
	writeRegressionHistory(t, []string{
		now.Add(-time.Hour).Format(time.RFC3339) + " 203.0.113.1 changed=0",
		now.Add(time.Hour).Format(time.RFC3339) + " 203.0.113.2 changed=1",
	})
	f := &Facts{}
	CollectStability(f)
	if f.IPChanges != 0 || f.IPHistoryComplete {
		t.Fatalf("future sample changed the result: changes=%d, complete=%v", f.IPChanges, f.IPHistoryComplete)
	}
}

func TestWebRTCJSONMatchesMixedCandidateVerdict(t *testing.T) {
	f := baselineFacts()
	f.BrRTC = f.ProbeIP + ",203.0.113.2"
	r := Evaluate(f)
	if s := regressionSignal(t, r, "WebRTC 出口"); s.Points != 0 {
		t.Fatalf("expected leak signal, got %+v", s)
	}
	data, err := JSON(f, r)
	if err != nil {
		t.Fatal(err)
	}
	var out jsonOut
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	if out.Details.WebRTCStatus != "泄漏" {
		t.Fatalf("JSON contradicts leak signal: %s", out.Details.WebRTCStatus)
	}
}
