// Package api exposes FastDrop REST endpoints (spec §20) and middleware.
package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"fastdrop-desktop/internal/config"
	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/pairing"
	"fastdrop-desktop/internal/session"
	"fastdrop-desktop/internal/storage"
	"fastdrop-desktop/internal/transfer"
	"fastdrop-desktop/internal/websocket"
)

// Server bundles all subsystems the API needs.
type Server struct {
	Cfg      *config.Config
	DB       *database.DB
	Pairing  *pairing.Manager
	Session  *session.Manager
	Transfer *transfer.Manager
	Storage  *storage.Manager
	WSHub    *websocket.Hub
}

// upsertDevice persists a device row.
func upsertDevice(s *Server, dev database.Device) error {
	return s.DB.UpsertDevice(dev)
}

// getDevice fetches a device row by ID.
func (s *Server) getDevice(id string) (*database.Device, error) {
	return s.DB.GetDevice(context.Background(), id)
}

// New constructs an http.Handler with all routes mounted under /api/v1.
func New(s *Server) http.Handler {
	mux := http.NewServeMux()

	// --- system ---
	mux.HandleFunc("GET /api/v1/health", handleHealth)
	mux.HandleFunc("GET /api/v1/server/info", s.handleServerInfo)
	mux.HandleFunc("GET /api/v1/capabilities", s.handleCapabilities)

	// --- pairing ---
	mux.HandleFunc("POST /api/v1/pair/request", s.withSizeLimit(64*1024, s.withPairRateLimit(s.handlePairRequest)))
	mux.HandleFunc("GET /api/v1/pair/requests", s.handleListPairRequests)
	mux.HandleFunc("GET /api/v1/pair/requests/{requestId}", s.handlePairStatus)
	mux.HandleFunc("POST /api/v1/pair/requests/{requestId}/accept", s.withPairRateLimit(s.handlePairAccept))
	mux.HandleFunc("POST /api/v1/pair/requests/{requestId}/reject", s.withPairRateLimit(s.handlePairReject))
	mux.HandleFunc("POST /api/v1/pair/token/refresh", s.withAuth(s.handlePairTokenRefresh))

	// --- session ---
	mux.HandleFunc("GET /api/v1/session", s.withAuth(s.handleSessionGet))
	mux.HandleFunc("DELETE /api/v1/session", s.withAuth(s.handleSessionDelete))

	// --- transfers ---
	mux.HandleFunc("POST /api/v1/transfers", s.withAuth(s.withSizeLimit(1*1024*1024, s.handleCreateTransfer)))
	mux.HandleFunc("GET /api/v1/transfers", s.withAuth(s.handleListTransfers))
	mux.HandleFunc("GET /api/v1/transfers/active", s.withAuth(s.handleListActiveTransfers))
	mux.HandleFunc("GET /api/v1/transfers/{transferId}", s.withAuth(s.handleGetTransfer))
	mux.HandleFunc("POST /api/v1/transfers/{transferId}/cancel", s.withAuth(s.handleCancelTransfer))
	mux.HandleFunc("POST /api/v1/transfers/{transferId}/retry", s.withAuth(s.handleRetryTransfer))
	mux.HandleFunc("DELETE /api/v1/transfers/{transferId}", s.withAuth(s.handleDeleteTransfer))

	// --- files ---
	mux.HandleFunc("GET /api/v1/transfers/{transferId}/files/{fileId}", s.withAuth(s.handleGetFile))
	mux.HandleFunc("PUT /api/v1/transfers/{transferId}/files/{fileId}/chunks/{chunkIndex}", s.withAuth(s.handlePutChunk))
	mux.HandleFunc("GET /api/v1/transfers/{transferId}/files/{fileId}/chunks", s.withAuth(s.handleListChunks))
	mux.HandleFunc("POST /api/v1/transfers/{transferId}/files/{fileId}/complete", s.withAuth(s.withSizeLimit(64*1024, s.handleCompleteFile)))
	mux.HandleFunc("GET /api/v1/transfers/{transferId}/files/{fileId}/content", s.withAuth(s.handleDownloadFile))
	mux.HandleFunc("HEAD /api/v1/transfers/{transferId}/files/{fileId}/content", s.withAuth(s.handleDownloadFile))

	// --- current pair token (for the QR code) ---
	mux.HandleFunc("GET /api/v1/pair/qr", s.handleCurrentQRPayload)

	return withRecover(mux)
}

// withRecover wraps the handler to convert panics into 500s.
func withRecover(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "internal server error", requestID(r))
			}
		}()
		h.ServeHTTP(w, r)
	})
}

type ctxKey string

const (
	ctxRequestID ctxKey = "requestID"
	ctxSessionID ctxKey = "sessionID"
	ctxDeviceID  ctxKey = "deviceID"
)

func requestID(r *http.Request) string {
	if v, ok := r.Context().Value(ctxRequestID).(string); ok {
		return v
	}
	return ""
}

// handleHealth is a simple liveness probe.
func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":   "ok",
		"version":  "0.1.0",
		"protocol": 1,
	})
}

func (s *Server) handleServerInfo(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"deviceId":   "local",
		"name":       s.Cfg.Server.DeviceName,
		"platform":   "windows",
		"protocol":   1,
		"version":    "0.1.0",
		"port":       s.Cfg.Server.Port,
		"mdnsEnabled": s.Cfg.Discovery.MdnsEnabled,
	})
}

func (s *Server) handleCapabilities(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"chunkSize":          s.Cfg.Transfer.ChunkSize,
		"maxConcurrentFiles": s.Cfg.Transfer.MaxConcurrentFiles,
		"maxConcurrentChunks": s.Cfg.Transfer.MaxConcurrentChunks,
		"maxGlobalHTTP":      s.Cfg.Transfer.MaxGlobalHTTP,
		"supportedVersions":  []int{1},
	})
}

// writeJSON is a small helper that sets the content type and writes a value.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeError emits the canonical error shape from §21.
func writeError(w http.ResponseWriter, status int, code, msg, reqID string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]any{
			"code":      code,
			"message":   msg,
			"requestId": reqID,
			"details":   map[string]any{},
		},
	})
}

// withAuth enforces Authorization + X-Session-Id on protected routes.
// On success the session/device IDs are stashed in the request context.
func (s *Server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		reqID, _ := generateID()
		r = withContext(r, ctxRequestID, reqID)

		authHeader := r.Header.Get("Authorization")
		if !strings.HasPrefix(authHeader, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "SESSION_INVALID", "missing bearer token", reqID)
			return
		}
		token := strings.TrimPrefix(authHeader, "Bearer ")
		sessionID := r.Header.Get("X-Session-Id")
		if sessionID == "" {
			writeError(w, http.StatusUnauthorized, "SESSION_INVALID", "missing session id", reqID)
			return
		}
		ip := clientIP(r)
		// enforceIP=false: the same session is shared by the PC browser
		// (127.0.0.1) and the phone (LAN IP), so strict IP binding would
		// reject valid API requests from the phone.
		row, err := s.Session.Validate(r.Context(), sessionID, token, ip, false)
		if err != nil {
			code, status := sessionErrToHTTP(err)
			writeError(w, status, code, "session rejected", reqID)
			return
		}
		r = withContext(r, ctxSessionID, row.ID)
		r = withContext(r, ctxDeviceID, row.DeviceID)
		next(w, r)
	}
}

func sessionErrToHTTP(err error) (string, int) {
	switch {
	case err == session.ErrRevoked:
		return "SESSION_REVOKED", http.StatusUnauthorized
	case err == session.ErrExpired:
		return "SESSION_EXPIRED", http.StatusUnauthorized
	case err == session.ErrIPMismatch:
		return "SESSION_INVALID", http.StatusUnauthorized
	default:
		return "SESSION_INVALID", http.StatusUnauthorized
	}
}

func withContext(r *http.Request, key, val any) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), key, val))
}

func clientIP(r *http.Request) string {
	if h := r.Header.Get("X-Forwarded-For"); h != "" {
		if i := strings.Index(h, ","); i > 0 {
			return strings.TrimSpace(h[:i])
		}
		return strings.TrimSpace(h)
	}
	host := r.RemoteAddr
	if i := strings.LastIndex(host, ":"); i > 0 {
		host = host[:i]
	}
	return strings.Trim(host, "[]")
}

// generateID returns a short request ID. Reuses the security package's UUID.
func generateID() (string, error) {
	return newReqID()
}

// now0 is a tiny indirection to keep tests deterministic.
var now0 = func() time.Time { return time.Now() }
