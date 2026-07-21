// Package netutil enumerates usable LAN IPv4 addresses, filtering out
// loopback / link-local and known-virtual adapters (WSL, Docker, VPN,
// Hyper-V default switch) per spec §27.
//
// Windows Mobile Hotspot's "vEthernet (LAN Connection* N)" adapter is
// deliberately KEPT: when the phone is tethered off the PC's hotspot,
// it lives in 192.168.137.0/24 and must reach the server via the PC's
// hotspot IP (192.168.137.1).
package netutil

import (
	"net"
	"strings"
)

// LANIPv4Addresses returns active private IPv4 addresses, excluding
// loopback, link-local, and adapters whose names look virtual.
func LANIPv4Addresses() []string {
	out := []string{}
	ifaces, err := net.Interfaces()
	if err != nil {
		return out
	}
	// Sort "real" LAN IPs first (these are more likely to work for both
	// router-tethered and hotspot-tethered phones), then fall back to
	// hotspot/virtual-host adapters.
	primary, fallback := []string{}, []string{}
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 {
			continue
		}
		if ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		virtualKind := classifyAdapter(ifc.Name)
		if virtualKind == "blocked" {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipnet.IP.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
				continue
			}
			if !isPrivate(ip4) {
				continue
			}
			if virtualKind == "hotspot" {
				fallback = append(fallback, ip4.String())
			} else {
				primary = append(primary, ip4.String())
			}
		}
	}
	out = append(out, primary...)
	out = append(out, fallback...)
	return out
}

// PreferLANIPv4 returns the first usable LAN IPv4, or "" if none.
func PreferLANIPv4() string {
	for _, ip := range LANIPv4Addresses() {
		return ip
	}
	return ""
}

func isPrivate(ip net.IP) bool {
	switch {
	case ip[0] == 10:
		return true
	case ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31:
		return true
	case ip[0] == 192 && ip[1] == 168:
		return true
	}
	return false
}

// classifyAdapter returns:
//   - ""        : a real, usable adapter (typical Wi-Fi / Ethernet)
//   - "hotspot" : Windows Mobile Hotspot adapter — usable, but lower priority
//   - "blocked" : WSL / Docker / Hyper-V VM / VPN / VirtualBox — never usable
func classifyAdapter(name string) string {
	n := strings.ToLower(name)
	// Windows Mobile Hotspot uses "vEthernet (LAN Connection* N)" or
	// "vEthernet (Local Area Connection* N)" — keep with lower priority.
	if strings.HasPrefix(n, "vethernet (lan connection*") ||
		strings.HasPrefix(n, "vethernet (local area connection*") {
		return "hotspot"
	}
	for _, key := range []string{
		"wsl", "docker", "virtualbox", "vmware",
		"tap-", "tunnel", "vpn", "hyper-v",
		// Hyper-V default switch + WSL vEthernet variants.
		"vethernet (default switch)",
		"vethernet (ws",
	} {
		if strings.Contains(n, key) {
			return "blocked"
		}
	}
	return ""
}
