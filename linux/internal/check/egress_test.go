package check

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestThreeWayAddressFamilies(t *testing.T) {
	cases := []struct {
		name, cn, intl, gfw string
		want                egressState
	}{
		{"IPv4 equal", "203.0.113.8", "203.0.113.8", "203.0.113.8", egressConsistent},
		{"IPv6 spelling", "2001:db8::8", "2001:0db8:0:0:0:0:0:8", "2001:db8::8", egressConsistent},
		{"mapped IPv4", "203.0.113.8", "::ffff:203.0.113.8", "203.0.113.8", egressConsistent},
		{"dual stack", "203.0.113.8", "203.0.113.8", "2001:db8::8", egressMixed},
		{"mixed with IPv4 disagreement", "203.0.113.8", "203.0.113.9", "2001:db8::8", egressDifferent},
		{"mixed with IPv6 disagreement", "203.0.113.8", "2001:db8::8", "2001:db8::9", egressDifferent},
		{"missing", "203.0.113.8", "", "203.0.113.8", egressIncomplete},
		{"invalid", "203.0.113.8", "not an IP", "203.0.113.8", egressIncomplete},
		{"all missing", "", "", "", egressIncomplete},
		{"missing with observed disagreement", "203.0.113.8", "203.0.113.9", "", egressDifferent},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &Facts{CnIP: c.cn, IntlIP: c.intl, GfwIP: c.gfw}
			if got := threeWayState(f); got != c.want {
				t.Fatalf("got %s, want %s", got, c.want)
			}
		})
	}
}

func TestThreeWayInconclusiveIsNeitherLeakNorAllClear(t *testing.T) {
	for _, state := range []egressState{egressMixed, egressIncomplete} {
		t.Run(string(state), func(t *testing.T) {
			f := baselineFacts()
			f.Consistent = false
			if state == egressMixed {
				f.GfwIP = "2001:db8::8"
				f.ProbeIP, f.CfIP, f.BrRTC = f.GfwIP, f.GfwIP, f.GfwIP
			} else {
				f.CnIP = ""
			}
			r := Evaluate(f)
			if r.Consistent || r.SafeUse || r.Grade == GradeExcellent || r.RiskLevel != RiskMedium {
				t.Fatalf("inconclusive comparison must remain a warning: %+v", r)
			}
			if strings.Contains(r.Verdict, "画像跳变") || strings.Contains(r.Verdict, "出口分流") {
				t.Fatalf("unsupported diagnosis: %s", r.Verdict)
			}
			for _, name := range r.CritFails {
				if name == "三路出口一致" {
					t.Fatal("inconclusive samples treated as a confirmed critical failure")
				}
			}
			// Uncertainty must not mask an independent confirmed critical failure.
			f.APICode = 403
			r = Evaluate(f)
			if r.RiskLevel != RiskHigh || !strings.Contains(r.Verdict, "Anthropic API 可达") {
				t.Fatalf("API failure was masked: %+v", r)
			}
		})
	}
}

func TestThreeWaySameFamilyDifferenceStillBlocks(t *testing.T) {
	f := baselineFacts()
	f.CnIP, f.IntlIP, f.GfwIP = "203.0.113.8", "203.0.113.8", "203.0.113.9"
	f.ProbeIP, f.CfIP, f.BrRTC = f.GfwIP, f.GfwIP, f.GfwIP
	// A stale boolean must not hide the sampled addresses.
	f.Consistent = true
	r := Evaluate(f)
	if r.Consistent || r.SafeUse || r.Grade != GradeRisk || r.RiskLevel != RiskHigh {
		t.Fatalf("same-family disagreement must still block: %+v", r)
	}
	for _, label := range []string{"CN=203.0.113.8", "INTL=203.0.113.8", "GFW=203.0.113.9"} {
		if !strings.Contains(r.Verdict, label) {
			t.Errorf("verdict omits actual sample %s: %s", label, r.Verdict)
		}
	}
	if strings.Contains(r.Verdict, "画像跳变") {
		t.Fatalf("address difference does not prove geographic movement: %s", r.Verdict)
	}
}

func TestLinkComparisonAcrossFamilies(t *testing.T) {
	f := baselineFacts()
	f.CfIP = "2001:db8::8"
	r := Evaluate(f)
	for _, s := range r.Signals {
		if s.Label == "出口链路单一" {
			if s.Points == 0 || s.Points == s.Weight || strings.Contains(s.Issue, "链路上还有一层代理") {
				t.Fatalf("v4/v6 pair should be inconclusive: %+v", s)
			}
			return
		}
	}
	t.Fatal("missing link signal")
}

func TestInconclusiveComparisonDoesNotLowerOtherRisks(t *testing.T) {
	f := baselineFacts()
	f.GfwIP = "2001:db8::8"
	r := &Report{Score: 40}
	determineGrade(f, r, "US")
	if r.Grade != GradeDanger || r.RiskLevel != RiskCrit {
		t.Fatalf("inconclusive route must not reduce an independently low score: %+v", r)
	}
}

func TestThreeWayJSONIncludesEverySample(t *testing.T) {
	f := baselineFacts()
	f.GfwIP = "2001:db8::8"
	data, err := JSON(f, Evaluate(f))
	if err != nil {
		t.Fatal(err)
	}
	var report struct {
		Consistent bool                   `json:"consistent"`
		Details    map[string]interface{} `json:"details"`
	}
	if err := json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	if report.Consistent {
		t.Fatal("mixed-family result reported as consistent")
	}
	for k, want := range map[string]string{"cnIP": f.CnIP, "intlIP": f.IntlIP, "gfwIP": f.GfwIP, "threeWayStatus": "mixed-family"} {
		if report.Details[k] != want {
			t.Errorf("%s = %v, want %s", k, report.Details[k], want)
		}
	}
}
