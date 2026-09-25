package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

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
		// A corrupted config.json must not brick the app: quarantine the
		// broken file and start over with defaults (spec §29 resilience).
		if qErr := quarantineCorruptConfig(); qErr != nil {
			return nil, fmt.Errorf("config: %v (quarantine failed: %v)", err, qErr)
		}
		log.Printf("[config] config.json unreadable (%v); backed up as config.json.corrupt-* and regenerated with defaults", err)
		cfg, err = config.Load()
		if err != nil {
			return nil, fmt.Errorf("config: %w", err)
		}
	}
	return cfg, nil
}

// quarantineCorruptConfig renames the current config.json aside so the next
// Load bootstraps a fresh default one. Returns an error when there is no
// config file to quarantine (nothing was corrupted).
func quarantineCorruptConfig() error {
	src := config.ConfigPath()
	if _, err := os.Stat(src); err != nil {
		return err
	}
	dst := fmt.Sprintf("%s.corrupt-%d", src, time.Now().Unix())
	return os.Rename(src, dst)
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
