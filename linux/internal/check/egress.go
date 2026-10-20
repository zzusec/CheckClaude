package check

import (
	"fmt"
	"net/netip"
	"strings"
)

type egressState string

const (
	egressConsistent egressState = "consistent"
	egressDifferent  egressState = "different"
	egressMixed      egressState = "mixed-family"
	egressIncomplete egressState = "incomplete"
)

func observedIP(raw string) (netip.Addr, bool) {
	ip, err := netip.ParseAddr(strings.TrimSpace(raw))
	if err != nil || ip.Zone() != "" {
		return netip.Addr{}, false
	}
	return ip.Unmap(), true
}

// Compare addresses within each family. A v4/v6 pair alone cannot establish
// either a common egress or split routing, even when both geolocate alike.
func threeWayState(f *Facts) egressState {
	var v4, v6 netip.Addr
	missing := false
	for _, raw := range []string{f.CnIP, f.IntlIP, f.GfwIP} {
		ip, ok := observedIP(raw)
		if !ok {
			missing = true
			continue
		}
		previous := &v6
		if ip.Is4() {
			previous = &v4
		}
		if previous.IsValid() && *previous != ip {
			return egressDifferent
		}
		*previous = ip
	}
	if missing {
		return egressIncomplete
	}
	if v4.IsValid() && v6.IsValid() {
		return egressMixed
	}
	return egressConsistent
}

func threeWaySummary(f *Facts) string {
	show := func(raw string) string {
		if ip, ok := observedIP(raw); ok {
			return ip.String()
		}
		return "未获取"
	}
	return fmt.Sprintf("CN=%s / INTL=%s / GFW=%s", show(f.CnIP), show(f.IntlIP), show(f.GfwIP))
}
