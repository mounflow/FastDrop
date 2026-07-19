// Package storage owns on-disk file handling: temp .part files, WriteAt
// chunk writes, SHA-256 verification, atomic rename, disk-space checks
// (spec §10, §16, §17, §18).
package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"fastdrop-desktop/internal/security"
)

// TempSubdir is the temp-file sandbox under Downloads (spec §17, §10.2).
const TempSubdir = ".fastdrop-temp"

// Manager handles file IO under a fixed downloads directory.
type Manager struct {
	downloadDir string
	mu          sync.Mutex
	openFiles   map[string]*os.File // fileId -> handle for the active .part
}

func NewManager(downloadDir string) (*Manager, error) {
	abs, err := filepath.Abs(downloadDir)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir download dir: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(abs, TempSubdir), 0o755); err != nil {
		return nil, fmt.Errorf("mkdir temp: %w", err)
	}
	return &Manager{downloadDir: abs, openFiles: make(map[string]*os.File)}, nil
}

// DownloadDir returns the absolute downloads path.
func (m *Manager) DownloadDir() string { return m.downloadDir }

// TempDir returns the .fastdrop-temp path.
func (m *Manager) TempDir() string { return filepath.Join(m.downloadDir, TempSubdir) }

// HasSpaceFor returns true if the volume containing the download directory
// has at least `size + max(100MB, size*5%)` bytes free. Spec §18.
func (m *Manager) HasSpaceFor(size int64) (bool, int64, error) {
	required := size + safetyMargin(size)
	free, err := diskFreeBytes(m.downloadDir)
	if err != nil {
		return false, 0, err
	}
	return free >= required, free, nil
}

func safetyMargin(size int64) int64 {
	const hundredMB = 100 * 1024 * 1024
	fivePct := size / 20
	if fivePct > hundredMB {
		return fivePct
	}
	return hundredMB
}

// PartPath returns the absolute path for a transfer's .part file.
func (m *Manager) PartPath(transferID, fileID string) string {
	return filepath.Join(m.TempDir(), transferID, fileID+".part")
}

// CreatePart creates (or truncates) the .part file, preallocating it to
// totalSize if supported by the platform.
func (m *Manager) CreatePart(transferID, fileID string, totalSize int64) error {
	dir := filepath.Join(m.TempDir(), transferID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := m.PartPath(transferID, fileID)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if totalSize > 0 {
		// Preallocate to reduce fragmentation. Errors here are non-fatal —
		// the file will grow on WriteAt regardless.
		_ = f.Truncate(totalSize)
	}
	return nil
}

// WriteChunk writes `data` at offset `chunkIndex * chunkSize` in the .part
// file. Multiple concurrent chunks within the same file are safe because
// WriteAt is goroutine-safe at the OS level (no shared file pointer).
func (m *Manager) WriteChunk(transferID, fileID string, chunkIndex, chunkSize int, data []byte) (int, error) {
	m.mu.Lock()
	f, ok := m.openFiles[fileID]
	m.mu.Unlock()
	open := true
	if !ok {
		path := m.PartPath(transferID, fileID)
		var err error
		f, err = os.OpenFile(path, os.O_RDWR, 0o644)
		if err != nil {
			// Lazily-created part file via CreatePart is expected. If it
			// doesn't exist, return the error to the caller.
			return 0, err
		}
		open = false // we open per-write; no need to track it
	}
	if !open {
		defer f.Close()
	}
	offset := int64(chunkIndex) * int64(chunkSize)
	n, err := f.WriteAt(data, offset)
	if err != nil {
		return n, err
	}
	return n, nil
}

// FinalizeAndVerify verifies the SHA-256 of the .part file against the
// sender-supplied expectedSha (optional), then atomically renames to the
// final download path with rename-on-conflict resolution.
//
// Returns the absolute saved path.
//
// If expectedSha is empty, hash verification is skipped (caller-discipline).
func (m *Manager) FinalizeAndVerify(ctx context.Context, transferID, fileID, originalName, expectedSha, conflictPolicy string) (string, string, error) {
	partPath := m.PartPath(transferID, fileID)
	f, err := os.Open(partPath)
	if err != nil {
		return "", "", err
	}
	actualSha, err := security.HashReader(f)
	f.Close()
	if err != nil {
		return "", "", err
	}
	if expectedSha != "" && actualSha != expectedSha {
		return "", actualSha, ErrHashMismatch
	}

	safeName := security.SanitizeFilename(originalName)
	finalName := security.ResolveConflict(m.downloadDir, safeName, conflictPolicy, fileExists)
	if finalName == "" {
		// "skip" policy and target exists: remove the .part, return no-op.
		_ = os.Remove(partPath)
		return "", actualSha, ErrSkipConflict
	}
	finalPath := filepath.Join(m.downloadDir, finalName)
	// Atomic-ish rename. Windows does not atomic-rename over an existing
	// file, but ResolveConflict guarantees finalName is unused.
	if err := os.Rename(partPath, finalPath); err != nil {
		return "", actualSha, err
	}
	// Best-effort: drop the (now empty) per-transfer temp dir.
	_ = os.Remove(filepath.Dir(partPath))
	return finalPath, actualSha, nil
}

// ReadChunk opens the .part file and returns a byte range. Used for resume.
func (m *Manager) ReadChunk(transferID, fileID string, offset, length int64) (io.ReadCloser, error) {
	path := m.PartPath(transferID, fileID)
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		f.Close()
		return nil, err
	}
	return &chunkReader{f: f, remaining: length}, nil
}

type chunkReader struct {
	f        *os.File
	remaining int64
}

func (c *chunkReader) Read(p []byte) (int, error) {
	if c.remaining <= 0 {
		return 0, io.EOF
	}
	if int64(len(p)) > c.remaining {
		p = p[:c.remaining]
	}
	n, err := c.f.Read(p)
	c.remaining -= int64(n)
	if c.remaining <= 0 && err == nil {
		err = io.EOF
	}
	return n, err
}

func (c *chunkReader) Close() error { return c.f.Close() }

// CleanupTransfer removes the temp directory of a transfer (e.g. on cancel).
func (m *Manager) CleanupTransfer(transferID string) error {
	return os.RemoveAll(filepath.Join(m.TempDir(), transferID))
}

// diskFreeBytes returns the bytes available on the volume containing path.
func diskFreeBytes(path string) (int64, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return 0, err
	}
	return freeBytesWindows(abs)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// Errors.
var (
	ErrHashMismatch  = errors.New("file hash mismatch")
	ErrSkipConflict  = errors.New("file already exists (skip policy)")
)
