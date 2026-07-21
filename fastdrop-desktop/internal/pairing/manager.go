// Package pairing manages one-time pair tokens and pending pair requests
// (spec §5, §6).
package pairing

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"sync"
	"time"

	"fastdrop-desktop/internal/security"
)

// DefaultTokenTTL is the spec-mandated token lifetime (§5.2).
const DefaultTokenTTL = 60 * time.Second

// MaxTokenFailures locks a token after this many failed verifications.
const MaxTokenFailures = 5

// PendingStatus enumerates the lifecycle of a pair request once the
// phone has hit POST /pair/request.
type PendingStatus string

const (
	StatusWaitingConfirmation PendingStatus = "waiting_confirmation"
	StatusAccepted            PendingStatus = "accepted"
	StatusRejected            PendingStatus = "rejected"
	StatusExpired             PendingStatus = "expired"
)

// PairToken is an issued, not-yet-consumed pair token.
type PairToken struct {
	PairID     string
	Token      string // plaintext — only kept in memory, never persisted
	HashedTok  string // sha256(token) — for in-memory equality only
	ExpiresAt  time.Time
	CreatedAt  time.Time
	Failures   int
	Consumed   bool
	ServerName string
	SourceIP   string // network IP captured when the QR was generated, optional
}

// PairRequest is a phone-initiated pair attempt that is pending user action.
type PairRequest struct {
	RequestID   string
	PairID      string
	Status      PendingStatus
	Device      ClientDevice
	CreatedAt   time.Time
	ExpiresAt   time.Time
	Result      *AcceptResult // populated on accept
	RejectReason string
}

// ClientDevice is the device-info payload a phone sends when requesting.
type ClientDevice struct {
	DeviceID    string `json:"deviceId"`
	DeviceName  string `json:"deviceName"`
	Platform    string `json:"platform"`
	AppVersion  string `json:"appVersion"`
}

// AcceptResult is what the phone ultimately receives after acceptance.
type AcceptResult struct {
	SessionID     string
	SessionToken  string
	ExpiresIn     int
	WebsocketURL  string
	ServerDevice  ClientDevice
}

// Manager holds in-memory pair tokens + pending requests.
// All state is volatile; a server restart invalidates every pending pair,
// consistent with spec §5.2 (single-use, short-lived) and §7.1 (restart
// invalidates sessions).
type Manager struct {
	mu              sync.Mutex
	now             func() time.Time
	ttl             time.Duration
	requestTTL      time.Duration
	tokens          map[string]*PairToken    // by PairID
	requests        map[string]*PairRequest  // by RequestID
	tokenByRequest  map[string]string        // requestID -> PairID (for status lookup)
}

// NewManager constructs a Manager with the given token TTL. requestTTL is
// the window in which the user must accept or reject; it defaults to 30s
// (per §6.1 example response "expiresIn": 30).
func NewManager(tokenTTL time.Duration) *Manager {
	if tokenTTL <= 0 {
		tokenTTL = DefaultTokenTTL
	}
	return &Manager{
		now:            time.Now,
		ttl:            tokenTTL,
		requestTTL:     30 * time.Second,
		tokens:         make(map[string]*PairToken),
		requests:       make(map[string]*PairRequest),
		tokenByRequest: make(map[string]string),
	}
}

// Issue generates a fresh pair ID and one-time token.
// The caller (server) is responsible for embedding both in the QR code.
func (m *Manager) Issue(serverName, sourceIP string) (*PairToken, error) {
	pairID, err := security.NewUUID()
	if err != nil {
		return nil, err
	}
	tok, err := security.GenerateToken()
	if err != nil {
		return nil, err
	}
	now := m.now()
	pt := &PairToken{
		PairID:     pairID,
		Token:      tok,
		HashedTok:  security.HashToken(tok),
		ExpiresAt:  now.Add(m.ttl),
		CreatedAt:  now,
		ServerName: serverName,
		SourceIP:   sourceIP,
	}
	m.mu.Lock()
	m.tokens[pairID] = pt
	m.mu.Unlock()
	return pt, nil
}

// Lookup returns the token by pairID (whether or not expired/consumed).
func (m *Manager) Lookup(pairID string) (*PairToken, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tokens[pairID]
	return t, ok
}

// Validate checks the pairID + plaintext token against the issued token.
// It returns:
//
//   - nil + the *PairToken on success (token consumed atomically)
//   - ErrTokenInvalid / ErrTokenExpired / ErrTokenAlreadyUsed / ErrTokenLocked
//
// On success the token is marked Consumed so it cannot be reused.
// On failure the Failures counter is incremented and the token may be locked.
func (m *Manager) Validate(pairID, token string) (*PairToken, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	t, ok := m.tokens[pairID]
	if !ok {
		return nil, ErrTokenInvalid
	}
	if t.Consumed {
		return nil, ErrTokenAlreadyUsed
	}
	if t.Failures >= MaxTokenFailures {
		return nil, ErrTokenLocked
	}
	if m.now().After(t.ExpiresAt) {
		return nil, ErrTokenExpired
	}
	// Constant-time compare against the hashed token.
	gotHash := security.HashToken(token)
	if subtle.ConstantTimeCompare([]byte(gotHash), []byte(t.HashedTok)) != 1 {
		t.Failures++
		if t.Failures >= MaxTokenFailures {
			return nil, ErrTokenLocked
		}
		return nil, ErrTokenInvalid
	}
	t.Consumed = true
	return t, nil
}

// CreateRequest registers a phone-initiated pair request and returns its ID.
// Callers must have already called Validate successfully.
func (m *Manager) CreateRequest(pairID string, dev ClientDevice) (*PairRequest, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tokens[pairID]
	if !ok {
		return nil, ErrTokenInvalid
	}
	if !t.Consumed {
		return nil, fmt.Errorf("pair token not yet validated")
	}
	reqID, err := security.NewUUID()
	if err != nil {
		return nil, err
	}
	now := m.now()
	req := &PairRequest{
		RequestID: reqID,
		PairID:    pairID,
		Status:    StatusWaitingConfirmation,
		Device:    dev,
		CreatedAt: now,
		ExpiresAt: now.Add(m.requestTTL),
	}
	m.requests[reqID] = req
	m.tokenByRequest[reqID] = pairID
	return req, nil
}

// GetRequest looks up a request by ID.
func (m *Manager) GetRequest(requestID string) (*PairRequest, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.requests[requestID]
	if !ok {
		return nil, false
	}
	if r.Status == StatusWaitingConfirmation && m.now().After(r.ExpiresAt) {
		r.Status = StatusExpired
	}
	return r, true
}

// Accept marks a request accepted and stores the session result so the
// phone can pick it up via GetRequest.
func (m *Manager) Accept(requestID string, result AcceptResult) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.requests[requestID]
	if !ok {
		return ErrRequestNotFound
	}
	if r.Status != StatusWaitingConfirmation {
		return fmt.Errorf("pair request is in terminal state %q", r.Status)
	}
	if m.now().After(r.ExpiresAt) {
		r.Status = StatusExpired
		return ErrRequestExpired
	}
	r.Status = StatusAccepted
	r.Result = &result
	return nil
}

// Reject marks a request rejected with a reason code.
func (m *Manager) Reject(requestID, reason string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.requests[requestID]
	if !ok {
		return ErrRequestNotFound
	}
	if r.Status != StatusWaitingConfirmation {
		return fmt.Errorf("pair request is in terminal state %q", r.Status)
	}
	r.Status = StatusRejected
	r.RejectReason = reason
	return nil
}

// Refresh reuses the same pairID to issue a brand-new token, invalidating
// the previous token. Used by POST /pair/token/refresh.
func (m *Manager) Refresh(pairID, serverName, sourceIP string) (*PairToken, error) {
	tok, err := security.GenerateToken()
	if err != nil {
		return nil, err
	}
	now := m.now()
	pt := &PairToken{
		PairID:     pairID,
		Token:      tok,
		HashedTok:  security.HashToken(tok),
		ExpiresAt:  now.Add(m.ttl),
		CreatedAt:  now,
		ServerName: serverName,
		SourceIP:   sourceIP,
	}
	m.mu.Lock()
	m.tokens[pairID] = pt
	m.mu.Unlock()
	return pt, nil
}

// ListPendingRequests returns all requests still waiting for user action.
func (m *Manager) ListPendingRequests() []*PairRequest {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	out := make([]*PairRequest, 0)
	for _, r := range m.requests {
		if r.Status == StatusWaitingConfirmation && now.Before(r.ExpiresAt) {
			out = append(out, r)
		}
	}
	return out
}

// Cleanup evicts expired tokens and expired pending requests. Intended to be
// called on a timer.
func (m *Manager) Cleanup() {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	for id, t := range m.tokens {
		if t.Consumed || now.After(t.ExpiresAt.Add(5*time.Minute)) {
			delete(m.tokens, id)
		}
	}
	for id, r := range m.requests {
		// Keep terminal requests (accepted/rejected/expired) for 5 minutes
		// after creation so the phone has time to poll for the result.
		if now.After(r.CreatedAt.Add(5 * time.Minute)) {
			delete(m.requests, id)
			delete(m.tokenByRequest, id)
		}
	}
}

// Errors. Callers should map these to §21 codes:
//   ErrTokenInvalid       -> PAIR_TOKEN_INVALID
//   ErrTokenExpired       -> PAIR_TOKEN_EXPIRED
//   ErrTokenAlreadyUsed   -> PAIR_TOKEN_ALREADY_USED
//   ErrTokenLocked        -> PAIR_TOKEN_INVALID (after 5 fails)
//   ErrRequestNotFound    -> PAIR_REQUEST_EXPIRED
//   ErrRequestExpired     -> PAIR_REQUEST_EXPIRED
var (
	ErrTokenInvalid      = errors.New("pair token invalid")
	ErrTokenExpired      = errors.New("pair token expired")
	ErrTokenAlreadyUsed  = errors.New("pair token already used")
	ErrTokenLocked       = errors.New("pair token locked after repeated failures")
	ErrRequestNotFound   = errors.New("pair request not found")
	ErrRequestExpired    = errors.New("pair request expired")
)
