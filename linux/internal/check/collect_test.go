package check

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

type reachabilityTestTransport struct {
	endpoint *url.URL
}

func (tr reachabilityTestTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	clone := req.Clone(req.Context())
	u := *req.URL
	u.Scheme, u.Host = tr.endpoint.Scheme, tr.endpoint.Host
	clone.URL = &u
	clone.Host = req.URL.Host
	return http.DefaultTransport.RoundTrip(clone)
}

func TestServiceReachabilityUsesUnauthenticatedPOSTForMessages(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch req.Host {
		case "api.anthropic.com":
			if req.Method != http.MethodPost || req.URL.Path != "/v1/messages" {
				w.WriteHeader(http.StatusMethodNotAllowed)
				return
			}
			body, err := io.ReadAll(req.Body)
			if err != nil || string(body) != "{}" {
				t.Errorf("Messages probe body = %q, error = %v; want {}", body, err)
			}
			if req.Header.Get("Content-Type") != "application/json" || req.Header.Get("anthropic-version") != "2023-06-01" {
				t.Error("Messages probe is missing JSON or Anthropic version headers")
			}
			if req.Header.Get("x-api-key") != "" || req.Header.Get("Authorization") != "" {
				t.Error("Environment probe must not send account credentials")
			}
			w.WriteHeader(http.StatusUnauthorized)
		case "claude.ai", "www.anthropic.com":
			if req.Method != http.MethodGet || req.URL.Path != "/robots.txt" {
				t.Errorf("Website probe = %s %s; want GET /robots.txt", req.Method, req.URL.Path)
			}
			w.WriteHeader(http.StatusOK)
		default:
			t.Errorf("Unexpected probe host %s", req.Host)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	endpoint, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: reachabilityTestTransport{endpoint: endpoint}}
	f := &Facts{}
	CollectServiceReachability(context.Background(), client, f)
	if f.APICode != http.StatusUnauthorized || f.WebCode != http.StatusOK || f.SiteCode != http.StatusOK {
		t.Fatalf("Collected statuses API/web/site = %d/%d/%d; want 401/200/200", f.APICode, f.WebCode, f.SiteCode)
	}
}
