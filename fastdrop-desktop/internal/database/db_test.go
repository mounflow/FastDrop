package database

import (
	"context"
	"path/filepath"
	"sort"
	"testing"
)

func newTestDB(t *testing.T) *DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	db, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestOpenAndMigrate(t *testing.T) {
	db := newTestDB(t)
	// Schema applied: tables exist.
	var name string
	err := db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name='devices'`).Scan(&name)
	if err != nil {
		t.Fatalf("devices table missing: %v", err)
	}
	for _, table := range []string{"sessions", "transfers", "transfer_files", "file_chunk_states"} {
		err := db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name)
		if err != nil {
			t.Errorf("table %s missing: %v", table, err)
		}
	}
}

func TestUpsertAndGetDevice(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	dev := Device{ID: "dev-1", Name: "Phone", Platform: "android", AppVersion: "0.1.0", LastIP: "10.0.0.5", FirstSeenAt: 100, LastSeenAt: 100}
	if err := db.UpsertDevice(dev); err != nil {
		t.Fatal(err)
	}
	// Upsert again with new last_seen.
	dev.LastSeenAt = 200
	dev.LastIP = "10.0.0.9"
	if err := db.UpsertDevice(dev); err != nil {
		t.Fatal(err)
	}
	got, err := db.GetDevice(ctx, "dev-1")
	if err != nil {
		t.Fatal(err)
	}
	if got.LastSeenAt != 200 || got.LastIP != "10.0.0.9" {
		t.Errorf("upsert didn't refresh: %+v", got)
	}
}

func TestSessionLifecycle(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	if err := db.UpsertDevice(Device{ID: "d1", Name: "x", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1}); err != nil {
		t.Fatal(err)
	}
	s := SessionRow{ID: "s1", DeviceID: "d1", TokenHash: "hash", SourceIP: "1.2.3.4", CreatedAt: 1, ExpiresAt: 999}
	if err := db.InsertSession(s); err != nil {
		t.Fatal(err)
	}
	got, err := db.GetSession(ctx, "s1")
	if err != nil {
		t.Fatal(err)
	}
	if got.TokenHash != "hash" || got.SourceIP != "1.2.3.4" {
		t.Errorf("unexpected session: %+v", got)
	}
	if got.RevokedAt.Valid {
		t.Error("new session is revoked")
	}
	if err := db.RevokeSession(ctx, "s1"); err != nil {
		t.Fatal(err)
	}
	got, _ = db.GetSession(ctx, "s1")
	if !got.RevokedAt.Valid {
		t.Error("RevokeSession did not set revoked_at")
	}
}

func TestRevokeAllSessions(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	db.UpsertDevice(Device{ID: "d", Name: "x", Platform: "p", FirstSeenAt: 1, LastSeenAt: 1})
	for i, sid := range []string{"s1", "s2", "s3"} {
		db.InsertSession(SessionRow{ID: sid, DeviceID: "d", TokenHash: "h", CreatedAt: int64(i), ExpiresAt: 9999})
	}
	n, err := db.RevokeAllSessions(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Errorf("revoked %d, want 3", n)
	}
	// Idempotent.
	n, _ = db.RevokeAllSessions(ctx)
	if n != 0 {
		t.Errorf("second call revoked %d, want 0", n)
	}
}

func TestChunkBitmap(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	const total = 30
	// Mark chunks 0, 5, 29 out of order.
	for _, idx := range []int{29, 0, 5, 0} { // 0 twice to test idempotency
		count, isNew, err := db.SetChunkBit(ctx, "file-x", idx, total)
		if err != nil {
			t.Fatal(err)
		}
		_ = count
		_ = isNew
	}
	bm, err := db.GetChunkBitmap(ctx, "file-x", total)
	if err != nil {
		t.Fatal(err)
	}
	completed := CompletedChunkIndices(bm, total)
	sort.Ints(completed)
	want := []int{0, 5, 29}
	if len(completed) != 3 || completed[0] != 0 || completed[1] != 5 || completed[2] != 29 {
		t.Errorf("completed = %v, want %v", completed, want)
	}
	// Idempotency: marking 0 again does not increment count.
	before := len(completed)
	count, isNew, _ := db.SetChunkBit(ctx, "file-x", 0, total)
	if isNew || count != before {
		t.Errorf("idempotent re-mark: count=%d isNew=%v", count, isNew)
	}
	// Out of range rejected.
	_, _, err = db.SetChunkBit(ctx, "file-x", total, total)
	if err == nil {
		t.Error("expected error on out-of-range chunk")
	}
}

func TestMissingChunkIndices(t *testing.T) {
	total := 16
	bm := make([]byte, 2)
	bm[0] = 0b00000101 // chunks 0 and 2
	missing := MissingChunkIndices(bm, total)
	if len(missing) != 14 {
		t.Errorf("missing = %d, want 14", len(missing))
	}
}

func TestTransferInsertAndList(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()
	for _, id := range []string{"t1", "t2"} {
		err := db.InsertTransfer(ctx, TransferRow{
			ID: id, SessionID: "s1", PeerDeviceID: "d1",
			Direction: "client_to_server", Status: "transferring",
			TotalFiles: 1, TotalBytes: 100, TransferredBytes: 0,
			CreatedAt: 1,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	got, err := db.ListTransfersForSession(ctx, "s1")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Errorf("got %d, want 2", len(got))
	}
}
