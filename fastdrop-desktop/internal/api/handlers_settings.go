package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"

	"fastdrop-desktop/internal/config"
)

// saveCfg persists the config to disk.
func saveCfg(cfg *config.Config) error {
	return config.Save(cfg)
}

// settingsResponse is the JSON shape returned by GET /api/v1/settings.
type settingsResponse struct {
	DownloadDirectory string `json:"downloadDirectory"`
	ConflictPolicy    string `json:"conflictPolicy"`
	DeviceName        string `json:"deviceName"`
	MdnsEnabled       bool   `json:"mdnsEnabled"`
}

// updateSettingsRequest is the JSON body for PUT /api/v1/settings.
type updateSettingsRequest struct {
	DownloadDirectory *string `json:"downloadDirectory,omitempty"`
	ConflictPolicy    *string `json:"conflictPolicy,omitempty"`
	MdnsEnabled       *bool   `json:"mdnsEnabled,omitempty"`
}

// handleGetSettings returns the current configurable settings.
// No auth required — this endpoint is only reachable from the local PC
// browser (same-origin, embedded UI).
func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request) {
	mdnsEnabled := s.Cfg.Discovery.MdnsEnabled
	if s.Discovery != nil {
		// Prefer the live controller state — it may have been toggled
		// without making it to disk yet (shouldn't happen in practice
		// since SetEnabled persists below, but defensive).
		mdnsEnabled = s.Discovery.IsEnabled()
	}
	writeJSON(w, http.StatusOK, settingsResponse{
		DownloadDirectory: s.Storage.DownloadDir(),
		ConflictPolicy:    s.Cfg.Storage.ConflictPolicy,
		DeviceName:        s.Cfg.Server.DeviceName,
		MdnsEnabled:       mdnsEnabled,
	})
}

// handleUpdateSettings updates configurable settings and persists them
// to config.json. Hot-reloads the storage manager's download directory.
func (s *Server) handleUpdateSettings(w http.ResponseWriter, r *http.Request) {
	reqID, _ := generateID()
	var req updateSettingsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "malformed JSON body", reqID)
		return
	}

	changed := false

	// Update download directory.
	if req.DownloadDirectory != nil {
		dir := filepath.Clean(*req.DownloadDirectory)
		if dir == "" {
			writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "downloadDirectory cannot be empty", reqID)
			return
		}
		abs, err := filepath.Abs(dir)
		if err != nil {
			writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid path: "+err.Error(), reqID)
			return
		}
		// Verify the directory is usable (create if needed).
		if err := os.MkdirAll(abs, 0o755); err != nil {
			writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "cannot create directory: "+err.Error(), reqID)
			return
		}
		// Hot-reload the storage manager.
		if err := s.Storage.SetDownloadDir(abs); err != nil {
			writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to set download dir: "+err.Error(), reqID)
			return
		}
		s.Cfg.Storage.DownloadDirectory = abs
		changed = true
	}

	// Update conflict policy.
	if req.ConflictPolicy != nil {
		p := *req.ConflictPolicy
		if p != "rename" && p != "overwrite" && p != "skip" {
			writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "conflictPolicy must be rename, overwrite, or skip", reqID)
			return
		}
		s.Cfg.Storage.ConflictPolicy = p
		changed = true
	}

	// Toggle mDNS broadcasting. Hot-swapped via the Discovery
	// controller — no server restart required.
	if req.MdnsEnabled != nil {
		if s.Discovery != nil {
			if err := s.Discovery.SetEnabled(*req.MdnsEnabled); err != nil {
				writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to toggle mDNS: "+err.Error(), reqID)
				return
			}
		}
		s.Cfg.Discovery.MdnsEnabled = *req.MdnsEnabled
		changed = true
	}

	if changed {
		if err := saveCfg(s.Cfg); err != nil {
			writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to save config: "+err.Error(), reqID)
			return
		}
	}

	// Return the updated settings.
	mdnsEnabled := s.Cfg.Discovery.MdnsEnabled
	if s.Discovery != nil {
		mdnsEnabled = s.Discovery.IsEnabled()
	}
	writeJSON(w, http.StatusOK, settingsResponse{
		DownloadDirectory: s.Storage.DownloadDir(),
		ConflictPolicy:    s.Cfg.Storage.ConflictPolicy,
		DeviceName:        s.Cfg.Server.DeviceName,
		MdnsEnabled:       mdnsEnabled,
	})
}
