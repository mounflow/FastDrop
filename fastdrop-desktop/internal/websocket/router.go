package websocket

import (
	"context"
	"encoding/json"
	"log"

	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/session"
	"fastdrop-desktop/internal/storage"
	"fastdrop-desktop/internal/transfer"
)

// Router dispatches WS messages to the appropriate business-logic handlers.
type Router struct {
	Hub      *Hub
	Transfer *transfer.Manager
	Session  *session.Manager
	DB       *database.DB
	Storage  *storage.Manager
}

// OnMessage implements MessageHandler. It dispatches based on envelope type.
func (r *Router) OnMessage(c *Client, env *Envelope) {
	log.Printf("[ws] dispatch type=%s session=%s", env.Type, maskID(c.sessionID))
	switch env.Type {
	case MsgFileOffer:
		r.handleFileOffer(c, env)
	case MsgFileOfferAccept:
		r.handleFileOfferAccept(c, env)
	case MsgFileOfferReject:
		r.handleFileOfferReject(c, env)
	case MsgTransferCancel:
		r.handleTransferCancel(c, env)
	case MsgTransferPaused:
		r.handleTransferPause(c, env)
	case MsgTransferResume:
		r.handleTransferResume(c, env)
	default:
		// Unknown message types are silently ignored per spec.
	}
}

// FileOfferPayload mirrors §8.3.
type FileOfferPayload struct {
	OfferID string              `json:"offerId"`
	Files   []FileOfferFile     `json:"files"`
}

type FileOfferFile struct {
	ClientFileID string `json:"clientFileId"`
	Name         string `json:"name"`
	Size         int64  `json:"size"`
	MimeType     string `json:"mimeType"`
	ModifiedAt   int64  `json:"modifiedAt,omitempty"`
}

func (r *Router) handleFileOffer(c *Client, env *Envelope) {
	var p FileOfferPayload
	if err := json.Unmarshal(env.Payload, &p); err != nil {
		r.sendError(c, "INVALID_REQUEST", "malformed file.offer payload")
		return
	}
	if len(p.Files) == 0 {
		r.sendError(c, "INVALID_REQUEST", "no files in offer")
		return
	}
	specs := make([]transfer.FileSpec, 0, len(p.Files))
	for _, f := range p.Files {
		specs = append(specs, transfer.FileSpec{
			ClientFileID: f.ClientFileID,
			Name:         f.Name,
			Size:         f.Size,
			MimeType:     f.MimeType,
		})
	}
	// file.offer means the phone wants to send files TO the PC (client_to_server).
	res, err := r.Transfer.Create(context.Background(), c.sessionID, c.deviceID, transfer.DirClientToServer, p.OfferID, specs)
	if err != nil {
		r.sendError(c, "INTERNAL_ERROR", err.Error())
		return
	}
	// Allocate .part files for each inbound file.
	for _, f := range res.Files {
		if size := fileSizeByID(specs, f.ClientFileID); size > 0 {
			_ = r.Storage.CreatePart(res.TransferID, f.FileID, size)
		}
	}
	// Reply to the sender (the phone) with the create result. The phone
	// needs transferId + per-file fileId to drive subsequent chunk PUTs.
	reply, _ := NewEnvelope(MsgTransferCreated, map[string]any{
		"transferId": res.TransferID,
		"offerId":    p.OfferID,
		"direction":  string(transfer.DirClientToServer),
		"status":     string(transfer.StatusCreated),
		"files":      toOfferFileInfos(res),
	})
	_ = c.sendEnvelope(reply)

	// Broadcast the offer to other WS clients on this session (e.g. the
	// Vue PC UI) so they can display an accept/reject dialog. The sender
	// (phone) also receives this but already has transfer.created and can
	// ignore the echo. Include file sizes from the original offer payload.
	offerFiles := make([]map[string]any, 0, len(res.Files))
	for _, f := range res.Files {
		offerFiles = append(offerFiles, map[string]any{
			"fileId":   f.FileID,
			"name":     f.Name,
			"size":     fileSizeByID(specs, f.ClientFileID),
			"mimeType": fileMimeByID(specs, f.ClientFileID),
		})
	}
	r.pushTransferEvent(c.sessionID, MsgFileOffer, map[string]any{
		"offerId":    p.OfferID,
		"transferId": res.TransferID,
		"deviceName": "Phone",
		"files":      offerFiles,
	})
}

func (r *Router) handleFileOfferAccept(c *Client, env *Envelope) {
	var p struct {
		OfferID string `json:"offerId"`
	}
	if err := json.Unmarshal(env.Payload, &p); err != nil {
		return
	}
	// Try the offerId as a direct transferId first (the Vue UI sends
	// transferId in the offerId field), then fall back to session search.
	transferID := p.OfferID
	if transferID == "" || !r.transferExists(transferID) {
		transferID = r.findTransferBySession(c.sessionID)
	}
	if transferID == "" {
		r.sendError(c, "TRANSFER_NOT_FOUND", "no pending transfer for this session")
		return
	}
	// Preserve current transferred_bytes — accepting must not lose progress.
	var transferred int64
	if t, err := r.DB.GetTransfer(context.Background(), transferID); err == nil {
		transferred = t.TransferredBytes
	}
	_ = r.DB.UpdateTransferStatus(context.Background(), transferID, string(transfer.StatusPreparing), transferred, "", "")
	r.pushTransferEvent(c.sessionID, MsgFileOfferAccept, map[string]any{
		"transferId": transferID,
		"offerId":    p.OfferID,
	})
}

func (r *Router) handleFileOfferReject(c *Client, env *Envelope) {
	var p struct {
		OfferID string `json:"offerId"`
		Reason  string `json:"reason"`
	}
	_ = json.Unmarshal(env.Payload, &p)
	transferID := r.findTransferBySession(c.sessionID)
	if transferID == "" {
		return
	}
	// Preserve current transferred_bytes.
	var transferred int64
	if t, err := r.DB.GetTransfer(context.Background(), transferID); err == nil {
		transferred = t.TransferredBytes
	}
	_ = r.DB.UpdateTransferStatus(context.Background(), transferID, string(transfer.StatusRejected), transferred, "user_rejected", p.Reason)
	r.pushTransferEvent(c.sessionID, MsgFileOfferReject, map[string]any{
		"transferId": transferID,
		"offerId":    p.OfferID,
		"reason":     p.Reason,
	})
}

func (r *Router) handleTransferCancel(c *Client, env *Envelope) {
	var p struct {
		TransferID string `json:"transferId"`
	}
	_ = json.Unmarshal(env.Payload, &p)
	if p.TransferID == "" {
		return
	}
	// Ownership check: the transfer must belong to this client's session.
	if t, err := r.DB.GetTransfer(context.Background(), p.TransferID); err != nil || t.SessionID != c.sessionID {
		r.sendError(c, "TRANSFER_NOT_FOUND", "no such transfer for this session")
		return
	}
	if err := r.Transfer.Cancel(context.Background(), p.TransferID); err != nil {
		r.sendError(c, "TRANSFER_CANCELLED", err.Error())
		return
	}
	_ = r.Storage.CleanupTransfer(p.TransferID)
	r.pushTransferEvent(c.sessionID, MsgTransferCancelled, map[string]any{
		"transferId": p.TransferID,
	})
}

func (r *Router) handleTransferPause(c *Client, env *Envelope) {
	var p struct {
		TransferID string `json:"transferId"`
	}
	_ = json.Unmarshal(env.Payload, &p)
	if p.TransferID == "" {
		return
	}
	// Preserve current transferred_bytes — pausing must not lose progress.
	var transferred int64
	if t, err := r.DB.GetTransfer(context.Background(), p.TransferID); err == nil {
		transferred = t.TransferredBytes
	}
	_ = r.DB.UpdateTransferStatus(context.Background(), p.TransferID, string(transfer.StatusPaused), transferred, "", "")
	r.pushTransferEvent(c.sessionID, MsgTransferPaused, map[string]any{
		"transferId": p.TransferID,
	})
}

func (r *Router) handleTransferResume(c *Client, env *Envelope) {
	var p struct {
		TransferID string `json:"transferId"`
	}
	_ = json.Unmarshal(env.Payload, &p)
	if p.TransferID == "" {
		return
	}
	// Verify the transfer is currently paused and belongs to this session.
	t, err := r.DB.GetTransfer(context.Background(), p.TransferID)
	if err != nil || t.SessionID != c.sessionID {
		r.sendError(c, "TRANSFER_NOT_FOUND", "no such transfer for this session")
		return
	}
	if t.Status != string(transfer.StatusPaused) {
		r.sendError(c, "INVALID_REQUEST", "transfer is not paused")
		return
	}
	_ = r.DB.UpdateTransferStatus(context.Background(), p.TransferID, string(transfer.StatusTransferring), t.TransferredBytes, "", "")
	r.pushTransferEvent(c.sessionID, MsgTransferResume, map[string]any{
		"transferId": p.TransferID,
	})
}

// pushTransferEvent sends an event to the session's WS client.
func (r *Router) pushTransferEvent(sessionID string, msgType MessageType, payload map[string]any) {
	env, err := NewEnvelope(msgType, payload)
	if err != nil {
		return
	}
	_ = r.Hub.Send(sessionID, env)
}

func (r *Router) sendError(c *Client, code, message string) {
	errEnv, _ := NewEnvelope(MsgError, map[string]any{"code": code, "message": message})
	_ = c.sendEnvelope(errEnv)
}

func (r *Router) transferExists(transferID string) bool {
	_, err := r.DB.GetTransfer(context.Background(), transferID)
	return err == nil
}

func (r *Router) findTransferBySession(sessionID string) string {
	transfers, err := r.DB.ListTransfersForSession(context.Background(), sessionID)
	if err != nil || len(transfers) == 0 {
		return ""
	}
	for _, t := range transfers {
		if t.Status == string(transfer.StatusCreated) || t.Status == string(transfer.StatusWaitingAccept) {
			return t.ID
		}
	}
	// No active transfer in an accept/reject state: return "" rather than
	// mutating an unrelated historical row.
	return ""
}

func fileSizeByID(specs []transfer.FileSpec, clientID string) int64 {
	for _, s := range specs {
		if s.ClientFileID == clientID {
			return s.Size
		}
	}
	return 0
}

func fileMimeByID(specs []transfer.FileSpec, clientID string) string {
	for _, s := range specs {
		if s.ClientFileID == clientID {
			return s.MimeType
		}
	}
	return ""
}

func toOfferFileInfos(res *transfer.CreateResult) []map[string]any {
	out := make([]map[string]any, 0, len(res.Files))
	for _, f := range res.Files {
		out = append(out, map[string]any{
			"fileId":       f.FileID,
			"clientFileId": f.ClientFileID,
			"name":         f.Name,
			"chunkSize":    f.ChunkSize,
			"totalChunks":  f.TotalChunks,
		})
	}
	return out
}

// TransferEventCallback returns a ProgressCallback that pushes WS events.
func (r *Router) TransferEventCallback() transfer.ProgressCallback {
	return func(transferID, fileID string, transferredBytes, totalBytes int64, speedBps float64) {
		t, err := r.DB.GetTransfer(context.Background(), transferID)
		if err != nil {
			return
		}
		r.pushTransferEvent(t.SessionID, MsgTransferProgress, map[string]any{
			"transferId":       transferID,
			"fileId":           fileID,
			"transferredBytes": transferredBytes,
			"totalBytes":       totalBytes,
			"speedBps":         speedBps,
		})
	}
}
