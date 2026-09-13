// Package config loads FastDrop runtime configuration.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/google/uuid"
)

// Protocol-scoped constants (do not deviate, see spec §9.1, §5.2, §7.1, §14, §15).
const (
	AppVersion                 = "1.0.0"
	DefaultPort                = 9527
	DefaultChunkSize           = 4 * 1024 * 1024 // 4 MB
	DefaultMaxConcurrentFiles  = 2
	DefaultMaxConcurrentChunks = 3
	DefaultMaxGlobalHTTP       = 6
	DefaultPairTokenTTL        = 60           // seconds
	DefaultSessionTTL          = 12 * 60 * 60 // 12 hours
)

// Config is the top-level config root.
type Config struct {
	Server    ServerConfig    `json:"server"`
	Storage   StorageConfig   `json:"storage"`
	Transfer  TransferConfig  `json:"transfer"`
	Security  SecurityConfig  `json:"security"`
	Discovery DiscoveryConfig `json:"discovery"`
}

type ServerConfig struct {
	Port         int    `json:"port"`
	BindAddress  string `json:"bindAddress"` // "auto" or specific IP
	DeviceID     string `json:"deviceId"`
	DeviceName   string `json:"deviceName"`
	DatabasePath string `json:"databasePath"`
}

type StorageConfig struct {
	DownloadDirectory string `json:"downloadDirectory"`
	ConflictPolicy    string `json:"conflictPolicy"` // "rename" (default) | "overwrite" | "skip"
}

type TransferConfig struct {
	ChunkSize           int `json:"chunkSize"`
	MaxConcurrentFiles  int `json:"maxConcurrentFiles"`
	MaxConcurrentChunks int `json:"maxConcurrentChunks"`
	MaxGlobalHTTP       int `json:"maxGlobalHTTP"`
	MaxChunkRetries     int `json:"maxChunkRetries"`
}

type SecurityConfig struct {
	PairTokenTTLSeconds        int  `json:"pairTokenTtlSeconds"`
	SessionTTLSeconds          int  `json:"sessionTtlSeconds"`
	RequirePairConfirmation    bool `json:"requirePairConfirmation"`
	RequireReceiveConfirmation bool `json:"requireReceiveConfirmation"`
}

type DiscoveryConfig struct {
	MdnsEnabled bool `json:"mdnsEnabled"`
}

// Default returns a Config populated with spec defaults.
func Default() *Config {
	deviceID := uuid.NewString()
	cfg := &Config{
		Server: ServerConfig{
			Port:        DefaultPort,
			BindAddress: "auto",
			DeviceID:    deviceID,
			DeviceName:  anonymousDeviceName(deviceID),
		},
		Storage: StorageConfig{
			DownloadDirectory: "",
			ConflictPolicy:    "rename",
		},
		Transfer: TransferConfig{
			ChunkSize:           DefaultChunkSize,
			MaxConcurrentFiles:  DefaultMaxConcurrentFiles,
			MaxConcurrentChunks: DefaultMaxConcurrentChunks,
			MaxGlobalHTTP:       DefaultMaxGlobalHTTP,
			MaxChunkRetries:     5,
		},
		Security: SecurityConfig{
			PairTokenTTLSeconds:        DefaultPairTokenTTL,
			SessionTTLSeconds:          DefaultSessionTTL,
			RequirePairConfirmation:    false,
			RequireReceiveConfirmation: false,
		},
		Discovery: DiscoveryConfig{
			MdnsEnabled: true,
		},
	}
	cfg.Server.DatabasePath = filepath.Join(AppDataDir(), "fastdrop.db")
	cfg.Storage.DownloadDirectory = filepath.Join(userHome(), "Downloads", "FastDrop")
	return cfg
}

// AppDataDir returns the FastDrop folder under %APPDATA% (or equivalent).
func AppDataDir() string {
	base := os.Getenv("APPDATA")
	if base == "" {
		// Non-Windows fallback for tests.
		base = filepath.Join(userHome(), ".config")
	}
	return filepath.Join(base, "FastDrop")
}

// ConfigPath returns the absolute config file path.
func ConfigPath() string {
	return filepath.Join(AppDataDir(), "config.json")
}

// Load reads the config file at ConfigPath, applying defaults for missing keys.
// If the file does not exist, it returns Default() untouched.
func Load() (*Config, error) {
	cfg := Default()
	path := ConfigPath()
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			if err := Save(cfg); err != nil {
				return nil, fmt.Errorf("create default config: %w", err)
			}
			return cfg, nil
		}
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	var stored struct {
		Server struct {
			DeviceID   string `json:"deviceId"`
			DeviceName string `json:"deviceName"`
		} `json:"server"`
	}
	_ = json.Unmarshal(data, &stored)

	// Merge user-supplied JSON onto defaults.
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", path, err)
	}
	if stored.Server.DeviceName == "" {
		cfg.Server.DeviceName = ""
	}
	cfg.normalize()
	if stored.Server.DeviceID == "" ||
		stored.Server.DeviceName != cfg.Server.DeviceName {
		if err := Save(cfg); err != nil {
			return nil, fmt.Errorf("persist generated device id: %w", err)
		}
	}
	return cfg, nil
}

// Save writes the config to ConfigPath, creating directories as needed.
func Save(cfg *Config) error {
	dir := AppDataDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(ConfigPath(), data, 0o600)
}

// normalize enforces protocol invariants even if user config is wrong.
func (c *Config) normalize() {
	if c.Server.Port <= 0 || c.Server.Port > 65535 {
		c.Server.Port = DefaultPort
	}
	if c.Transfer.ChunkSize <= 0 {
		c.Transfer.ChunkSize = DefaultChunkSize
	}
	if c.Transfer.MaxConcurrentFiles <= 0 {
		c.Transfer.MaxConcurrentFiles = DefaultMaxConcurrentFiles
	}
	if c.Transfer.MaxConcurrentChunks <= 0 {
		c.Transfer.MaxConcurrentChunks = DefaultMaxConcurrentChunks
	}
	if c.Transfer.MaxGlobalHTTP <= 0 {
		c.Transfer.MaxGlobalHTTP = DefaultMaxGlobalHTTP
	}
	if c.Transfer.MaxChunkRetries <= 0 {
		c.Transfer.MaxChunkRetries = 5
	}
	if c.Security.PairTokenTTLSeconds <= 0 {
		c.Security.PairTokenTTLSeconds = DefaultPairTokenTTL
	}
	if c.Security.SessionTTLSeconds <= 0 {
		c.Security.SessionTTLSeconds = DefaultSessionTTL
	}
	if c.Storage.ConflictPolicy == "" {
		c.Storage.ConflictPolicy = "rename"
	}
	if c.Server.BindAddress == "" {
		c.Server.BindAddress = "auto"
	}
	if c.Server.DeviceID == "" {
		c.Server.DeviceID = uuid.NewString()
	}
	if c.Server.DeviceName == "" || isLegacyHostName(c.Server.DeviceName) {
		c.Server.DeviceName = anonymousDeviceName(c.Server.DeviceID)
	}
}

func anonymousDeviceName(deviceID string) string {
	cleanID := strings.ReplaceAll(deviceID, "-", "")
	if len(cleanID) > 6 {
		cleanID = cleanID[:6]
	}
	if cleanID == "" {
		return "FastDrop-PC"
	}
	return "FastDrop-PC-" + strings.ToUpper(cleanID)
}

func isLegacyHostName(deviceName string) bool {
	host, err := os.Hostname()
	return err == nil && host != "" && strings.EqualFold(deviceName, host)
}

func userHome() string {
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		return h
	}
	if h := os.Getenv("USERPROFILE"); h != "" {
		return h
	}
	return "."
}

// PortString is a small helper for logging / URL formatting.
func (c *Config) PortString() string { return strconv.Itoa(c.Server.Port) }
