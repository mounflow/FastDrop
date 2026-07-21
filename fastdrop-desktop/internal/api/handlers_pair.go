package api

import (
	"errors"
	"net/http"

	"fastdrop-desktop/internal/netutil"
	"fastdrop-desktop/internal/pairing"
)

// pairRequestPayload mirrors §6.1.
type pairRequestPayload struct {
	PairID string                `json:"pairId"`
	Token  string                `json:"token"`
	Device pairing.ClientDevice  `json:"device"`
}

// handlePairRequest is called by the phone after scanning the QR.
func (s *Server) handlePairRequest(w http.ResponseWriter, r *http.Request) {
	var body pairRequestPayload
	if err := readJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "malformed pair request", requestID(r))
		return
	}
	if body.PairID == "" || body.Token == "" || body.Device.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "missing required fields", requestID(r))
		return
	}
	_, err := s.Pairing.Validate(body.PairID, body.Token)
	if err != nil {
		code, status := pairErrToHTTP(err)
		writeError(w, status, code, err.Error(), requestID(r))
		return
	}
	req, err := s.Pairing.CreateRequest(body.PairID, body.Device)
	if err != nil {
		writeError(w, http.StatusBadRequest, "PAIR_TOKEN_INVALID", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"requestId": req.RequestID,
		"status":    string(req.Status),
		"expiresIn": int(timeUntil(req.ExpiresAt).Seconds()),
	})
}

// handlePairStatus returns the current status (§6.2).
func (s *Server) handlePairStatus(w http.ResponseWriter, r *http.Request) {
	requestID := r.PathValue("requestId")
	req, ok := s.Pairing.GetRequest(requestID)
	if !ok {
		writeError(w, http.StatusNotFound, "PAIR_REQUEST_EXPIRED", "no such pair request", newReqIDError(r))
		return
	}
	switch req.Status {
	case pairing.StatusAccepted:
		writeJSON(w, http.StatusOK, map[string]any{
			"status": string(req.Status),
			"session": map[string]any{
				"sessionId":    req.Result.SessionID,
				"accessToken":  req.Result.SessionToken,
				"expiresIn":    req.Result.ExpiresIn,
				"websocketUrl": req.Result.WebsocketURL,
			},
			"server": map[string]any{
				"deviceId":   req.Result.ServerDevice.DeviceID,
				"deviceName": req.Result.ServerDevice.DeviceName,
				"platform":   req.Result.ServerDevice.Platform,
			},
		})
	case pairing.StatusRejected:
		writeJSON(w, http.StatusOK, map[string]any{
			"status": string(req.Status),
			"reason": req.RejectReason,
		})
	case pairing.StatusExpired:
		writeJSON(w, http.StatusOK, map[string]any{"status": string(req.Status)})
	default:
		writeJSON(w, http.StatusOK, map[string]any{
			"status":    string(req.Status),
			"expiresIn": int(timeUntil(req.ExpiresAt).Seconds()),
		})
	}
}

// handlePairAccept is invoked by the PC user (via Vue UI) to approve.
func (s *Server) handlePairAccept(w http.ResponseWriter, r *http.Request) {
	requestID := r.PathValue("requestId")
	req, ok := s.Pairing.GetRequest(requestID)
	if !ok {
		writeError(w, http.StatusNotFound, "PAIR_REQUEST_EXPIRED", "no such pair request", requestID)
		return
	}
	// Create the session.
	ip := clientIP(r)
	dbDev := upsertDeviceFromRequest(s, req.Device, ip)
	sess, err := s.Session.Create(r.Context(), dbDev.ID, ip)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID)
		return
	}
	result := pairing.AcceptResult{
		SessionID:    sess.ID,
		SessionToken: sess.Token,
		ExpiresIn:    sess.ExpiresIn(),
		WebsocketURL: s.WebSocketURL(req.Device.DeviceID),
		ServerDevice: serverDeviceIdentity(s),
	}
	if err := s.Pairing.Accept(requestID, result); err != nil {
		writeError(w, http.StatusBadRequest, "PAIR_REQUEST_EXPIRED", err.Error(), requestID)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "accepted",
		"session": map[string]any{
			"sessionId":    sess.ID,
			"accessToken":  sess.Token,
			"expiresIn":    sess.ExpiresIn(),
			"websocketUrl": s.WebSocketURL(req.Device.DeviceID),
		},
		"server": map[string]any{
			"deviceId":   "local",
			"deviceName": s.Cfg.Server.DeviceName,
			"platform":   "windows",
		},
	})
}

// handlePairReject is invoked by the PC user to decline.
func (s *Server) handlePairReject(w http.ResponseWriter, r *http.Request) {
	requestID := r.PathValue("requestId")
	if err := s.Pairing.Reject(requestID, "user_rejected"); err != nil {
		writeError(w, http.StatusNotFound, "PAIR_REQUEST_EXPIRED", err.Error(), requestID)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "rejected"})
}

// handlePairTokenRefresh issues a fresh token for the same pair ID.
// Caller must be authenticated (PC-side UI only).
func (s *Server) handlePairTokenRefresh(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PairID string `json:"pairId"`
	}
	_ = readJSON(r, &body)
	if body.PairID == "" {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "pairId required", requestID(r))
		return
	}
	pt, err := s.Pairing.Refresh(body.PairID, s.Cfg.Server.DeviceName, clientIP(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, s.qrPayload(pt))
}

// handleListPairRequests returns all pending pair requests for the PC UI.
func (s *Server) handleListPairRequests(w http.ResponseWriter, r *http.Request) {
	requests := s.Pairing.ListPendingRequests()
	out := make([]map[string]any, 0, len(requests))
	for _, req := range requests {
		out = append(out, map[string]any{
			"requestId":  req.RequestID,
			"pairId":     req.PairID,
			"status":     string(req.Status),
			"device":     req.Device,
			"expiresIn":  int(timeUntil(req.ExpiresAt).Seconds()),
			"createdAt":  req.CreatedAt.UnixMilli(),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"requests": out})
}

// handleCurrentQRPayload returns the active QR data for the Vue UI. If no
// token has been issued yet (server just started), one is minted on demand.
func (s *Server) handleCurrentQRPayload(w http.ResponseWriter, r *http.Request) {
	pt, err := s.Pairing.Issue(s.Cfg.Server.DeviceName, clientIP(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, s.qrPayload(pt))
}

func (s *Server) qrPayload(pt *pairing.PairToken) map[string]any {
	primary := s.resolveHost()
	candidates := netutil.LANIPv4Addresses()
	// Build altHosts: every other LAN IPv4 the server is reachable on.
	// The phone tries `host` first, then each altHost until one connects.
	// This handles the common case where the phone is on the PC's mobile
	// hotspot (different subnet from the PC's primary LAN IP).
	altHosts := make([]string, 0, len(candidates))
	for _, ip := range candidates {
		if ip != primary {
			altHosts = append(altHosts, ip)
		}
	}
	return map[string]any{
		"version":    1,
		"protocol":   "fastdrop",
		"host":       primary,
		"altHosts":   altHosts,
		"port":       s.Cfg.Server.Port,
		"pairId":     pt.PairID,
		"token":      pt.Token,
		"expiresAt":  pt.ExpiresAt.Unix(),
		"serverName": s.Cfg.Server.DeviceName,
	}
}

func pairErrToHTTP(err error) (string, int) {
	switch {
	case errors.Is(err, pairing.ErrTokenInvalid):
		return "PAIR_TOKEN_INVALID", http.StatusUnauthorized
	case errors.Is(err, pairing.ErrTokenExpired):
		return "PAIR_TOKEN_EXPIRED", http.StatusUnauthorized
	case errors.Is(err, pairing.ErrTokenAlreadyUsed):
		return "PAIR_TOKEN_ALREADY_USED", http.StatusUnauthorized
	case errors.Is(err, pairing.ErrTokenLocked):
		return "PAIR_TOKEN_INVALID", http.StatusTooManyRequests
	default:
		return "PAIR_TOKEN_INVALID", http.StatusBadRequest
	}
}

func newReqIDError(r *http.Request) string {
	if id, ok := r.Context().Value(ctxRequestID).(string); ok {
		return id
	}
	id, _ := newReqID()
	return id
}
