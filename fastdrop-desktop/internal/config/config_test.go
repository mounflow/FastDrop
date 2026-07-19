package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefaultValues(t *testing.T) {
	cfg := Default()
	if cfg.Server.Port != DefaultPort {
		t.Errorf("port = %d, want %d", cfg.Server.Port, DefaultPort)
	}
	if cfg.Transfer.ChunkSize != 4*1024*1024 {
		t.Errorf("chunk = %d, want 4MB", cfg.Transfer.ChunkSize)
	}
	if cfg.Security.SessionTTLSeconds != 12*60*60 {
		t.Errorf("session ttl = %d, want 12h", cfg.Security.SessionTTLSeconds)
	}
	if cfg.Security.PairTokenTTLSeconds != 60 {
		t.Errorf("pair ttl = %d, want 60", cfg.Security.PairTokenTTLSeconds)
	}
	if cfg.Transfer.MaxConcurrentChunks != 3 || cfg.Transfer.MaxConcurrentFiles != 2 || cfg.Transfer.MaxGlobalHTTP != 6 {
		t.Errorf("concurrency = %d/%d/%d, want 3/2/6", cfg.Transfer.MaxConcurrentChunks, cfg.Transfer.MaxConcurrentFiles, cfg.Transfer.MaxGlobalHTTP)
	}
}

func TestLoadMissingFile(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Server.Port != DefaultPort {
		t.Errorf("port = %d", cfg.Server.Port)
	}
}

func TestLoadUserOverride(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("APPDATA", dir)

	user := map[string]any{
		"server":   map[string]any{"port": 9999, "deviceName": "My-PC"},
		"transfer": map[string]any{"chunkSize": 1024},
	}
	data, _ := json.Marshal(user)
	cfgDir := filepath.Join(dir, "FastDrop")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "config.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Server.Port != 9999 {
		t.Errorf("port = %d, want 9999", cfg.Server.Port)
	}
	if cfg.Server.DeviceName != "My-PC" {
		t.Errorf("deviceName = %q", cfg.Server.DeviceName)
	}
	if cfg.Transfer.ChunkSize != 1024 {
		t.Errorf("chunk = %d", cfg.Transfer.ChunkSize)
	}
	// Untouched field should retain default.
	if cfg.Security.PairTokenTTLSeconds != 60 {
		t.Errorf("pair ttl defaulted wrong: %d", cfg.Security.PairTokenTTLSeconds)
	}
}

func TestNormalizeBadPort(t *testing.T) {
	cfg := Default()
	cfg.Server.Port = 0
	cfg.normalize()
	if cfg.Server.Port != DefaultPort {
		t.Errorf("normalize did not reset port")
	}
}

func TestSaveRoundTrip(t *testing.T) {
	t.Setenv("APPDATA", t.TempDir())
	cfg := Default()
	cfg.Server.DeviceName = "Save-Test"
	if err := Save(cfg); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Server.DeviceName != "Save-Test" {
		t.Errorf("save/load mismatch: %q", loaded.Server.DeviceName)
	}
	// File must be inside the FastDrop appdata dir.
	if !strings.HasPrefix(ConfigPath(), AppDataDir()) {
		t.Errorf("config path outside appdata: %s", ConfigPath())
	}
}
