package api

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"

	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/storage"
	"fastdrop-desktop/internal/transfer"
	ws "fastdrop-desktop/internal/websocket"
)

// createTransferBody mirrors §10.1.
type createTransferBody struct {
	OfferID   string                  `json:"offerId"`
	Direction string                  `json:"direction"`
	Files     []createTransferFile    `json:"files"`
}

type createTransferFile struct {
	ClientFileID string `json:"clientFileId"`
	Name         string `json:"name"`
	Size         int64  `json:"size"`
	MimeType     string `json:"mimeType"`
	Sha256       string `json:"sha256"`
}

func (s *Server) handleCreateTransfer(w http.ResponseWriter, r *http.Request) {
	var body createTransferBody
	if err := readJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "malformed body", requestID(r))
		return
	}
	if len(body.Files) == 0 {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "no files", requestID(r))
		return
	}
	dir := transfer.DirClientToServer
	if strings.EqualFold(body.Direction, "server_to_client") {
		dir = transfer.DirServerToClient
	}
	sessID, _ := r.Context().Value(ctxSessionID).(string)
	devID, _ := r.Context().Value(ctxDeviceID).(string)

	// Disk space precheck for inbound files (§18).
	if dir == transfer.DirClientToServer {
		var total int64
		for _, f := range body.Files {
			total += f.Size
		}
		ok, free, err := s.Storage.HasSpaceFor(total)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
			return
		}
		if !ok {
			writeJSON(w, http.StatusInsufficientStorage, map[string]any{
				"error": map[string]any{
					"code":    "INSUFFICIENT_STORAGE",
					"message": "接收设备存储空间不足",
					"requestId": requestID(r),
					"details": map[string]any{
						"requiredBytes": total,
						"availableBytes": free,
					},
				},
			})
			return
		}
	}

	specs := make([]transfer.FileSpec, 0, len(body.Files))
	for _, f := range body.Files {
		specs = append(specs, transfer.FileSpec{
			ClientFileID: f.ClientFileID, Name: f.Name, Size: f.Size, MimeType: f.MimeType, Sha256: f.Sha256,
		})
	}
	res, err := s.Transfer.Create(r.Context(), sessID, devID, dir, body.OfferID, specs)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}

	// For inbound files: allocate .part files now.
	if dir == transfer.DirClientToServer {
		for _, f := range res.Files {
			_ = s.Storage.CreatePart(res.TransferID, f.FileID, fileSizeByID(body, f.ClientFileID))
		}
		// Notify the PC UI (and other WS clients on this session) that a
		// phone→PC transfer has been created, so it can show progress.
		offerFiles := make([]map[string]any, 0, len(res.Files))
		for _, f := range res.Files {
			offerFiles = append(offerFiles, map[string]any{
				"fileId": f.FileID,
				"name":   f.Name,
				"size":   fileSizeByID(body, f.ClientFileID),
			})
		}
		s.pushWSEvent(sessID, ws.MsgFileOffer, map[string]any{
			"offerId":    body.OfferID,
			"transferId": res.TransferID,
			"deviceName": "Phone",
			"files":      offerFiles,
		})
	}

	resp := map[string]any{
		"transferId": res.TransferID,
		"files":      toFileResponses(res),
	}
	writeJSON(w, http.StatusCreated, resp)
}

func toFileResponses(res *transfer.CreateResult) []map[string]any {
	out := make([]map[string]any, 0, len(res.Files))
	for _, f := range res.Files {
		out = append(out, map[string]any{
			"fileId":            f.FileID,
			"clientFileId":      f.ClientFileID,
			"name":              f.Name,
			"chunkSize":         f.ChunkSize,
			"totalChunks":       f.TotalChunks,
			"uploadUrlTemplate": "/api/v1/transfers/" + res.TransferID + "/files/" + f.FileID + "/chunks/{index}",
		})
	}
	return out
}

func fileSizeByID(body createTransferBody, clientID string) int64 {
	for _, f := range body.Files {
		if f.ClientFileID == clientID {
			return f.Size
		}
	}
	return 0
}

// errForbidden signals a cross-session access attempt.
var errForbidden = errors.New("resource does not belong to caller session")

// transferOwned loads a transfer and verifies it belongs to callerSession.
// Every transfer-scoped handler MUST gate on this so one paired device
// cannot read or mutate another session's transfers.
func (s *Server) transferOwned(ctx context.Context, transferID, callerSession string) (*database.TransferRow, error) {
	t, err := s.DB.GetTransfer(ctx, transferID)
	if err != nil {
		return nil, transfer.ErrTransferNotFound
	}
	if t.SessionID != callerSession {
		return nil, errForbidden
	}
	return t, nil
}

// fileOwned loads a transfer file, enforces that it lives under the
// path-scoped transferID (when non-empty), and verifies the owning transfer
// belongs to callerSession. Without the transferID check a caller could PUT
// chunks to the wrong .part path (data corruption) by mixing a foreign
// transferId with a known fileId.
func (s *Server) fileOwned(ctx context.Context, transferID, fileID, callerSession string) (*database.TransferFileRow, *database.TransferRow, error) {
	f, err := s.DB.GetTransferFile(ctx, fileID)
	if err != nil {
		return nil, nil, transfer.ErrFileNotFound
	}
	if transferID != "" && f.TransferID != transferID {
		return nil, nil, transfer.ErrFileNotFound
	}
	t, err := s.transferOwned(ctx, f.TransferID, callerSession)
	if err != nil {
		return nil, nil, err
	}
	return f, t, nil
}

// writeOwnedError maps ownership-helper errors to canonical HTTP responses.
func writeOwnedError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, transfer.ErrTransferNotFound):
		writeError(w, http.StatusNotFound, "TRANSFER_NOT_FOUND", "no such transfer", requestID(r))
	case errors.Is(err, transfer.ErrFileNotFound):
		writeError(w, http.StatusNotFound, "FILE_NOT_FOUND", "no such file in transfer", requestID(r))
	case errors.Is(err, errForbidden):
		writeError(w, http.StatusForbidden, "PERMISSION_DENIED", err.Error(), requestID(r))
	default:
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
	}
}

func (s *Server) handleListTransfers(w http.ResponseWriter, r *http.Request) {
	sessID, _ := r.Context().Value(ctxSessionID).(string)
	transfers, err := s.DB.ListTransfersForSession(r.Context(), sessID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"transfers": transfers})
}

func (s *Server) handleListActiveTransfers(w http.ResponseWriter, r *http.Request) {
	sessID, _ := r.Context().Value(ctxSessionID).(string)
	transfers, err := s.DB.ListTransfersForSession(r.Context(), sessID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	out := make([]any, 0)
	for _, t := range transfers {
		// "Active" = any non-terminal transfer (created/waiting_accept/
		// preparing/transferring/paused/retrying/verifying).
		if !transfer.Status(t.Status).IsTerminal() {
			out = append(out, t)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"transfers": out})
}

func (s *Server) handleGetTransfer(w http.ResponseWriter, r *http.Request) {
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	t, err := s.transferOwned(r.Context(), r.PathValue("transferId"), callerSession)
	if err != nil {
		writeOwnedError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func (s *Server) handleCancelTransfer(w http.ResponseWriter, r *http.Request) {
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	transferID := r.PathValue("transferId")
	if _, err := s.transferOwned(r.Context(), transferID, callerSession); err != nil {
		writeOwnedError(w, r, err)
		return
	}
	if err := s.Transfer.Cancel(r.Context(), transferID); err != nil {
		if errors.Is(err, transfer.ErrTransferNotFound) {
			writeError(w, http.StatusNotFound, "TRANSFER_NOT_FOUND", err.Error(), requestID(r))
			return
		}
		writeError(w, http.StatusBadRequest, "TRANSFER_CANCELLED", err.Error(), requestID(r))
		return
	}
	s.pushWSEvent(callerSession, ws.MsgTransferCancelled, map[string]any{
		"transferId": transferID,
	})
	writeJSON(w, http.StatusOK, map[string]any{"status": "cancelled"})
}

func (s *Server) handleRetryTransfer(w http.ResponseWriter, r *http.Request) {
	// Retry is a client-driven state change. For inbound transfers the
	// server simply records the intent; the next chunk PUT will re-arm
	// the scheduler.
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	t, err := s.transferOwned(r.Context(), r.PathValue("transferId"), callerSession)
	if err != nil {
		writeOwnedError(w, r, err)
		return
	}
	if transfer.Status(t.Status).IsTerminal() {
		writeError(w, http.StatusConflict, "TRANSFER_NOT_ACTIVE", "cannot retry a terminal transfer", requestID(r))
		return
	}
	_ = s.DB.UpdateTransferStatus(r.Context(), t.ID, string(transfer.StatusRetrying), t.TransferredBytes, "", "")
	writeJSON(w, http.StatusOK, map[string]any{"status": string(transfer.StatusRetrying)})
}

func (s *Server) handleDeleteTransfer(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("transferId")
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	if _, err := s.transferOwned(r.Context(), id, callerSession); err != nil {
		writeOwnedError(w, r, err)
		return
	}
	_ = s.Storage.CleanupTransfer(id)
	// Hard delete: chunk bitmaps first (FK references transfer_files), then
	// files, then the parent transfer row.
	_, _ = s.DB.ExecContext(r.Context(), `DELETE FROM file_chunk_states WHERE file_id IN (SELECT id FROM transfer_files WHERE transfer_id = ?)`, id)
	_, _ = s.DB.ExecContext(r.Context(), `DELETE FROM transfer_files WHERE transfer_id = ?`, id)
	_, _ = s.DB.ExecContext(r.Context(), `DELETE FROM transfers WHERE id = ?`, id)
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted"})
}

func (s *Server) handleGetFile(w http.ResponseWriter, r *http.Request) {
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	f, _, err := s.fileOwned(r.Context(), r.PathValue("transferId"), r.PathValue("fileId"), callerSession)
	if err != nil {
		writeOwnedError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, f)
}

func (s *Server) handlePutChunk(w http.ResponseWriter, r *http.Request) {
	transferID := r.PathValue("transferId")
	fileID := r.PathValue("fileId")
	idxStr := r.PathValue("chunkIndex")
	idx, err := strconv.Atoi(idxStr)
	if err != nil || idx < 0 {
		writeError(w, http.StatusBadRequest, "CHUNK_INDEX_INVALID", "bad chunk index", requestID(r))
		return
	}
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	f, t, err := s.fileOwned(r.Context(), transferID, fileID, callerSession)
	if err != nil {
		writeOwnedError(w, r, err)
		return
	}
	// Reject chunks aimed at a transfer that has already finished.
	if transfer.Status(t.Status).IsTerminal() {
		writeError(w, http.StatusConflict, "TRANSFER_NOT_ACTIVE", "transfer is "+t.Status, requestID(r))
		return
	}
	// §12: retrying → transferring when the next chunk arrives.
	if t.Status == string(transfer.StatusRetrying) {
		_ = s.DB.UpdateTransferStatus(r.Context(), transferID, string(transfer.StatusTransferring), t.TransferredBytes, "", "")
	}
	if idx >= f.TotalChunks {
		writeError(w, http.StatusBadRequest, "CHUNK_INDEX_INVALID", "chunk out of range", requestID(r))
		return
	}
	// Body size = at most chunkSize + small slack (spec §28.1).
	maxBody := int64(f.ChunkSize) + 1024
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "INVALID_REQUEST", "chunk too large", requestID(r))
		return
	}
	sched := s.Transfer.Scheduler()
	if sched != nil {
		if err := sched.Acquire(r.Context(), fileID); err != nil {
			writeError(w, http.StatusServiceUnavailable, "TOO_MANY_REQUESTS", "scheduler busy", requestID(r))
			return
		}
		defer sched.Release(fileID)
	}
	if _, err := s.Storage.WriteChunk(transferID, fileID, idx, f.ChunkSize, data); err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	chunkBytes := int64(len(data))
	count, justStarted, err := s.Transfer.MarkChunkComplete(r.Context(), transferID, fileID, idx, chunkBytes)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	// First chunk for this transfer → push transfer.started to all WS clients.
	if justStarted {
		s.pushWSEvent(t.SessionID, ws.MsgTransferStarted, map[string]any{
			"transferId": transferID,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"fileId":         fileID,
		"chunkIndex":     idx,
		"completedChunks": count,
	})
}

func (s *Server) handleListChunks(w http.ResponseWriter, r *http.Request) {
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	f, _, err := s.fileOwned(r.Context(), r.PathValue("transferId"), r.PathValue("fileId"), callerSession)
	if err != nil {
		writeOwnedError(w, r, err)
		return
	}
	bm, err := s.DB.GetChunkBitmap(r.Context(), f.ID, f.TotalChunks)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	completed := chunkIndices(bm, f.TotalChunks, true)
	missing := chunkIndices(bm, f.TotalChunks, false)
	writeJSON(w, http.StatusOK, map[string]any{
		"completedChunks": completed,
		"missingChunks":   missing,
	})
}

func chunkIndices(bm []byte, total int, completed bool) []int {
	out := make([]int, 0, total)
	for i := 0; i < total; i++ {
		set := bm[i>>3]&(1<<uint(i&7)) != 0
		if set == completed {
			out = append(out, i)
		}
	}
	return out
}

func (s *Server) handleCompleteFile(w http.ResponseWriter, r *http.Request) {
	transferID := r.PathValue("transferId")
	fileID := r.PathValue("fileId")
	var body struct {
		Size   int64  `json:"size"`
		Sha256 string `json:"sha256"`
	}
	if err := readJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error(), requestID(r))
		return
	}
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	f, t, err := s.fileOwned(r.Context(), transferID, fileID, callerSession)
	if err != nil {
		writeOwnedError(w, r, err)
		return
	}
	if body.Size > 0 && body.Size != f.TotalBytes {
		writeError(w, http.StatusBadRequest, "FILE_SIZE_MISMATCH", "size mismatch", requestID(r))
		return
	}
	// Verify bitmap is complete.
	bm, err := s.DB.GetChunkBitmap(r.Context(), f.ID, f.TotalChunks)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	completedCount := 0
	for _, b := range bm {
		completedCount += popcountByte(b)
	}
	if completedCount != f.TotalChunks {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "not all chunks received", requestID(r))
		return
	}
	// §12: If this is the last incomplete file, transition to verifying
	// before running the hash check so observers see the state.
	allFiles, _ := s.DB.ListTransferFiles(r.Context(), transferID)
	lastFile := true
	for _, ff := range allFiles {
		if ff.ID != fileID && ff.Status != string(transfer.StatusCompleted) {
			lastFile = false
			break
		}
	}
	if lastFile {
		_ = s.DB.UpdateTransferStatus(r.Context(), transferID, string(transfer.StatusVerifying), t.TransferredBytes, "", "")
		s.pushWSEvent(callerSession, ws.MsgTransferVerifying, map[string]any{"transferId": transferID})
	}
	finalPath, shaActual, err := s.Storage.FinalizeAndVerify(r.Context(), transferID, fileID, f.OriginalName, body.Sha256, s.Cfg.Storage.ConflictPolicy)
	if err != nil {
		if errors.Is(err, storage.ErrHashMismatch) {
			writeError(w, http.StatusBadRequest, "FILE_HASH_MISMATCH", "hash mismatch", requestID(r))
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	allDone, err := s.Transfer.CompleteFile(r.Context(), transferID, fileID, shaActual, baseName(finalPath), finalPath)
	if err != nil {
		// Hash mismatch or DB error — push transfer.failed.
		s.pushWSEvent(callerSession, ws.MsgTransferFailed, map[string]any{
			"transferId": transferID,
			"fileId":     fileID,
			"error":      err.Error(),
		})
		writeError(w, http.StatusBadRequest, "FILE_HASH_MISMATCH", err.Error(), requestID(r))
		return
	}
	if allDone {
		s.pushWSEvent(callerSession, ws.MsgTransferCompleted, map[string]any{
			"transferId": transferID,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"fileId":   fileID,
		"sha256":   shaActual,
		"savedPath": finalPath,
	})
}

func popcountByte(b byte) int {
	b = b - ((b >> 1) & 0x55)
	b = (b & 0x33) + ((b >> 2) & 0x33)
	return int((b + (b >> 4)) & 0x0F)
}

func baseName(p string) string {
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		p = p[i+1:]
	}
	if i := strings.LastIndexByte(p, '\\'); i >= 0 {
		p = p[i+1:]
	}
	return p
}

// pushWSEvent sends a WS event to a session (used to notify clients of
// transfer lifecycle changes that happen through the HTTP channel).
func (s *Server) pushWSEvent(sessionID string, msgType ws.MessageType, payload map[string]any) {
	if s.WSHub == nil {
		return
	}
	env, err := ws.NewEnvelope(msgType, payload)
	if err != nil {
		return
	}
	_ = s.WSHub.Send(sessionID, env)
}

// --- download helpers ---

func openFile(path string) (*os.File, error) { return os.Open(path) }

func serveContent(w http.ResponseWriter, f *os.File) { _, _ = io.Copy(w, f) }

func serveN(w http.ResponseWriter, f *os.File, n int64) { _, _ = io.CopyN(w, f, n) }

func mimeOrDefault(mimeType string) string {
	if mimeType != "" {
		return mimeType
	}
	return "application/octet-stream"
}

func formatInt(n int64) string {
	if n < 0 {
		return "0"
	}
	return strconv.FormatInt(n, 10)
}

func parseRange(h string, size int64) (start, end int64, ok bool) {
	if !strings.HasPrefix(h, "bytes=") {
		return 0, 0, false
	}
	h = strings.TrimPrefix(h, "bytes=")
	// Only single range; ignore multiple.
	if i := strings.IndexByte(h, ','); i >= 0 {
		h = h[:i]
	}
	parts := strings.SplitN(h, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false
	}
	// Suffix range: bytes=-N (last N bytes of the file).
	if strings.TrimSpace(parts[0]) == "" {
		count, err := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
		if err != nil || count <= 0 || count > size {
			return 0, 0, false
		}
		return size - count, size - 1, true
	}
	s, err := strconv.ParseInt(strings.TrimSpace(parts[0]), 10, 64)
	if err != nil {
		return 0, 0, false
	}
	// Open-ended: bytes=N-
	if strings.TrimSpace(parts[1]) == "" {
		if s < 0 || s >= size {
			return 0, 0, false
		}
		return s, size - 1, true
	}
	e, err := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
	if err != nil {
		return 0, 0, false
	}
	if s < 0 || s >= size || e < s || e >= size {
		return 0, 0, false
	}
	return s, e, true
}

func (s *Server) handleDownloadFile(w http.ResponseWriter, r *http.Request) {
	transferID := r.PathValue("transferId")
	fileID := r.PathValue("fileId")
	f, err := s.DB.GetTransferFile(r.Context(), fileID)
	if err != nil {
		writeError(w, http.StatusNotFound, "FILE_NOT_FOUND", "no such file", requestID(r))
		return
	}
	// Ownership check: the file's transfer must belong to the caller's session.
	// Without this, any paired device could read other sessions' files by
	// guessing fileId.
	if f.TransferID != transferID {
		writeError(w, http.StatusNotFound, "FILE_NOT_FOUND", "file not in transfer", requestID(r))
		return
	}
	t, err := s.DB.GetTransfer(r.Context(), transferID)
	if err != nil {
		writeError(w, http.StatusNotFound, "TRANSFER_NOT_FOUND", "no such transfer", requestID(r))
		return
	}
	callerSession, _ := r.Context().Value(ctxSessionID).(string)
	if t.SessionID != callerSession {
		writeError(w, http.StatusForbidden, "PERMISSION_DENIED", "file does not belong to caller session", requestID(r))
		return
	}

	// Resolve the on-disk path. Prefer target_path (completed), then
	// source_path (server_to_client source), then .part as fallback.
	diskPath := f.TargetPath
	if diskPath == "" {
		diskPath = f.SourcePath
	}
	if diskPath == "" {
		diskPath = s.Storage.PartPath(transferID, fileID)
	}

	file, err := openFile(diskPath)
	if err != nil {
		writeError(w, http.StatusNotFound, "FILE_NOT_FOUND", "file not accessible on disk", requestID(r))
		return
	}
	defer file.Close()

	fileSize := f.TotalBytes
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", mimeOrDefault(f.MimeType))

	// HEAD returns only headers.
	if r.Method == http.MethodHead {
		w.Header().Set("Content-Length", formatInt(fileSize))
		w.WriteHeader(http.StatusOK)
		return
	}

	// Parse Range header (single range only, per spec).
	rangeHeader := r.Header.Get("Range")
	if rangeHeader == "" {
		w.Header().Set("Content-Length", formatInt(fileSize))
		w.WriteHeader(http.StatusOK)
		serveContent(w, file)
		return
	}

	start, end, ok := parseRange(rangeHeader, fileSize)
	if !ok {
		w.Header().Set("Content-Range", "bytes */"+formatInt(fileSize))
		writeError(w, http.StatusRequestedRangeNotSatisfiable, "INVALID_REQUEST", "bad range", requestID(r))
		return
	}
	if end == 0 {
		end = fileSize - 1
	}
	contentLen := end - start + 1
	w.Header().Set("Content-Length", formatInt(contentLen))
	w.Header().Set("Content-Range", "bytes "+formatInt(start)+"-"+formatInt(end)+"/"+formatInt(fileSize))
	w.WriteHeader(http.StatusPartialContent)
	if _, err := file.Seek(start, 0); err != nil {
		return
	}
	serveN(w, file, contentLen)
}
