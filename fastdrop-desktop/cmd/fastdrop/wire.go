package main

import (
	"log"
	"os"
	"path/filepath"

	"fastdrop-desktop/internal/config"
	"fastdrop-desktop/internal/netutil"
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
		if ip := netutil.PreferLANIPv4(); ip != "" {
			return ip, cfg.Server.Port
		}
		return "127.0.0.1", cfg.Server.Port
	}
	return cfg.Server.BindAddress, cfg.Server.Port
}

// lanIPAddresses is a thin wrapper for the startup log.
func lanIPAddresses() []string { return netutil.LANIPv4Addresses() }

// init ensures the log format is sensible by default.
func init() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
}
