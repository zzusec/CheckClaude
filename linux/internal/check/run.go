// Package check: run.go orchestrates the full collection pipeline.
package check

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Version is the CheckClaude release version.
const Version = "4.18"

// CollectAll runs every collector and returns the populated Facts.
// Local probes run first (cheap), then the exit IP is resolved, then all
// network probes that depend on the exit IP run in parallel.
func CollectAll(ctx context.Context) *Facts {
	f := &Facts{ClaudeVer: Version}
	client := &http.Client{Timeout: 12 * time.Second}

	// Local system state.
	CollectTimezone(f)
	CollectLocale(f)
	CollectDNS(f)
	CollectProxyMode(f)
	CollectVirtualization(f)
	CollectRelay(f)
	CollectBrowser(f)

	// Exit IP must be known before intel lookups.
	CollectThreeWayIPs(ctx, client, f)

	var wg sync.WaitGroup
	for _, fn := range []func(){
		func() { CollectIPIntel(ctx, client, f) },
		func() { CollectCloudflare(ctx, client, f) },
		func() { CollectServiceReachability(ctx, client, f) },
		func() { CollectIPv6(ctx, client, f) },
		func() { CollectDNSVerdict(f) },
	} {
		wg.Add(1)
		go func(fn func()) { defer wg.Done(); fn() }(fn)
	}
	wg.Wait()

	RecordIP(f.ProbeIP)
	CollectStability(f)

	return f
}

// Check runs the full pipeline and scores it.
func Check(ctx context.Context) (*Facts, *Report) {
	f := CollectAll(ctx)
	return f, Evaluate(f)
}

// RecordIP appends the current exit IP to the 24h history file, marking the
// line as a confirmed change when it differs from the previous entry.
// ponytail: a single differing sample counts as confirmed; add a two-sample
// quorum if flapping proxies turn out to inflate the change count.
func RecordIP(ip string) {
	if ip == "" {
		return
	}
	dir := DataDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	path := filepath.Join(dir, "network_history")

	last := ""
	if data, err := os.ReadFile(path); err == nil {
		lines := strings.Split(strings.TrimSpace(string(data)), "\n")
		for i := len(lines) - 1; i >= 0; i-- {
			if fields := strings.Fields(lines[i]); len(fields) >= 2 {
				last = fields[1]
				break
			}
		}
		// Keep the file bounded: retain the most recent 500 lines.
		if len(lines) > 500 {
			_ = os.WriteFile(path, []byte(strings.Join(lines[len(lines)-500:], "\n")+"\n"), 0o644)
		}
	}

	changed := "0"
	if last != "" && last != ip {
		changed = "1"
	}
	line := time.Now().Format("2006-01-02T15:04:05") + " " + ip + " changed=" + changed + "\n"

	fh, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer fh.Close()
	_, _ = fh.WriteString(line)
}
