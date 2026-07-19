package api

import (
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"fastdrop-desktop/internal/storage"
	"fastdrop-desktop/internal/transfer"
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
		if t.Status == "transferring" || t.Status == "preparing" || t.Status == "retrying" || t.Status == "paused" {
			out = append(out, t)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"transfers": out})
}

func (s *Server) handleGetTransfer(w http.ResponseWriter, r *http.Request) {
	t, err := s.DB.GetTransfer(r.Context(), r.PathValue("transferId"))
	if err != nil {
		writeError(w, http.StatusNotFound, "TRANSFER_NOT_FOUND", "no such transfer", requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func (s *Server) handleCancelTransfer(w http.ResponseWriter, r *http.Request) {
	if err := s.Transfer.Cancel(r.Context(), r.PathValue("transferId")); err != nil {
		if errors.Is(err, transfer.ErrTransferNotFound) {
			writeError(w, http.StatusNotFound, "TRANSFER_NOT_FOUND", err.Error(), requestID(r))
			return
		}
		writeError(w, http.StatusBadRequest, "TRANSFER_CANCELLED", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "cancelled"})
}

func (s *Server) handleRetryTransfer(w http.ResponseWriter, r *http.Request) {
	// Retry is a client-driven state change. For inbound transfers the
	// server simply records the intent; the next chunk PUT will re-arm
	// the scheduler.
	t, err := s.DB.GetTransfer(r.Context(), r.PathValue("transferId"))
	if err != nil {
		writeError(w, http.StatusNotFound, "TRANSFER_NOT_FOUND", err.Error(), requestID(r))
		return
	}
	_ = s.DB.UpdateTransferStatus(r.Context(), t.ID, "retrying", t.TransferredBytes, "", "")
	writeJSON(w, http.StatusOK, map[string]any{"status": "retrying"})
}

func (s *Server) handleDeleteTransfer(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("transferId")
	t, err := s.DB.GetTransfer(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusNotFound, "TRANSFER_NOT_FOUND", err.Error(), requestID(r))
		return
	}
	_ = t
	_ = s.Storage.CleanupTransfer(id)
	// Hard delete the row + files.
	_, _ = s.DB.ExecContext(r.Context(), `DELETE FROM transfer_files WHERE transfer_id = ?`, id)
	_, _ = s.DB.ExecContext(r.Context(), `DELETE FROM file_chunk_states WHERE file_id IN (SELECT id FROM transfer_files WHERE transfer_id = ?)`, id)
	_, _ = s.DB.ExecContext(r.Context(), `DELETE FROM transfers WHERE id = ?`, id)
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted"})
}

func (s *Server) handleGetFile(w http.ResponseWriter, r *http.Request) {
	f, err := s.DB.GetTransferFile(r.Context(), r.PathValue("fileId"))
	if err != nil {
		writeError(w, http.StatusNotFound, "FILE_NOT_FOUND", err.Error(), requestID(r))
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
	f, err := s.DB.GetTransferFile(r.Context(), fileID)
	if err != nil {
		writeError(w, http.StatusNotFound, "FILE_NOT_FOUND", err.Error(), requestID(r))
		return
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
	count, err := s.Transfer.MarkChunkComplete(r.Context(), transferID, fileID, idx, chunkBytes)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"fileId":         fileID,
		"chunkIndex":     idx,
		"completedChunks": count,
	})
}

func (s *Server) handleListChunks(w http.ResponseWriter, r *http.Request) {
	f, err := s.DB.GetTransferFile(r.Context(), r.PathValue("fileId"))
	if err != nil {
		writeError(w, http.StatusNotFound, "FILE_NOT_FOUND", err.Error(), requestID(r))
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
	f, err := s.DB.GetTransferFile(r.Context(), fileID)
	if err != nil {
		writeError(w, http.StatusNotFound, "FILE_NOT_FOUND", err.Error(), requestID(r))
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
		writeError(w, http.StatusBadRequest, "FILE_SIZE_MISMATCH", "not all chunks received", requestID(r))
		return
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
	if err := s.Transfer.CompleteFile(r.Context(), transferID, fileID, shaActual, baseName(finalPath), finalPath); err != nil {
		writeError(w, http.StatusBadRequest, "FILE_HASH_MISMATCH", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"fileId":   fileID,
		"sha256":   shaActual,
		"savedPath": finalPath,
	})
}

// storageHashMismatch is unused; storage.ErrHashMismatch is used directly.
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

func (s *Server) handleDownloadFile(w http.ResponseWriter, r *http.Request) {
	// Phase 1: server_to_client direction is via drag-drop on the Vue UI;
	// implementation is structurally similar to GET /content with Range.
	// Returning a 501 keeps the contract honest without faking it.
	writeError(w, http.StatusNotImplemented, "INTERNAL_ERROR", "download path not yet wired", requestID(r))
}
