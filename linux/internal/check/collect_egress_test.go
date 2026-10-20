package check

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

type egressTransport func(*http.Request) (*http.Response, error)

func (fn egressTransport) RoundTrip(r *http.Request) (*http.Response, error) { return fn(r) }

func TestExtractBothIPFamilies(t *testing.T) {
	for input, want := range map[string]string{
		" 203.0.113.8\n":                         "203.0.113.8",
		"2001:0db8:0:0:0:0:0:8\n":                "2001:db8::8",
		`{"ip":"2001:db8::8"}`:                   "2001:db8::8",
		`{"ip":"invalid","other":"203.0.113.8"}`: "",
		`IPCallBack({"ip":"203.0.113.8"})`:       "203.0.113.8",
		"::ffff:203.0.113.8":                     "203.0.113.8",
		"not an address":                         "",
		"999.999.999.999":                        "",
	} {
		if got := extractIP(input); got != want {
			t.Errorf("extractIP(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestThreeWayCollectorIPv6Fallback(t *testing.T) {
	client := &http.Client{Transport: egressTransport(func(r *http.Request) (*http.Response, error) {
		body := "error page mentions 203.0.113.99"
		code := http.StatusForbidden
		switch r.URL.Host {
		case "whois.pconline.com.cn":
			body, code = `{"ip":"2001:db8::8"}`, http.StatusOK
		case "icanhazip.com":
			body, code = "2001:0db8:0:0:0:0:0:8\n", http.StatusOK
		case "cloudflare.com":
			body, code = "ip=2001:db8::8\ncolo=LAX\n", http.StatusOK
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	f := &Facts{}
	CollectThreeWayIPs(context.Background(), client, f)
	if !f.Consistent || f.CnIP != "2001:db8::8" || f.IntlIP != f.CnIP || f.GfwIP != f.CnIP {
		t.Fatalf("IPv6 fallbacks not collected/normalized, or failed responses used: %+v", f)
	}
}

func TestThreeWayCollectorMixedFamilies(t *testing.T) {
	client := &http.Client{Transport: egressTransport(func(r *http.Request) (*http.Response, error) {
		body := "203.0.113.8"
		if r.URL.Host == "cloudflare.com" {
			body = "ip=2001:db8::8\n"
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	f := &Facts{Consistent: true}
	CollectThreeWayIPs(context.Background(), client, f)
	if f.Consistent || threeWayState(f) != egressMixed {
		t.Fatalf("mixed family misclassified: %+v", f)
	}
}
