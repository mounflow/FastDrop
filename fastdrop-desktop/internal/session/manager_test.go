package session

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"fastdrop-desktop/internal/database"
)

func newDB(t *testing.T) *database.DB {
	t.Helper()
	db, err := database.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestCreateAndValidate(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, time.Hour)
	ctx := context.Background()
	db.UpsertDevice(database.Device{ID: "d1", Name: "x", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	s, err := m.Create(ctx, "d1", "1.1.1.1")
	if err != nil {
		t.Fatal(err)
	}
	if s.Token == "" || s.ID == "" {
		t.Fatal("empty session fields")
	}
	row, err := m.Validate(ctx, s.ID, s.Token, "1.1.1.1", true)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if row.ID != s.ID {
		t.Error("row ID mismatch")
	}
}

func TestValidateWrongToken(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, time.Hour)
	ctx := context.Background()
	db.UpsertDevice(database.Device{ID: "d1", Name: "x", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	s, _ := m.Create(ctx, "d1", "1.1.1.1")
	_, err := m.Validate(ctx, s.ID, "wrong", "1.1.1.1", false)
	if !errors.Is(err, ErrInvalid) {
		t.Errorf("want ErrInvalid, got %v", err)
	}
}

func TestSessionExpiry(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, time.Hour)
	m.now = func() time.Time { return time.Unix(1000, 0) }
	ctx := context.Background()
	db.UpsertDevice(database.Device{ID: "d1", Name: "x", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	s, _ := m.Create(ctx, "d1", "1.1.1.1")
	// Advance past expiry.
	m.now = func() time.Time { return time.Unix(1000, 0).Add(2 * time.Hour) }
	_, err := m.Validate(ctx, s.ID, s.Token, "1.1.1.1", false)
	if !errors.Is(err, ErrExpired) {
		t.Errorf("want ErrExpired, got %v", err)
	}
}

func TestSessionRevoke(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, time.Hour)
	ctx := context.Background()
	db.UpsertDevice(database.Device{ID: "d1", Name: "x", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	s, _ := m.Create(ctx, "d1", "1.1.1.1")
	if err := m.Revoke(ctx, s.ID); err != nil {
		t.Fatal(err)
	}
	_, err := m.Validate(ctx, s.ID, s.Token, "1.1.1.1", false)
	if !errors.Is(err, ErrRevoked) {
		t.Errorf("want ErrRevoked, got %v", err)
	}
}

func TestRevokeAll(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, time.Hour)
	ctx := context.Background()
	db.UpsertDevice(database.Device{ID: "d1", Name: "x", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	s1, _ := m.Create(ctx, "d1", "")
	s2, _ := m.Create(ctx, "d1", "")
	n, err := m.RevokeAll(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Errorf("revoked %d, want 2", n)
	}
	for _, sid := range []string{s1.ID, s2.ID} {
		_, err := m.Validate(ctx, sid, "x", "", false)
		if !errors.Is(err, ErrRevoked) && !errors.Is(err, ErrInvalid) {
			t.Errorf("post-revoke validate: %v", err)
		}
	}
}

func TestIPMismatch(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, time.Hour)
	ctx := context.Background()
	db.UpsertDevice(database.Device{ID: "d1", Name: "x", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	s, _ := m.Create(ctx, "d1", "1.1.1.1")
	_, err := m.Validate(ctx, s.ID, s.Token, "2.2.2.2", true)
	if !errors.Is(err, ErrIPMismatch) {
		t.Errorf("want ErrIPMismatch, got %v", err)
	}
	// With enforceIP=false it should still pass.
	_, err = m.Validate(ctx, s.ID, s.Token, "2.2.2.2", false)
	if err != nil {
		t.Errorf("enforceIP=false should pass: %v", err)
	}
}
