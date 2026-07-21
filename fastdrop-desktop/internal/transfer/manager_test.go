package transfer

import (
	"context"
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
	db.UpsertDevice(database.Device{ID: "d1", Name: "x", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	db.InsertSession(database.SessionRow{ID: "s1", DeviceID: "d1", TokenHash: "h", CreatedAt: 1, ExpiresAt: 9999999})
	return db
}

// State machine tests.
func TestLegalTransitions(t *testing.T) {
	legal := []struct{ from, to Status }{
		{StatusCreated, StatusWaitingAccept},
		{StatusWaitingAccept, StatusPreparing},
		{StatusPreparing, StatusTransferring},
		{StatusTransferring, StatusPaused},
		{StatusPaused, StatusTransferring},
		{StatusTransferring, StatusRetrying},
		{StatusRetrying, StatusTransferring},
		{StatusTransferring, StatusVerifying},
		{StatusVerifying, StatusCompleted},
		{StatusVerifying, StatusFailed},
		{StatusTransferring, StatusCancelled},
	}
	for _, c := range legal {
		if !CanTransition(c.from, c.to) {
			t.Errorf("expected legal: %s -> %s", c.from, c.to)
		}
	}
}

func TestIllegalTransitions(t *testing.T) {
	illegal := []struct{ from, to Status }{
		{StatusCreated, StatusTransferring},
		{StatusCompleted, StatusTransferring},
		{StatusCancelled, StatusTransferring},
		{StatusRejected, StatusPreparing},
		{StatusWaitingAccept, StatusCompleted},
	}
	for _, c := range illegal {
		if CanTransition(c.from, c.to) {
			t.Errorf("expected illegal: %s -> %s", c.from, c.to)
		}
	}
}

func TestAdvance(t *testing.T) {
	if _, err := Advance(StatusCreated, StatusWaitingAccept); err != nil {
		t.Errorf("legal advance: %v", err)
	}
	if _, err := Advance(StatusCompleted, StatusTransferring); err == nil {
		t.Error("illegal advance should fail")
	}
}

func TestIsTerminal(t *testing.T) {
	for _, s := range []Status{StatusCompleted, StatusFailed, StatusCancelled, StatusRejected} {
		if !s.IsTerminal() {
			t.Errorf("%s should be terminal", s)
		}
	}
	for _, s := range []Status{StatusCreated, StatusTransferring, StatusPaused} {
		if s.IsTerminal() {
			t.Errorf("%s should not be terminal", s)
		}
	}
}

// Chunk arithmetic.
func TestTotalChunks(t *testing.T) {
	const mb = 4 * 1024 * 1024
	cases := []struct{ size, chunk int64; want int }{
		{0, mb, 0},
		{1, mb, 1},
		{mb, mb, 1},
		{mb + 1, mb, 2},
		{10 * mb, mb, 10},
	}
	for _, c := range cases {
		got := TotalChunks(c.size, c.chunk)
		if got != c.want {
			t.Errorf("TotalChunks(%d, %d) = %d, want %d", c.size, c.chunk, got, c.want)
		}
	}
}

// Scheduler tests.
func TestSchedulerAcquireRelease(t *testing.T) {
	s := NewScheduler(3, 2, 6)
	ctx := context.Background()
	// Acquire across two files to respect per-file cap of 3.
	for i := 0; i < 6; i++ {
		fid := "f1"
		if i >= 3 {
			fid = "f2"
		}
		if err := s.Acquire(ctx, fid); err != nil {
			t.Fatalf("acquire %d: %v", i, err)
		}
	}
	// 7th (any file) should block since global max is 6.
	done := make(chan error, 1)
	go func() {
		done <- s.Acquire(ctx, "f1")
		s.Release("f1")
	}()
	select {
	case <-done:
		t.Error("7th acquire unexpectedly succeeded before release")
	case <-time.After(50 * time.Millisecond):
		// expected
	}
	s.Release("f1")
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("post-release acquire: %v", err)
		}
	case <-time.After(1 * time.Second):
		t.Error("acquire never succeeded after release")
	}
}

func TestSchedulerCancelContext(t *testing.T) {
	s := NewScheduler(3, 2, 6)
	ctx, cancel := context.WithCancel(context.Background())
	// Saturate across two files.
	for i := 0; i < 6; i++ {
		fid := "f1"
		if i >= 3 {
			fid = "f2"
		}
		s.Acquire(ctx, fid)
	}
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	err := s.Acquire(ctx, "f1")
	if err == nil {
		t.Error("expected ctx-canceled acquire to return error")
	}
}

// Retry strategy.
func TestBackoffSchedule(t *testing.T) {
	r := DefaultRetryStrategy()
	want := []time.Duration{
		500 * time.Millisecond, 1 * time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second,
	}
	for i, w := range want {
		got, err := r.BackoffFor(i + 1)
		if err != nil {
			t.Fatalf("attempt %d: %v", i+1, err)
		}
		if got != w {
			t.Errorf("attempt %d: got %v, want %v", i+1, got, w)
		}
	}
	if _, err := r.BackoffFor(6); err == nil {
		t.Error("6th attempt should exceed MaxAttempts")
	}
}

// Speed window.
func TestSpeedWindow(t *testing.T) {
	w := NewSpeedWindow()
	t0 := time.Unix(0, 0)
	w.Add(t0, 1000)
	w.Add(t0.Add(1*time.Second), 1000)
	w.Add(t0.Add(2*time.Second), 1000)
	speed := w.Speed(t0.Add(2 * time.Second))
	if speed < 999 || speed > 1001 {
		t.Errorf("speed = %f, want ~1000 B/s", speed)
	}
	// After 3s window slides, the early samples evict.
	speed2 := w.Speed(t0.Add(10 * time.Second))
	if speed2 != 0 {
		t.Errorf("stale window speed = %f, want 0", speed2)
	}
}

// Throttle.
func TestThrottleAllowsAtMostPerInterval(t *testing.T) {
	th := NewThrottle(100 * time.Millisecond)
	t0 := time.Unix(0, 0)
	if !th.Allow(t0) {
		t.Error("first call should allow")
	}
	if th.Allow(t0.Add(50 * time.Millisecond)) {
		t.Error("second call within interval should not allow")
	}
	if !th.Allow(t0.Add(150 * time.Millisecond)) {
		t.Error("third call after interval should allow")
	}
}

// Manager CRUD.
func TestManagerCreate(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, 4*1024*1024, nil)
	ctx := context.Background()
	files := []FileSpec{
		{ClientFileID: "c1", Name: "a.txt", Size: 100},
		{ClientFileID: "c2", Name: "b.txt", Size: 4*1024*1024 + 1},
	}
	res, err := m.Create(ctx, "s1", "d1", DirClientToServer, "offer-x", files)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Files) != 2 {
		t.Fatalf("got %d files", len(res.Files))
	}
	if res.Files[1].TotalChunks != 2 {
		t.Errorf("total chunks for ~4MB+1B file = %d, want 2", res.Files[1].TotalChunks)
	}
	// Verify persisted.
	t1, _ := db.GetTransfer(ctx, res.TransferID)
	if t1.TotalBytes != 100+(4*1024*1024+1) || t1.TotalFiles != 2 {
		t.Errorf("bad transfer totals: %+v", t1)
	}
}

func TestManagerMarkChunkCompleteAndProgress(t *testing.T) {
	db := newDB(t)
	var pushed bool
	cb := func(transferID, fileID string, tr, total int64, sp float64) { pushed = true }
	m := NewManager(db, 4*1024*1024, cb)
	ctx := context.Background()
	res, _ := m.Create(ctx, "s1", "d1", DirClientToServer, "o", []FileSpec{{ClientFileID: "c", Name: "a.bin", Size: 100}})
	fileID := res.Files[0].FileID
	transferID := res.TransferID

	count, justStarted, err := m.MarkChunkComplete(ctx, transferID, fileID, 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Errorf("count = %d, want 1", count)
	}
	if !justStarted {
		t.Error("first chunk should set justStarted=true")
	}
	if !pushed {
		t.Error("progress callback not invoked")
	}
	// Idempotency on byte counter (caller is responsible for not double-counting
	// in production, but the DB bitmap is idempotent at the chunk level).
}

func TestManagerCancel(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, 4*1024*1024, nil)
	ctx := context.Background()
	res, _ := m.Create(ctx, "s1", "d1", DirClientToServer, "o", []FileSpec{{ClientFileID: "c", Name: "a", Size: 10}})
	if err := m.Cancel(ctx, res.TransferID); err != nil {
		t.Fatal(err)
	}
	t1, _ := db.GetTransfer(ctx, res.TransferID)
	if t1.Status != string(StatusCancelled) {
		t.Errorf("status = %s", t1.Status)
	}
}

// ---------------------------------------------------------------------------
// CompleteFile tests
// ---------------------------------------------------------------------------

func TestCompleteFileSingleFile(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, 4*1024*1024, nil)
	ctx := context.Background()

	res, err := m.Create(ctx, "s1", "d1", DirClientToServer, "o", []FileSpec{
		{ClientFileID: "c1", Name: "a.txt", Size: 100},
	})
	if err != nil {
		t.Fatal(err)
	}
	tid := res.TransferID
	fid := res.Files[0].FileID

	// Mark the chunk as complete first.
	if _, _, err := m.MarkChunkComplete(ctx, tid, fid, 0, 100); err != nil {
		t.Fatal(err)
	}

	// Complete the file (no expected hash → any hash accepted).
	allDone, err := m.CompleteFile(ctx, tid, fid, "abc123", "a.txt", "/downloads/a.txt")
	if err != nil {
		t.Fatal(err)
	}
	if !allDone {
		t.Error("single file transfer should be allDone")
	}

	// Transfer should be completed.
	tr, _ := db.GetTransfer(ctx, tid)
	if tr.Status != string(StatusCompleted) {
		t.Errorf("transfer status = %s, want completed", tr.Status)
	}

	// File row should be completed with hash.
	f, _ := db.GetTransferFile(ctx, fid)
	if f.Status != string(StatusCompleted) {
		t.Errorf("file status = %s, want completed", f.Status)
	}
	if f.Sha256Actual != "abc123" {
		t.Errorf("file sha256_actual = %s, want abc123", f.Sha256Actual)
	}
}

func TestCompleteFileMultiFile(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, 4*1024*1024, nil)
	ctx := context.Background()

	res, err := m.Create(ctx, "s1", "d1", DirClientToServer, "o", []FileSpec{
		{ClientFileID: "c1", Name: "a.txt", Size: 50},
		{ClientFileID: "c2", Name: "b.txt", Size: 60},
	})
	if err != nil {
		t.Fatal(err)
	}
	tid := res.TransferID
	f1 := res.Files[0].FileID
	f2 := res.Files[1].FileID

	// Complete file 1.
	m.MarkChunkComplete(ctx, tid, f1, 0, 50)
	allDone, err := m.CompleteFile(ctx, tid, f1, "hash1", "a.txt", "/downloads/a.txt")
	if err != nil {
		t.Fatal(err)
	}
	if allDone {
		t.Error("should not be allDone after 1 of 2 files")
	}

	// Transfer should still be transferring.
	tr, _ := db.GetTransfer(ctx, tid)
	if tr.Status != string(StatusTransferring) {
		t.Errorf("transfer status = %s, want transferring", tr.Status)
	}

	// Complete file 2.
	m.MarkChunkComplete(ctx, tid, f2, 0, 60)
	allDone, err = m.CompleteFile(ctx, tid, f2, "hash2", "b.txt", "/downloads/b.txt")
	if err != nil {
		t.Fatal(err)
	}
	if !allDone {
		t.Error("should be allDone after 2 of 2 files")
	}

	tr, _ = db.GetTransfer(ctx, tid)
	if tr.Status != string(StatusCompleted) {
		t.Errorf("transfer status = %s, want completed", tr.Status)
	}
}

func TestCompleteFileHashMismatch(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, 4*1024*1024, nil)
	ctx := context.Background()

	res, _ := m.Create(ctx, "s1", "d1", DirClientToServer, "o", []FileSpec{
		{ClientFileID: "c1", Name: "a.txt", Size: 100, Sha256: "expected_hash"},
	})
	tid := res.TransferID
	fid := res.Files[0].FileID
	m.MarkChunkComplete(ctx, tid, fid, 0, 100)

	// Complete with wrong hash.
	_, err := m.CompleteFile(ctx, tid, fid, "wrong_hash", "a.txt", "/downloads/a.txt")
	if err != ErrHashMismatch {
		t.Errorf("expected ErrHashMismatch, got %v", err)
	}

	// File should be marked failed.
	f, _ := db.GetTransferFile(ctx, fid)
	if f.Status != string(StatusFailed) {
		t.Errorf("file status = %s, want failed", f.Status)
	}
}

func TestCompleteFileNotFound(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, 4*1024*1024, nil)
	ctx := context.Background()

	_, err := m.CompleteFile(ctx, "t1", "nonexistent", "hash", "f.txt", "/f.txt")
	if err != ErrFileNotFound {
		t.Errorf("expected ErrFileNotFound, got %v", err)
	}
}

func TestCancelTerminalTransfer(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, 4*1024*1024, nil)
	ctx := context.Background()

	res, _ := m.Create(ctx, "s1", "d1", DirClientToServer, "o", []FileSpec{
		{ClientFileID: "c1", Name: "a.txt", Size: 10},
	})
	tid := res.TransferID

	// Complete the file to make the transfer terminal.
	m.MarkChunkComplete(ctx, tid, res.Files[0].FileID, 0, 10)
	m.CompleteFile(ctx, tid, res.Files[0].FileID, "h", "a.txt", "/a.txt")

	// Cancel should fail on a completed transfer.
	err := m.Cancel(ctx, tid)
	if err == nil {
		t.Error("cancel on completed transfer should fail")
	}
}

func TestCancelNonexistentTransfer(t *testing.T) {
	db := newDB(t)
	m := NewManager(db, 4*1024*1024, nil)
	ctx := context.Background()

	err := m.Cancel(ctx, "nonexistent")
	if err != ErrTransferNotFound {
		t.Errorf("expected ErrTransferNotFound, got %v", err)
	}
}
