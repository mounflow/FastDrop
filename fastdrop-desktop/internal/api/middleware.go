package api

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"fastdrop-desktop/internal/security"
)

// withSizeLimit caps request body bytes via http.MaxBytesReader (spec §28.1).
func (s *Server) withSizeLimit(maxBytes int64, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
		next(w, r)
	}
}

// rateLimiter is a per-IP sliding-window counter for the pair endpoints.
// Spec §28.2: 20 requests / minute / IP.
type rateLimiter struct {
	mu       sync.Mutex
	hits     map[string][]time.Time
	maxCount int
	window   time.Duration
}

func newRateLimiter(maxCount int, window time.Duration) *rateLimiter {
	return &rateLimiter{hits: make(map[string][]time.Time), maxCount: maxCount, window: window}
}

// allow returns true if ip may proceed. It prunes old entries in place.
func (rl *rateLimiter) allow(ip string, now time.Time) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	cutoff := now.Add(-rl.window)
	hits := rl.hits[ip]
	keep := hits[:0]
	for _, h := range hits {
		if h.After(cutoff) {
			keep = append(keep, h)
		}
	}
	if len(keep) >= rl.maxCount {
		rl.hits[ip] = keep
		return false
	}
	keep = append(keep, now)
	rl.hits[ip] = keep
	return true
}

// pairLimiter is the singleton limiter for /api/v1/pair/* endpoints.
var pairLimiter = newRateLimiter(20, 1*time.Minute)

func (s *Server) withPairRateLimit(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if !pairLimiter.allow(ip, time.Now()) {
			writeError(w, http.StatusTooManyRequests, "TOO_MANY_REQUESTS", "rate limit exceeded; try again later", requestID(r))
			return
		}
		next(w, r)
	}
}

// readJSON decodes the body into out using encoding/json with the upstream
// MaxBytesReader enforcing size limits. Unknown fields are tolerated for
// forward-compatibility with newer clients.
func readJSON(r *http.Request, out any) error {
	dec := json.NewDecoder(r.Body)
	return dec.Decode(out)
}

// drainAndClose ensures request bodies are fully drained so connections
// can be reused.
func drainAndClose(r *http.Request) {
	if r.Body != nil {
		_, _ = io.Copy(io.Discard, r.Body)
		r.Body.Close()
	}
}

// isPrivateIPv4 reports whether ip is RFC1918 (not loopback/link-local).
func isPrivateIPv4(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	if ip4 := ip.To4(); ip4 != nil {
		switch {
		case ip4[0] == 10:
			return true
		case ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31:
			return true
		case ip4[0] == 192 && ip4[1] == 168:
			return true
		}
	}
	return false
}

// looksVirtualAdapter filters WSL / Docker / VPN NIC names (spec §27).
func looksVirtualAdapter(name string) bool {
	n := strings.ToLower(name)
	for _, key := range []string{"wsl", "docker", "vethernet", "virtualbox", "vmware", "tap-", "tunnel", "vpn", "hyper-v"} {
		if strings.Contains(n, key) {
			return true
		}
	}
	return false
}

// newReqID returns a UUID for request correlation.
func newReqID() (string, error) { return security.NewUUID() }
