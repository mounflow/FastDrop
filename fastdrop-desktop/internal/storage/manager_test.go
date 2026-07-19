package storage

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newMgr(t *testing.T) *Manager {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "Downloads", "FastDrop")
	m, err := NewManager(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { /* tmpdir auto-cleaned */ })
	return m
}

func TestCreateAndWriteChunk(t *testing.T) {
	m := newMgr(t)
	if err := m.CreatePart("t1", "f1", 1024); err != nil {
		t.Fatal(err)
	}
	data := []byte("hello")
	if _, err := m.WriteChunk("t1", "f1", 0, 16, data); err != nil {
		t.Fatal(err)
	}
	// Verify by reading the file directly.
	got, err := os.ReadFile(m.PartPath("t1", "f1"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got[:len(data)]) != "hello" {
		t.Errorf("got %q", got[:len(data)])
	}
}

func TestWriteChunkOffset(t *testing.T) {
	m := newMgr(t)
	m.CreatePart("t1", "f1", 100)
	// Write chunk 2 with chunkSize 10 -> offset 20.
	m.WriteChunk("t1", "f1", 2, 10, []byte("XYZ"))
	got, _ := os.ReadFile(m.PartPath("t1", "f1"))
	if string(got[20:23]) != "XYZ" {
		t.Errorf("offset write failed: %q", got[20:23])
	}
}

func TestHasSpaceFor(t *testing.T) {
	m := newMgr(t)
	ok, free, err := m.HasSpaceFor(1024)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Errorf("insufficient free space for 1KB (free=%d)", free)
	}
	// Asking for absurd space should fail.
	ok, _, _ = m.HasSpaceFor(1 << 60)
	if ok {
		t.Error("expected HasSpaceFor(1<<60) = false")
	}
}

func TestFinalizeHashMismatch(t *testing.T) {
	m := newMgr(t)
	m.CreatePart("t1", "f1", 0)
	m.WriteChunk("t1", "f1", 0, 16, []byte("data"))
	_, _, err := m.FinalizeAndVerify(context.Background(), "t1", "f1", "f.bin", "deadbeef", "rename")
	if err != ErrHashMismatch {
		t.Errorf("want ErrHashMismatch, got %v", err)
	}
}

func TestFinalizeAtomicRename(t *testing.T) {
	m := newMgr(t)
	data := []byte("hello world")
	m.CreatePart("t1", "f1", 0)
	m.WriteChunk("t1", "f1", 0, 16, data)

	// Compute expected sha for verification.
	path, sha, err := m.FinalizeAndVerify(context.Background(), "t1", "f1", "greeting.txt", "", "rename")
	if err != nil {
		t.Fatalf("finalize: %v", err)
	}
	if sha == "" {
		t.Error("no sha returned")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Errorf("content mismatch: %q", got)
	}
	if !strings.HasSuffix(path, "greeting.txt") {
		t.Errorf("final path: %s", path)
	}
	// Part file must be gone.
	if _, err := os.Stat(m.PartPath("t1", "f1")); !os.IsNotExist(err) {
		t.Errorf("part file still exists: %v", err)
	}
}

func TestFinalizeRenameOnConflict(t *testing.T) {
	m := newMgr(t)
	// Pre-place a file with the same name.
	first := filepath.Join(m.downloadDir, "dup.txt")
	os.WriteFile(first, []byte("old"), 0o644)

	data := []byte("new")
	m.CreatePart("t1", "f1", 0)
	m.WriteChunk("t1", "f1", 0, 16, data)
	path, _, err := m.FinalizeAndVerify(context.Background(), "t1", "f1", "dup.txt", "", "rename")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(path, "dup (1).txt") {
		t.Errorf("expected dup (1).txt, got %s", path)
	}
	// Original file untouched.
	got, _ := os.ReadFile(first)
	if string(got) != "old" {
		t.Error("conflict policy overwrote existing file")
	}
}

func TestSanitizeAppliedToSavedName(t *testing.T) {
	m := newMgr(t)
	m.CreatePart("t1", "f1", 0)
	m.WriteChunk("t1", "f1", 0, 16, []byte("x"))
	path, _, err := m.FinalizeAndVerify(context.Background(), "t1", "f1", "../etc/passwd", "", "rename")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(path, "passwd") {
		t.Errorf("path traversal escaped: %s", path)
	}
	// Confirm the file lives inside the download dir.
	if !strings.HasPrefix(path, m.downloadDir) {
		t.Errorf("file written outside download dir: %s", path)
	}
}

func TestCleanupTransfer(t *testing.T) {
	m := newMgr(t)
	m.CreatePart("t1", "f1", 0)
	if err := m.CleanupTransfer("t1"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(m.TempDir(), "t1")); !os.IsNotExist(err) {
		t.Error("temp dir not removed")
	}
}
