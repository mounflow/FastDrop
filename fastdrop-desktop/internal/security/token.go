// Package security provides cryptographic primitives, filename sanitization,
// and hashing utilities for FastDrop.
package security

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"io"

	"github.com/google/uuid"
)

// NewUUID returns a fresh RFC 4122 v4 UUID string. Used for pair IDs,
// request IDs, transfer IDs, etc.
func NewUUID() (string, error) {
	u, err := uuid.NewRandomFromReader(rand.Reader)
	if err != nil {
		return "", err
	}
	return u.String(), nil
}

// GenerateToken returns a 32-byte Base64URL-encoded token (no padding).
// Uses crypto/rand as mandated by spec §5.2. Never use math/rand.
func GenerateToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// HashToken returns the hex-encoded SHA-256 hash of a token.
// Tokens are never stored in plaintext (spec §22.2, CLAUDE.md).
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// HashReader returns the hex SHA-256 of all bytes read from r.
func HashReader(r io.Reader) (string, error) {
	h := sha256.New()
	if _, err := io.Copy(h, r); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
