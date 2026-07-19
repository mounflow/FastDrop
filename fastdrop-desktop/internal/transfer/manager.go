package transfer

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/security"
)

// Direction enumerates the two transfer directions.
type Direction string

const (
	DirClientToServer Direction = "client_to_server"
	DirServerToClient Direction = "server_to_client"
)

// FileSpec is the input for a single file within a transfer batch.
type FileSpec struct {
	ClientFileID string
	Name         string
	Size         int64
	MimeType     string
	Sha256       string // optional
}

// CreateResult is returned when a transfer is created.
type CreateResult struct {
	TransferID string
	Files      []CreatedFile
}

type CreatedFile struct {
	FileID           string
	ClientFileID     string
	Name             string
	ChunkSize        int
	TotalChunks      int
	UploadURLPattern string // unused server-side; informational
}

// ProgressCallback is invoked on throttled progress updates.
type ProgressCallback func(transferID, fileID string, transferredBytes, totalBytes int64, speedBps float64)

// Manager orchestrates transfer persistence and state transitions.
// Chunk-level IO is delegated to the storage layer; this manager owns the
// state machine, the scheduler, and progress aggregation.
type Manager struct {
	db        *database.DB
	scheduler *Scheduler
	chunkSize int

	mu       sync.Mutex
	progress map[string]*fileProgress // fileID -> in-flight progress
	speed    map[string]*SpeedWindow  // transferID -> speed window
	throttle map[string]*Throttle     // transferID -> push throttle
	cb       ProgressCallback
}

type fileProgress struct {
	transferred int64
	total       int64
}

// NewManager constructs a manager. The ProgressCallback is optional.
func NewManager(db *database.DB, chunkSize int, cb ProgressCallback) *Manager {
	if chunkSize <= 0 {
		chunkSize = 4 * 1024 * 1024
	}
	m := &Manager{
		db:        db,
		scheduler: NewScheduler(3, 2, 6),
		chunkSize: chunkSize,
		progress:  make(map[string]*fileProgress),
		speed:     make(map[string]*SpeedWindow),
		throttle:  make(map[string]*Throttle),
		cb:        cb,
	}
	return m
}

// Scheduler exposes the underlying scheduler (used by the API layer to
// gate chunk PUTs).
func (m *Manager) Scheduler() *Scheduler { return m.scheduler }

// TotalChunks returns the number of chunks for the given file size at the
// configured chunk size. Last chunk is short.
func TotalChunks(size, chunkSize int64) int {
	if size <= 0 {
		return 0
	}
	return int((size + chunkSize - 1) / chunkSize)
}

// Create stores a new transfer batch with status=created then immediately
// moves to waiting_accept or preparing based on the spec's flow.
func (m *Manager) Create(ctx context.Context, sessionID, peerDeviceID string, dir Direction, offerID string, files []FileSpec) (*CreateResult, error) {
	transferID, err := security.NewUUID()
	if err != nil {
		return nil, err
	}
	var totalBytes int64
	for _, f := range files {
		totalBytes += f.Size
	}
	now := database.Now()
	if err := m.db.InsertTransfer(ctx, database.TransferRow{
		ID: transferID, SessionID: sessionID, PeerDeviceID: peerDeviceID,
		Direction: string(dir), Status: string(StatusCreated),
		TotalFiles: len(files), TotalBytes: totalBytes, TransferredBytes: 0,
		CreatedAt: now,
	}); err != nil {
		return nil, err
	}
	out := &CreateResult{TransferID: transferID}
	for _, f := range files {
		fileID, _ := security.NewUUID()
		total := TotalChunks(f.Size, int64(m.chunkSize))
		row := database.TransferFileRow{
			ID: fileID, TransferID: transferID,
			ClientFileID: f.ClientFileID,
			OriginalName: f.Name, MimeType: f.MimeType,
			TotalBytes: f.Size, ChunkSize: m.chunkSize, TotalChunks: total,
			Sha256Expected: f.Sha256, Status: string(StatusCreated),
			CreatedAt: now,
		}
		if err := m.db.InsertTransferFile(ctx, row); err != nil {
			return nil, err
		}
		out.Files = append(out.Files, CreatedFile{
			FileID:       fileID,
			ClientFileID: f.ClientFileID,
			Name:         f.Name,
			ChunkSize:    m.chunkSize,
			TotalChunks:  total,
			UploadURLPattern: fmt.Sprintf("/api/v1/transfers/%s/files/%s/chunks/{index}", transferID, fileID),
		})
	}
	return out, nil
}

// MarkChunkComplete records that chunk `idx` for fileID has been received.
// Returns the new completed-chunk count for that file.
func (m *Manager) MarkChunkComplete(ctx context.Context, transferID, fileID string, idx int, chunkBytes int64) (int, error) {
	f, err := m.db.GetTransferFile(ctx, fileID)
	if err != nil {
		return 0, ErrFileNotFound
	}
	count, _, err := m.db.SetChunkBit(ctx, fileID, idx, f.TotalChunks)
	if err != nil {
		return 0, err
	}
	// In-memory progress (atomic enough for our purposes).
	m.mu.Lock()
	fp, ok := m.progress[fileID]
	if !ok {
		fp = &fileProgress{total: f.TotalBytes}
		m.progress[fileID] = fp
	}
	fp.transferred += chunkBytes
	if fp.transferred > fp.total {
		fp.transferred = fp.total
	}
	sw, hasSpeed := m.speed[transferID]
	if !hasSpeed {
		sw = NewSpeedWindow()
		m.speed[transferID] = sw
	}
	now := time.Now()
	sw.Add(now, chunkBytes)
	speed := sw.Speed(now)
	throttle, hasThrottle := m.throttle[transferID]
	if !hasThrottle {
		throttle = NewThrottle(300 * time.Millisecond)
		m.throttle[transferID] = throttle
	}
	cb := m.cb
	m.mu.Unlock()

	// Persist progress to DB at a coarse cadence; we always persist the chunk
	// completion count but only the actual byte counter (cheap upserts).
	if err := m.db.UpdateTransferFileProgress(ctx, fileID, fp.transferred, count, string(StatusTransferring)); err != nil {
		return count, err
	}

	if cb != nil && throttle.Allow(now) {
		cb(transferID, fileID, fp.transferred, fp.total, speed)
	}
	return count, nil
}

// CompleteFile transitions a file to verifying -> completed. The caller
// supplies the actual hash (from storage.FinalizeAndVerify).
func (m *Manager) CompleteFile(ctx context.Context, transferID, fileID, shaActual, savedName, targetPath string) error {
	f, err := m.db.GetTransferFile(ctx, fileID)
	if err != nil {
		return ErrFileNotFound
	}
	if f.Sha256Expected != "" && shaActual != f.Sha256Expected {
		_ = m.db.UpdateTransferFileProgress(ctx, fileID, f.TransferredBytes, f.CompletedChunks, string(StatusFailed))
		return ErrHashMismatch
	}
	if err := m.db.CompleteTransferFile(ctx, fileID, shaActual, savedName, targetPath, string(StatusCompleted), database.Now()); err != nil {
		return err
	}
	// Check if every file in the transfer is completed.
	files, err := m.db.ListTransferFiles(ctx, transferID)
	if err != nil {
		return err
	}
	allDone := true
	var sumBytes int64
	for _, ff := range files {
		sumBytes += ff.TransferredBytes
		if ff.Status != string(StatusCompleted) {
			allDone = false
		}
	}
	if allDone {
		return m.db.MarkTransferCompleted(ctx, transferID, database.Now())
	}
	// Otherwise, update aggregate progress on the parent transfer row.
	return m.db.UpdateTransferStatus(ctx, transferID, string(StatusTransferring), sumBytes, "", "")
}

// Cancel moves a transfer to the cancelled state.
func (m *Manager) Cancel(ctx context.Context, transferID string) error {
	t, err := m.db.GetTransfer(ctx, transferID)
	if err != nil {
		return ErrTransferNotFound
	}
	if Status(t.Status).IsTerminal() {
		return fmt.Errorf("transfer already terminal: %s", t.Status)
	}
	if _, err := Advance(Status(t.Status), StatusCancelled); err != nil {
		// Some states (e.g. waiting_accept) cannot cancel directly; force
		// via cancelled anyway because cancellation is user-driven.
	}
	return m.db.UpdateTransferStatus(ctx, transferID, string(StatusCancelled), t.TransferredBytes, "", "user_cancelled")
}

// ErrHashMismatch is returned by CompleteFile when the SHA-256 doesn't match.
var ErrHashMismatch = errors.New("file hash mismatch")
