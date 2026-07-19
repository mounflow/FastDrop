// Package database wraps modernc.org/sqlite and exposes CRUD helpers for
// the five FastDrop tables (spec §22).
package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

// SchemaSQL is the canonical 0001 init migration. It mirrors
// migrations/0001_init.sql; we duplicate the SQL here so the binary stays
// self-contained (no file IO needed at runtime).
var SchemaSQL = `
CREATE TABLE IF NOT EXISTS devices (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    platform      TEXT NOT NULL,
    app_version   TEXT,
    last_ip       TEXT,
    first_seen_at INTEGER NOT NULL,
    last_seen_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id          TEXT PRIMARY KEY,
    device_id   TEXT NOT NULL,
    token_hash  TEXT NOT NULL,
    source_ip   TEXT,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL,
    revoked_at  INTEGER,
    FOREIGN KEY(device_id) REFERENCES devices(id)
);

CREATE INDEX IF NOT EXISTS idx_sessions_device ON sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);

CREATE TABLE IF NOT EXISTS transfers (
    id                 TEXT PRIMARY KEY,
    session_id         TEXT,
    peer_device_id     TEXT NOT NULL,
    direction          TEXT NOT NULL,
    status             TEXT NOT NULL,
    total_files        INTEGER NOT NULL,
    total_bytes        INTEGER NOT NULL,
    transferred_bytes  INTEGER NOT NULL DEFAULT 0,
    created_at         INTEGER NOT NULL,
    started_at         INTEGER,
    completed_at       INTEGER,
    error_code         TEXT,
    error_message      TEXT
);

CREATE INDEX IF NOT EXISTS idx_transfers_session ON transfers(session_id);
CREATE INDEX IF NOT EXISTS idx_transfers_status  ON transfers(status);

CREATE TABLE IF NOT EXISTS transfer_files (
    id                  TEXT PRIMARY KEY,
    transfer_id         TEXT NOT NULL,
    client_file_id      TEXT,
    original_name       TEXT NOT NULL,
    saved_name          TEXT,
    source_path         TEXT,
    target_path         TEXT,
    mime_type           TEXT,
    total_bytes         INTEGER NOT NULL,
    transferred_bytes   INTEGER NOT NULL DEFAULT 0,
    chunk_size          INTEGER NOT NULL,
    total_chunks        INTEGER NOT NULL,
    completed_chunks    INTEGER NOT NULL DEFAULT 0,
    sha256_expected     TEXT,
    sha256_actual       TEXT,
    status              TEXT NOT NULL,
    created_at          INTEGER NOT NULL,
    completed_at        INTEGER,
    error_code          TEXT,
    FOREIGN KEY(transfer_id) REFERENCES transfers(id)
);

CREATE INDEX IF NOT EXISTS idx_transfer_files_transfer ON transfer_files(transfer_id);

CREATE TABLE IF NOT EXISTS file_chunk_states (
    file_id            TEXT PRIMARY KEY,
    completed_bitmap   BLOB NOT NULL,
    updated_at         INTEGER NOT NULL
);
`

// DB is a thin wrapper over *sql.DB with FastDrop helpers.
type DB struct {
	*sql.DB
}

// Open creates / opens the SQLite database at path and runs migrations.
func Open(path string) (*DB, error) {
	// Ensure the parent directory exists so a fresh APPDATA works.
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("mkdir db dir: %w", err)
		}
	}
	dsn := "file:" + filepath.ToSlash(path) + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)"
	sqlDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// SQLite serializes writes; a single connection avoids SQLITE_BUSY.
	sqlDB.SetMaxOpenConns(1)
	if err := sqlDB.PingContext(context.Background()); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}
	db := &DB{sqlDB}
	if err := db.Migrate(); err != nil {
		sqlDB.Close()
		return nil, err
	}
	return db, nil
}

// Migrate applies embedded schema if needed.
func (d *DB) Migrate() error {
	_, err := d.Exec(SchemaSQL)
	if err != nil {
		return fmt.Errorf("apply schema: %w", err)
	}
	return nil
}

// Now returns the current Unix timestamp in seconds.
func Now() int64 { return time.Now().Unix() }

// --- devices ---

// Device row.
type Device struct {
	ID          string
	Name        string
	Platform    string
	AppVersion  string
	LastIP      string
	FirstSeenAt int64
	LastSeenAt  int64
}

// UpsertDevice inserts or refreshes last-seen metadata.
func (d *DB) UpsertDevice(dev Device) error {
	_, err := d.Exec(`
INSERT INTO devices (id, name, platform, app_version, last_ip, first_seen_at, last_seen_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
   name = excluded.name,
   platform = excluded.platform,
   app_version = excluded.app_version,
   last_ip = excluded.last_ip,
   last_seen_at = excluded.last_seen_at`,
		dev.ID, dev.Name, dev.Platform, nullableString(dev.AppVersion), nullableString(dev.LastIP),
		dev.FirstSeenAt, dev.LastSeenAt)
	return err
}

// GetDevice fetches a device row by ID.
func (d *DB) GetDevice(ctx context.Context, id string) (*Device, error) {
	row := d.QueryRowContext(ctx, `SELECT id, name, platform, app_version, last_ip, first_seen_at, last_seen_at FROM devices WHERE id = ?`, id)
	var dev Device
	var appVersion, lastIP sql.NullString
	if err := row.Scan(&dev.ID, &dev.Name, &dev.Platform, &appVersion, &lastIP, &dev.FirstSeenAt, &dev.LastSeenAt); err != nil {
		return nil, err
	}
	dev.AppVersion = appVersion.String
	dev.LastIP = lastIP.String
	return &dev, nil
}

// --- sessions ---

// SessionRow is the persisted projection of a session.
type SessionRow struct {
	ID        string
	DeviceID  string
	TokenHash string
	SourceIP  string
	CreatedAt int64
	ExpiresAt int64
	RevokedAt sql.NullInt64
}

// InsertSession persists a session. The caller must hash the token first.
func (d *DB) InsertSession(s SessionRow) error {
	_, err := d.Exec(`INSERT INTO sessions (id, device_id, token_hash, source_ip, created_at, expires_at, revoked_at)
VALUES (?, ?, ?, ?, ?, ?, NULL)`,
		s.ID, s.DeviceID, s.TokenHash, nullableString(s.SourceIP), s.CreatedAt, s.ExpiresAt)
	return err
}

// GetSession looks up a session by ID.
func (d *DB) GetSession(ctx context.Context, id string) (*SessionRow, error) {
	row := d.QueryRowContext(ctx, `SELECT id, device_id, token_hash, source_ip, created_at, expires_at, revoked_at FROM sessions WHERE id = ?`, id)
	var s SessionRow
	var sourceIP sql.NullString
	if err := row.Scan(&s.ID, &s.DeviceID, &s.TokenHash, &sourceIP, &s.CreatedAt, &s.ExpiresAt, &s.RevokedAt); err != nil {
		return nil, err
	}
	s.SourceIP = sourceIP.String
	return &s, nil
}

// RevokeSession marks a session revoked (sets revoked_at).
func (d *DB) RevokeSession(ctx context.Context, id string) error {
	res, err := d.ExecContext(ctx, `UPDATE sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, Now(), id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// RevokeAllSessions marks every session revoked. Used on server restart
// per spec §7.1.
func (d *DB) RevokeAllSessions(ctx context.Context) (int64, error) {
	res, err := d.ExecContext(ctx, `UPDATE sessions SET revoked_at = ? WHERE revoked_at IS NULL`, Now())
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

// DeleteExpiredSessions purges expired sessions older than cutoff.
func (d *DB) DeleteExpiredSessions(ctx context.Context, cutoff int64) (int64, error) {
	res, err := d.ExecContext(ctx, `DELETE FROM sessions WHERE expires_at < ?`, cutoff)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

// --- transfers ---

type TransferRow struct {
	ID                string
	SessionID         string
	PeerDeviceID      string
	Direction         string
	Status            string
	TotalFiles        int
	TotalBytes        int64
	TransferredBytes  int64
	CreatedAt         int64
	StartedAt         sql.NullInt64
	CompletedAt       sql.NullInt64
	ErrorCode         string
	ErrorMessage      string
}

func (d *DB) InsertTransfer(ctx context.Context, t TransferRow) error {
	_, err := d.ExecContext(ctx, `
INSERT INTO transfers (id, session_id, peer_device_id, direction, status, total_files, total_bytes, transferred_bytes, created_at, started_at, completed_at, error_code, error_message)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)`,
		t.ID, nullableString(t.SessionID), t.PeerDeviceID, t.Direction, t.Status,
		t.TotalFiles, t.TotalBytes, t.TransferredBytes, t.CreatedAt,
		nullableString(t.ErrorCode), nullableString(t.ErrorMessage))
	return err
}

func (d *DB) UpdateTransferStatus(ctx context.Context, id, status string, transferred int64, errorCode, errorMsg string) error {
	_, err := d.ExecContext(ctx, `UPDATE transfers SET status = ?, transferred_bytes = ?, error_code = ?, error_message = ? WHERE id = ?`,
		status, transferred, nullableString(errorCode), nullableString(errorMsg), id)
	return err
}

func (d *DB) MarkTransferCompleted(ctx context.Context, id string, completedAt int64) error {
	_, err := d.ExecContext(ctx, `UPDATE transfers SET status = ?, completed_at = ?, error_code = NULL, error_message = NULL WHERE id = ?`,
		"completed", completedAt, id)
	return err
}

func (d *DB) GetTransfer(ctx context.Context, id string) (*TransferRow, error) {
	row := d.QueryRowContext(ctx, `SELECT id, session_id, peer_device_id, direction, status, total_files, total_bytes, transferred_bytes, created_at, started_at, completed_at, error_code, error_message FROM transfers WHERE id = ?`, id)
	var t TransferRow
	var sessionID, errCode, errMsg sql.NullString
	if err := row.Scan(&t.ID, &sessionID, &t.PeerDeviceID, &t.Direction, &t.Status, &t.TotalFiles, &t.TotalBytes, &t.TransferredBytes, &t.CreatedAt, &t.StartedAt, &t.CompletedAt, &errCode, &errMsg); err != nil {
		return nil, err
	}
	t.SessionID = sessionID.String
	t.ErrorCode = errCode.String
	t.ErrorMessage = errMsg.String
	return &t, nil
}

func (d *DB) ListTransfersForSession(ctx context.Context, sessionID string) ([]TransferRow, error) {
	rows, err := d.QueryContext(ctx, `SELECT id, session_id, peer_device_id, direction, status, total_files, total_bytes, transferred_bytes, created_at, started_at, completed_at, error_code, error_message FROM transfers WHERE session_id = ? ORDER BY created_at DESC`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TransferRow
	for rows.Next() {
		var t TransferRow
		var sessionID, errCode, errMsg sql.NullString
		if err := rows.Scan(&t.ID, &sessionID, &t.PeerDeviceID, &t.Direction, &t.Status, &t.TotalFiles, &t.TotalBytes, &t.TransferredBytes, &t.CreatedAt, &t.StartedAt, &t.CompletedAt, &errCode, &errMsg); err != nil {
			return nil, err
		}
		t.SessionID = sessionID.String
		t.ErrorCode = errCode.String
		t.ErrorMessage = errMsg.String
		out = append(out, t)
	}
	return out, rows.Err()
}

// --- transfer_files ---

type TransferFileRow struct {
	ID                string
	TransferID        string
	ClientFileID      string
	OriginalName      string
	SavedName         string
	SourcePath        string
	TargetPath        string
	MimeType          string
	TotalBytes        int64
	TransferredBytes  int64
	ChunkSize         int
	TotalChunks       int
	CompletedChunks   int
	Sha256Expected    string
	Sha256Actual      string
	Status            string
	CreatedAt         int64
	CompletedAt       sql.NullInt64
	ErrorCode         string
}

func (d *DB) InsertTransferFile(ctx context.Context, f TransferFileRow) error {
	_, err := d.ExecContext(ctx, `
INSERT INTO transfer_files (id, transfer_id, client_file_id, original_name, saved_name, source_path, target_path, mime_type, total_bytes, transferred_bytes, chunk_size, total_chunks, completed_chunks, sha256_expected, sha256_actual, status, created_at, completed_at, error_code)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)`,
		f.ID, f.TransferID, nullableString(f.ClientFileID), f.OriginalName, nullableString(f.SavedName),
		nullableString(f.SourcePath), nullableString(f.TargetPath), nullableString(f.MimeType),
		f.TotalBytes, f.TransferredBytes, f.ChunkSize, f.TotalChunks, f.CompletedChunks,
		nullableString(f.Sha256Expected), nullableString(f.Sha256Actual), f.Status, f.CreatedAt, nullableString(f.ErrorCode))
	return err
}

func (d *DB) GetTransferFile(ctx context.Context, fileID string) (*TransferFileRow, error) {
	row := d.QueryRowContext(ctx, `SELECT id, transfer_id, client_file_id, original_name, saved_name, source_path, target_path, mime_type, total_bytes, transferred_bytes, chunk_size, total_chunks, completed_chunks, sha256_expected, sha256_actual, status, created_at, completed_at, error_code FROM transfer_files WHERE id = ?`, fileID)
	var f TransferFileRow
	var clientID, savedName, src, tgt, mime, shaExp, shaAct, errCode sql.NullString
	var completedAt sql.NullInt64
	if err := row.Scan(&f.ID, &f.TransferID, &clientID, &f.OriginalName, &savedName, &src, &tgt, &mime,
		&f.TotalBytes, &f.TransferredBytes, &f.ChunkSize, &f.TotalChunks, &f.CompletedChunks,
		&shaExp, &shaAct, &f.Status, &f.CreatedAt, &completedAt, &errCode); err != nil {
		return nil, err
	}
	f.ClientFileID = clientID.String
	f.SavedName = savedName.String
	f.SourcePath = src.String
	f.TargetPath = tgt.String
	f.MimeType = mime.String
	f.Sha256Expected = shaExp.String
	f.Sha256Actual = shaAct.String
	f.ErrorCode = errCode.String
	f.CompletedAt = completedAt
	return &f, nil
}

func (d *DB) ListTransferFiles(ctx context.Context, transferID string) ([]TransferFileRow, error) {
	rows, err := d.QueryContext(ctx, `SELECT id, transfer_id, client_file_id, original_name, saved_name, source_path, target_path, mime_type, total_bytes, transferred_bytes, chunk_size, total_chunks, completed_chunks, sha256_expected, sha256_actual, status, created_at, completed_at, error_code FROM transfer_files WHERE transfer_id = ? ORDER BY created_at ASC`, transferID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TransferFileRow
	for rows.Next() {
		var f TransferFileRow
		var clientID, savedName, src, tgt, mime, shaExp, shaAct, errCode sql.NullString
		var completedAt sql.NullInt64
		if err := rows.Scan(&f.ID, &f.TransferID, &clientID, &f.OriginalName, &savedName, &src, &tgt, &mime,
			&f.TotalBytes, &f.TransferredBytes, &f.ChunkSize, &f.TotalChunks, &f.CompletedChunks,
			&shaExp, &shaAct, &f.Status, &f.CreatedAt, &completedAt, &errCode); err != nil {
			return nil, err
		}
		f.ClientFileID = clientID.String
		f.SavedName = savedName.String
		f.SourcePath = src.String
		f.TargetPath = tgt.String
		f.MimeType = mime.String
		f.Sha256Expected = shaExp.String
		f.Sha256Actual = shaAct.String
		f.ErrorCode = errCode.String
		f.CompletedAt = completedAt
		out = append(out, f)
	}
	return out, rows.Err()
}

func (d *DB) UpdateTransferFileProgress(ctx context.Context, fileID string, transferred int64, completedChunks int, status string) error {
	_, err := d.ExecContext(ctx, `UPDATE transfer_files SET transferred_bytes = ?, completed_chunks = ?, status = ? WHERE id = ?`,
		transferred, completedChunks, status, fileID)
	return err
}

func (d *DB) CompleteTransferFile(ctx context.Context, fileID, shaActual, savedName, targetPath, status string, completedAt int64) error {
	_, err := d.ExecContext(ctx, `UPDATE transfer_files SET sha256_actual = ?, saved_name = ?, target_path = ?, status = ?, completed_at = ? WHERE id = ?`,
		nullableString(shaActual), nullableString(savedName), nullableString(targetPath), status, completedAt, fileID)
	return err
}

// --- chunk bitmap ---

// GetChunkBitmap returns the current bitmap for a file, or a zeroed bitmap
// of size (totalChunks+7)/8 if none is stored.
func (d *DB) GetChunkBitmap(ctx context.Context, fileID string, totalChunks int) ([]byte, error) {
	row := d.QueryRowContext(ctx, `SELECT completed_bitmap FROM file_chunk_states WHERE file_id = ?`, fileID)
	var buf []byte
	if err := row.Scan(&buf); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return make([]byte, (totalChunks+7)/8), nil
		}
		return nil, err
	}
	return buf, nil
}

// SetChunkBit marks chunk index `chunk` completed and persists the bitmap.
// Returns the new completed count and whether this was a new completion.
func (d *DB) SetChunkBit(ctx context.Context, fileID string, chunk, totalChunks int) (int, bool, error) {
	bm, err := d.GetChunkBitmap(ctx, fileID, totalChunks)
	if err != nil {
		return 0, false, err
	}
	if chunk < 0 || chunk >= totalChunks {
		return 0, false, fmt.Errorf("chunk index %d out of range [0,%d)", chunk, totalChunks)
	}
	byteIdx := chunk >> 3
	mask := byte(1) << uint(chunk&7)
	already := bm[byteIdx]&mask != 0
	if !already {
		bm[byteIdx] |= mask
	}
	if err := d.saveBitmap(ctx, fileID, bm); err != nil {
		return 0, false, err
	}
	count := 0
	for _, b := range bm {
		count += popcount(b)
	}
	return count, !already, nil
}

// IsChunkComplete reports whether the given chunk index is set.
func (d *DB) IsChunkComplete(ctx context.Context, fileID string, chunk, totalChunks int) (bool, error) {
	bm, err := d.GetChunkBitmap(ctx, fileID, totalChunks)
	if err != nil {
		return false, err
	}
	if chunk < 0 || chunk >= totalChunks {
		return false, fmt.Errorf("chunk index out of range")
	}
	return bm[chunk>>3]&(1<<uint(chunk&7)) != 0, nil
}

func (d *DB) saveBitmap(ctx context.Context, fileID string, bm []byte) error {
	_, err := d.ExecContext(ctx, `
INSERT INTO file_chunk_states (file_id, completed_bitmap, updated_at)
VALUES (?, ?, ?)
ON CONFLICT(file_id) DO UPDATE SET completed_bitmap = excluded.completed_bitmap, updated_at = excluded.updated_at`,
		fileID, bm, Now())
	return err
}

// CompletedChunkIndices returns the sorted list of completed chunk indices.
func CompletedChunkIndices(bm []byte, totalChunks int) []int {
	out := make([]int, 0, totalChunks)
	for i := 0; i < totalChunks; i++ {
		if bm[i>>3]&(1<<uint(i&7)) != 0 {
			out = append(out, i)
		}
	}
	return out
}

// MissingChunkIndices is the complement of CompletedChunkIndices.
func MissingChunkIndices(bm []byte, totalChunks int) []int {
	out := make([]int, 0, totalChunks)
	for i := 0; i < totalChunks; i++ {
		if bm[i>>3]&(1<<uint(i&7)) == 0 {
			out = append(out, i)
		}
	}
	return out
}

// SetChunkBitInPlace is the pure, in-memory version of SetChunkBit.
// Returns the mutated bitmap, whether this was new, and the new completed count.
func SetChunkBitInPlace(bm []byte, chunk, totalChunks int) ([]byte, bool, int) {
	if chunk < 0 || chunk >= totalChunks {
		return bm, false, -1
	}
	byteIdx := chunk >> 3
	mask := byte(1) << uint(chunk&7)
	already := bm[byteIdx]&mask != 0
	if !already {
		bm[byteIdx] |= mask
	}
	count := 0
	for _, b := range bm {
		count += popcount(b)
	}
	return bm, !already, count
}

func popcount(b byte) int {
	b = b - ((b >> 1) & 0x55)
	b = (b & 0x33) + ((b >> 2) & 0x33)
	return int((b + (b >> 4)) & 0x0F)
}

func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}
