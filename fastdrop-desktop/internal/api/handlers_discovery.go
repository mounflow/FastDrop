package api

import (
	"context"
	"net/http"
	"time"

	"fastdrop-desktop/internal/discovery"
)

// handleDiscoveryNearby scans the LAN for FastDrop peers (问题 10). Desktop
// UI only: the scan reveals nothing sensitive (peers advertise their health
// endpoint on the LAN anyway), but it is slow and pointless for LAN clients,
// so it stays off the authenticated surface.
func (s *Server) handleDiscoveryNearby(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	devices, err := discovery.DiscoverNearby(ctx, s.Cfg.Server.DeviceID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devices})
}
