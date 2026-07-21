package api

import (
	"net/http"
	"strings"
	"time"

	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/netutil"
	"fastdrop-desktop/internal/pairing"
	ws "fastdrop-desktop/internal/websocket"
)

// timeUntil returns seconds until t (never negative).
func timeUntil(t time.Time) time.Duration {
	d := time.Until(t)
	if d < 0 {
		return 0
	}
	return d
}

// upsertDeviceFromRequest records the client device info in the DB.
func upsertDeviceFromRequest(s *Server, dev pairing.ClientDevice, ip string) *database.Device {
	row := database.Device{
		ID: dev.DeviceID, Name: dev.DeviceName, Platform: dev.Platform,
		AppVersion: dev.AppVersion, LastIP: ip,
		FirstSeenAt: database.Now(), LastSeenAt: database.Now(),
	}
	if existing, err := s.getDevice(dev.DeviceID); err == nil {
		row.FirstSeenAt = existing.FirstSeenAt
	}
	_ = upsertDevice(s, row)
	return &row
}

// serverDeviceIdentity is the FastDrop-PC identity shared with the phone
// on pair-accept (§6.2).
func serverDeviceIdentity(s *Server) pairing.ClientDevice {
	return pairing.ClientDevice{
		DeviceID:   "windows-local",
		DeviceName: s.Cfg.Server.DeviceName,
		Platform:   "windows",
		AppVersion: "0.1.0",
	}
}

// WebSocketURL returns the canonical ws:// URL for the controller.
// Falls back through: explicit BindAddress -> auto-detected LAN IPv4 ->
// 127.0.0.1 (loopback only — useful for local dev, never for a real phone).
func (s *Server) WebSocketURL(_ string) string {
	return "ws://" + s.resolveHost() + ":" + itoaPort(s.Cfg.Server.Port) + "/ws/v1"
}

// resolveHost returns the host the phone should use to reach this PC.
// Order: explicit BindAddress (not "auto") -> first LAN IPv4 -> loopback.
func (s *Server) resolveHost() string {
	h := s.Cfg.Server.BindAddress
	if h != "" && h != "auto" && !strings.HasPrefix(h, "0.") {
		return h
	}
	if lan := netutil.PreferLANIPv4(); lan != "" {
		return lan
	}
	return "127.0.0.1"
}

func itoaPort(p int) string {
	if p == 0 {
		return "9527"
	}
	return strconvItoa(p)
}

func strconvItoa(p int) string {
	if p == 0 {
		return "0"
	}
	digits := []byte{}
	neg := p < 0
	if neg {
		p = -p
	}
	for p > 0 {
		digits = append([]byte{byte('0' + p%10)}, digits...)
		p /= 10
	}
	if neg {
		digits = append([]byte{'-'}, digits...)
	}
	return string(digits)
}

// session handlers.

// handleSessionGet returns the active session's metadata.
func (s *Server) handleSessionGet(w http.ResponseWriter, r *http.Request) {
	sessID, _ := r.Context().Value(ctxSessionID).(string)
	devID, _ := r.Context().Value(ctxDeviceID).(string)
	writeJSON(w, http.StatusOK, map[string]any{
		"sessionId": sessID,
		"deviceId":  devID,
	})
}

// handleSessionDelete revokes the current session.
func (s *Server) handleSessionDelete(w http.ResponseWriter, r *http.Request) {
	sessID, _ := r.Context().Value(ctxSessionID).(string)
	if err := s.Session.Revoke(r.Context(), sessID); err != nil {
		writeError(w, http.StatusNotFound, "SESSION_INVALID", err.Error(), requestID(r))
		return
	}
	// Notify all WS clients on this session that it has been revoked.
	s.pushWSEvent(sessID, ws.MsgSessionRevoked, map[string]any{
		"sessionId": sessID,
	})
	writeJSON(w, http.StatusOK, map[string]any{"status": "revoked"})
}
