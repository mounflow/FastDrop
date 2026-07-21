// Package session creates / validates / revokes FastDrop sessions.
// Spec §7. Tokens are NEVER stored in plaintext — only their SHA-256 hash
// is persisted (sessions.token_hash).
package session

import (
	"context"
	"crypto/subtle"
	"errors"
	"time"

	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/security"
)

// Default TTL: 12 hours (§7.1).
const DefaultTTL = 12 * time.Hour

// Session is the in-memory representation returned to callers.
type Session struct {
	ID          string
	DeviceID    string
	Token       string // plaintext, returned ONCE on creation; never re-exposed
	TokenHash   string
	SourceIP    string
	CreatedAt   time.Time
	ExpiresAt   time.Time
}

// Manager wraps a *database.DB.
type Manager struct {
	db  *database.DB
	ttl time.Duration
	now func() time.Time
}

func NewManager(db *database.DB, ttl time.Duration) *Manager {
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	return &Manager{db: db, ttl: ttl, now: time.Now}
}

// Create persists a new session for the given device. It returns the
// plaintext session token exactly once.
func (m *Manager) Create(ctx context.Context, deviceID, sourceIP string) (*Session, error) {
	id, err := security.NewUUID()
	if err != nil {
		return nil, err
	}
	tok, err := security.GenerateToken()
	if err != nil {
		return nil, err
	}
	now := m.now()
	s := &Session{
		ID:        id,
		DeviceID:  deviceID,
		Token:     tok,
		TokenHash: security.HashToken(tok),
		SourceIP:  sourceIP,
		CreatedAt: now,
		ExpiresAt: now.Add(m.ttl),
	}
	row := database.SessionRow{
		ID:        s.ID,
		DeviceID:  s.DeviceID,
		TokenHash: s.TokenHash,
		SourceIP:  s.SourceIP,
		CreatedAt: now.Unix(),
		ExpiresAt: s.ExpiresAt.Unix(),
	}
	if err := m.db.InsertSession(row); err != nil {
		return nil, err
	}
	return s, nil
}

// Validate checks sessionID + token and returns the session row on success.
// It enforces:
//   - existence
//   - revocation (revoked_at IS NULL)
//   - expiry (now < expires_at)
//   - constant-time hash equality
//
// If enforceIP is true, the caller-supplied source IP must match the stored
// one (or the stored one is empty — pre-existing sessions had no IP).
func (m *Manager) Validate(ctx context.Context, sessionID, token, sourceIP string, enforceIP bool) (*database.SessionRow, error) {
	row, err := m.db.GetSession(ctx, sessionID)
	if err != nil {
		return nil, ErrInvalid
	}
	if row.RevokedAt.Valid {
		return nil, ErrRevoked
	}
	if m.now().Unix() >= row.ExpiresAt {
		return nil, ErrExpired
	}
	gotHash := security.HashToken(token)
	if subtle.ConstantTimeCompare([]byte(gotHash), []byte(row.TokenHash)) != 1 {
		return nil, ErrInvalid
	}
	if enforceIP && row.SourceIP != "" && row.SourceIP != sourceIP {
		return nil, ErrIPMismatch
	}
	return row, nil
}

// Get returns the raw session row for lightweight validity checks
// (no token comparison).
func (m *Manager) Get(ctx context.Context, sessionID string) (*database.SessionRow, error) {
	return m.db.GetSession(ctx, sessionID)
}

// Revoke marks a session revoked.
func (m *Manager) Revoke(ctx context.Context, sessionID string) error {
	if err := m.db.RevokeSession(ctx, sessionID); err != nil {
		return err
	}
	return nil
}

// RevokeAll is invoked on server start to invalidate pre-existing sessions.
func (m *Manager) RevokeAll(ctx context.Context) (int64, error) {
	return m.db.RevokeAllSessions(ctx)
}

// ExpiresIn is a convenience for callers constructing JSON responses.
func (s *Session) ExpiresIn() int { return int(s.ExpiresAt.Sub(s.CreatedAt).Seconds()) }

var (
	ErrInvalid   = errors.New("session invalid")
	ErrExpired   = errors.New("session expired")
	ErrRevoked   = errors.New("session revoked")
	ErrIPMismatch = errors.New("session source IP mismatch")
)
