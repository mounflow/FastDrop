package websocket

import (
	"context"

	"fastdrop-desktop/internal/session"
)

// SessionValidator adapts *session.Manager to the Validator interface.
type SessionValidator struct{ M *session.Manager }

// Validate returns the deviceID bound to the session on success.
func (s *SessionValidator) Validate(ctx context.Context, sessionID, token, sourceIP string, enforceIP bool) (string, error) {
	row, err := s.M.Validate(ctx, sessionID, token, sourceIP, enforceIP)
	if err != nil {
		return "", err
	}
	return row.DeviceID, nil
}

var _ Validator = (*SessionValidator)(nil)
