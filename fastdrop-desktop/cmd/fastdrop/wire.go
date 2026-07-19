package main

import (
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"

	"fastdrop-desktop/internal/config"
)

// loadOrInitConfig loads or bootstraps the on-disk config file.
func loadOrInitConfig(path string) (*config.Config, error) {
	if path != "" {
		// Override the default path.
		_ = os.Setenv("APPDATA", filepath.Dir(path))
	}
	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	return cfg, nil
}

// resolveBindAddress picks the LAN IP if cfg.Server.BindAddress == "auto",
// else returns the configured address and port.
func resolveBindAddress(cfg *config.Config) (string, int) {
	if cfg.Server.BindAddress == "" || cfg.Server.BindAddress == "auto" {
		if ip := preferLANIPv4(); ip != "" {
			return ip, cfg.Server.Port
		}
		return "127.0.0.1", cfg.Server.Port
	}
	return cfg.Server.BindAddress, cfg.Server.Port
}

// lanIPAddresses enumerates active NIC IPv4 addresses, excluding loopback
// and well-known virtual adapters (spec §27).
func lanIPAddresses() []string {
	out := []string{}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return out
	}
	ifaces, _ := net.Interfaces()
	virtualByMac := map[string]bool{}
	for _, ifc := range ifaces {
		n := strings.ToLower(ifc.Name)
		if containsAny(n, []string{"wsl", "docker", "virtualbox", "vmware", "tap-", "tunnel", "vpn", "hyper-v", "vethernet"}) {
			virtualByMac[ifc.HardwareAddr.String()] = true
		}
	}
	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ip4 := ipnet.IP.To4(); ip4 != nil && isPrivate(ip4) {
				out = append(out, ip4.String())
			}
		}
	}
	return out
}

// preferLANIPv4 picks the first private LAN IPv4.
func preferLANIPv4() string {
	for _, ip := range lanIPAddresses() {
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

func containsAny(s string, keys []string) bool {
	for _, k := range keys {
		if strings.Contains(s, k) {
			return true
		}
	}
	return false
}

// init ensures the log format is sensible by default.
func init() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
}
