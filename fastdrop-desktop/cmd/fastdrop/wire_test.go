package main

import (
	"os"
	"path/filepath"
	"testing"

	"fastdrop-desktop/internal/config"
)

// A corrupted config.json must be quarantined as config.json.corrupt-<ts>
// and startup continues with a fresh default config — no Fatalf.
func TestLoadOrInitConfigQuarantinesCorruptFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("APPDATA", dir)
	cfgDir := filepath.Join(dir, "FastDrop")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte("{ this is not json"), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadOrInitConfig("")
	if err != nil {
		t.Fatalf("loadOrInitConfig: %v", err)
	}
	if cfg == nil || cfg.Server.Port != config.DefaultPort {
		t.Fatalf("expected default config, got %+v", cfg)
	}

	matches, err := filepath.Glob(filepath.Join(cfgDir, "config.json.corrupt-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 1 {
		t.Fatalf("corrupt backup not created (matches=%v)", matches)
	}
	if _, err := os.Stat(filepath.Join(cfgDir, "config.json")); err != nil {
		t.Fatalf("config.json not regenerated: %v", err)
	}
}

// A healthy config must load untouched — no quarantine copy appears.
func TestLoadOrInitConfigHealthyFileUntouched(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("APPDATA", dir)

	if _, err := loadOrInitConfig(""); err != nil {
		t.Fatalf("loadOrInitConfig: %v", err)
	}
	matches, err := filepath.Glob(filepath.Join(dir, "FastDrop", "config.json.corrupt-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatalf("unexpected quarantine copies: %v", matches)
	}
}
