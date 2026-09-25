package websocket

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/session"
	"fastdrop-desktop/internal/storage"
	"fastdrop-desktop/internal/transfer"
)

// newTestRouter builds a Router backed by a real SQLite DB and a running Hub.
func newTestRouter(t *testing.T) (*Router, *Hub, *database.DB) {
	t.Helper()
	db, err := database.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })

	db.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	db.InsertSession(database.SessionRow{ID: "s1", DeviceID: "d1", TokenHash: "h", CreatedAt: 1, ExpiresAt: 9999999})

	hub := NewHub(&fakeValidator{deviceID: "d1"})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go hub.Run(ctx)

	storeMgr, err := storage.NewManager(filepath.Join(t.TempDir(), "Downloads"))
	if err != nil {
		t.Fatal(err)
	}
	sessMgr := session.NewManager(db, time.Hour)
	transferMgr := transfer.NewManager(db, 4*1024*1024, nil)

	r := &Router{
		Hub:      hub,
		Transfer: transferMgr,
		Session:  sessMgr,
		DB:       db,
		Storage:  storeMgr,
	}
	return r, hub, db
}

// fakeClient returns a Client with the given sessionID (no real WS conn).
func fakeClient(sessionID, deviceID string) *Client {
	return &Client{
		sessionID: sessionID,
		deviceID:  deviceID,
		send:      make(chan []byte, 64),
	}
}

func TestRouterFileOfferCreatesTransfer(t *testing.T) {
	r, _, db := newTestRouter(t)
	c := fakeClient("s1", "d1")

	payload, _ := json.Marshal(FileOfferPayload{
		OfferID: "offer-1",
		Files: []FileOfferFile{
			{ClientFileID: "cf1", Name: "photo.jpg", Size: 1024, MimeType: "image/jpeg"},
		},
	})
	env := &Envelope{Type: MsgFileOffer, Payload: payload}
	r.OnMessage(c, env)

	// The client should have received a transfer.created reply.
	select {
	case msg := <-c.send:
		var reply Envelope
		json.Unmarshal(msg, &reply)
		if reply.Type != MsgTransferCreated {
			t.Errorf("reply type = %s, want transfer.created", reply.Type)
		}
		var p map[string]any
		json.Unmarshal(reply.Payload, &p)
		if p["transferId"] == nil || p["transferId"] == "" {
			t.Error("missing transferId in reply")
		}
		if p["direction"] != "client_to_server" {
			t.Errorf("direction = %v, want client_to_server", p["direction"])
		}
	case <-time.After(time.Second):
		t.Fatal("no reply received")
	}

	// Verify the transfer was persisted.
	transfers, _ := db.ListTransfersForSession(context.Background(), "s1")
	if len(transfers) != 1 {
		t.Fatalf("expected 1 transfer, got %d", len(transfers))
	}
	if transfers[0].TotalFiles != 1 || transfers[0].TotalBytes != 1024 {
		t.Errorf("transfer totals: files=%d bytes=%d", transfers[0].TotalFiles, transfers[0].TotalBytes)
	}
}

func TestRouterFileOfferEmptyFiles(t *testing.T) {
	r, _, _ := newTestRouter(t)
	c := fakeClient("s1", "d1")

	payload, _ := json.Marshal(FileOfferPayload{OfferID: "o", Files: []FileOfferFile{}})
	env := &Envelope{Type: MsgFileOffer, Payload: payload}
	r.OnMessage(c, env)

	// Should receive an error.
	select {
	case msg := <-c.send:
		var reply Envelope
		json.Unmarshal(msg, &reply)
		if reply.Type != MsgError {
			t.Errorf("reply type = %s, want error", reply.Type)
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply received")
	}
}

func TestRouterFileOfferMalformedPayload(t *testing.T) {
	r, _, _ := newTestRouter(t)
	c := fakeClient("s1", "d1")

	env := &Envelope{Type: MsgFileOffer, Payload: json.RawMessage(`{invalid`)}
	r.OnMessage(c, env)

	select {
	case msg := <-c.send:
		var reply Envelope
		json.Unmarshal(msg, &reply)
		if reply.Type != MsgError {
			t.Errorf("reply type = %s, want error", reply.Type)
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply received")
	}
}

func TestRouterTransferCancelOwnership(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	// Create a transfer under session s1.
	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, _ := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "o", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})

	// Client from a different session tries to cancel → error.
	c2 := fakeClient("s2", "d2")
	payload, _ := json.Marshal(map[string]string{"transferId": res.TransferID})
	r.OnMessage(c2, &Envelope{Type: MsgTransferCancel, Payload: payload})

	select {
	case msg := <-c2.send:
		var reply Envelope
		json.Unmarshal(msg, &reply)
		if reply.Type != MsgError {
			t.Errorf("reply type = %s, want error", reply.Type)
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply for cross-session cancel")
	}

	// Transfer should NOT be cancelled.
	tr, _ := db.GetTransfer(ctx, res.TransferID)
	if tr.Status == "cancelled" {
		t.Error("cross-session cancel should not have succeeded")
	}
}

func TestRouterTransferCancelSuccess(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, _ := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "o", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})

	c := fakeClient("s1", "d1")
	payload, _ := json.Marshal(map[string]string{"transferId": res.TransferID})
	r.OnMessage(c, &Envelope{Type: MsgTransferCancel, Payload: payload})

	// Transfer should be cancelled.
	tr, _ := db.GetTransfer(ctx, res.TransferID)
	if tr.Status != "cancelled" {
		t.Errorf("status = %s, want cancelled", tr.Status)
	}
}

func TestRouterTransferPauseResume(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, _ := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "o", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	// Move to transferring first.
	db.UpdateTransferStatus(ctx, res.TransferID, "transferring", 0, "", "")

	c := fakeClient("s1", "d1")

	// Pause.
	payload, _ := json.Marshal(map[string]string{"transferId": res.TransferID})
	r.OnMessage(c, &Envelope{Type: MsgTransferPause, Payload: payload})
	tr, _ := db.GetTransfer(ctx, res.TransferID)
	if tr.Status != "paused" {
		t.Errorf("after pause: status = %s, want paused", tr.Status)
	}

	// Resume.
	r.OnMessage(c, &Envelope{Type: MsgTransferResume, Payload: payload})
	tr, _ = db.GetTransfer(ctx, res.TransferID)
	if tr.Status != "transferring" {
		t.Errorf("after resume: status = %s, want transferring", tr.Status)
	}
}

func TestRouterRejectsCrossSessionPause(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, _ := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "o", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	_ = db.UpdateTransferStatus(ctx, res.TransferID, "transferring", 0, "", "")

	c := fakeClient("s2", "d2")
	payload, _ := json.Marshal(map[string]string{"transferId": res.TransferID})
	r.OnMessage(c, &Envelope{Type: MsgTransferPause, Payload: payload})

	select {
	case msg := <-c.send:
		var reply Envelope
		_ = json.Unmarshal(msg, &reply)
		if reply.Type != MsgError {
			t.Errorf("reply type = %s, want error", reply.Type)
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply for cross-session pause")
	}

	tr, _ := db.GetTransfer(ctx, res.TransferID)
	if tr.Status != "transferring" {
		t.Errorf("status = %s, want transferring", tr.Status)
	}
}

func TestRouterResumeNonPausedTransfer(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, _ := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "o", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	// Status is "created", not "paused".
	c := fakeClient("s1", "d1")
	payload, _ := json.Marshal(map[string]string{"transferId": res.TransferID})
	r.OnMessage(c, &Envelope{Type: MsgTransferResume, Payload: payload})

	// Should receive an error.
	select {
	case msg := <-c.send:
		var reply Envelope
		json.Unmarshal(msg, &reply)
		if reply.Type != MsgError {
			t.Errorf("reply type = %s, want error", reply.Type)
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply for resume of non-paused transfer")
	}
}

func TestRouterUnknownMessageType(t *testing.T) {
	r, _, _ := newTestRouter(t)
	c := fakeClient("s1", "d1")

	// Unknown message types should be silently ignored (no reply).
	r.OnMessage(c, &Envelope{Type: "unknown.type", Payload: json.RawMessage(`{}`)})

	select {
	case msg := <-c.send:
		t.Errorf("unexpected reply for unknown type: %s", string(msg))
	case <-time.After(100 * time.Millisecond):
		// expected: no reply
	}
}

func TestRouterFileOfferAcceptReject(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, _ := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "offer-x", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	// Set to waiting_accept so findTransferBySession can find it.
	db.UpdateTransferStatus(ctx, res.TransferID, "waiting_accept", 0, "", "")

	c := fakeClient("s1", "d1")

	// Accept using the transferId directly.
	payload, _ := json.Marshal(map[string]string{"offerId": res.TransferID})
	r.OnMessage(c, &Envelope{Type: MsgFileOfferAccept, Payload: payload})

	tr, _ := db.GetTransfer(ctx, res.TransferID)
	if tr.Status != "preparing" {
		t.Errorf("after accept: status = %s, want preparing", tr.Status)
	}
}

func TestRouterFileOfferReject(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, _ := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "offer-y", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	db.UpdateTransferStatus(ctx, res.TransferID, "waiting_accept", 0, "", "")

	c := fakeClient("s1", "d1")
	payload, _ := json.Marshal(map[string]string{"offerId": res.TransferID, "reason": "not now"})
	r.OnMessage(c, &Envelope{Type: MsgFileOfferReject, Payload: payload})

	tr, _ := db.GetTransfer(ctx, res.TransferID)
	if tr.Status != "rejected" {
		t.Errorf("after reject: status = %s, want rejected", tr.Status)
	}
}

func TestRouterReceiverCompletionClosesOutboundTransfer(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	res, err := r.Transfer.Create(ctx, "s1", "d1", transfer.DirServerToClient, "offer-out", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	if err != nil {
		t.Fatal(err)
	}
	c := fakeClient("s1", "d1")
	payload, _ := json.Marshal(map[string]string{"transferId": res.TransferID})
	r.OnMessage(c, &Envelope{Type: MsgTransferCompleted, Payload: payload})

	tr, err := db.GetTransfer(ctx, res.TransferID)
	if err != nil {
		t.Fatal(err)
	}
	if tr.Status != string(transfer.StatusCompleted) || tr.TransferredBytes != 10 {
		t.Fatalf("transfer status=%s bytes=%d, want completed/10", tr.Status, tr.TransferredBytes)
	}
	file, err := db.GetTransferFile(ctx, res.Files[0].FileID)
	if err != nil {
		t.Fatal(err)
	}
	if file.Status != string(transfer.StatusCompleted) || file.TransferredBytes != 10 {
		t.Fatalf("file status=%s bytes=%d, want completed/10", file.Status, file.TransferredBytes)
	}
}

func TestRouterReceiverCannotCompleteInboundTransfer(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	res, err := r.Transfer.Create(ctx, "s1", "d1", transfer.DirClientToServer, "offer-in", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	if err != nil {
		t.Fatal(err)
	}
	c := fakeClient("s1", "d1")
	payload, _ := json.Marshal(map[string]string{"transferId": res.TransferID})
	r.OnMessage(c, &Envelope{Type: MsgTransferCompleted, Payload: payload})

	tr, err := db.GetTransfer(ctx, res.TransferID)
	if err != nil {
		t.Fatal(err)
	}
	if tr.Status == string(transfer.StatusCompleted) {
		t.Fatal("client_to_server transfer must not be completed by a WS receiver acknowledgement")
	}
	select {
	case msg := <-c.send:
		var reply Envelope
		if err := json.Unmarshal(msg, &reply); err != nil {
			t.Fatal(err)
		}
		if reply.Type != MsgError {
			t.Fatalf("reply type=%s, want error", reply.Type)
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply for invalid completion acknowledgement")
	}
}

func TestFileSizeByID(t *testing.T) {
	specs := []transfer.FileSpec{
		{ClientFileID: "a", Size: 100},
		{ClientFileID: "b", Size: 200},
	}
	if fileSizeByID(specs, "a") != 100 {
		t.Error("fileSizeByID(a) wrong")
	}
	if fileSizeByID(specs, "b") != 200 {
		t.Error("fileSizeByID(b) wrong")
	}
	if fileSizeByID(specs, "c") != 0 {
		t.Error("fileSizeByID(c) should be 0")
	}
}

func TestFileMimeByID(t *testing.T) {
	specs := []transfer.FileSpec{
		{ClientFileID: "a", MimeType: "text/plain"},
		{ClientFileID: "b", MimeType: "image/png"},
	}
	if fileMimeByID(specs, "a") != "text/plain" {
		t.Error("fileMimeByID(a) wrong")
	}
	if fileMimeByID(specs, "c") != "" {
		t.Error("fileMimeByID(c) should be empty")
	}
}

// Insufficient disk space must reject the offer before any transfer task or
// .part file is created (§18).
func TestRouterFileOfferInsufficientStorage(t *testing.T) {
	r, _, db := newTestRouter(t)
	c := fakeClient("s1", "d1")

	payload, _ := json.Marshal(FileOfferPayload{
		OfferID: "offer-big",
		Files: []FileOfferFile{
			{ClientFileID: "cf1", Name: "huge.bin", Size: 1 << 62},
		},
	})
	r.OnMessage(c, &Envelope{Type: MsgFileOffer, Payload: payload})

	select {
	case msg := <-c.send:
		var reply Envelope
		if err := json.Unmarshal(msg, &reply); err != nil {
			t.Fatal(err)
		}
		if reply.Type != MsgError {
			t.Fatalf("reply type = %s, want error", reply.Type)
		}
		var p map[string]any
		if err := json.Unmarshal(reply.Payload, &p); err != nil {
			t.Fatal(err)
		}
		if p["code"] != "INSUFFICIENT_STORAGE" {
			t.Errorf("error code = %v, want INSUFFICIENT_STORAGE", p["code"])
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply received")
	}

	transfers, _ := db.ListTransfersForSession(context.Background(), "s1")
	if len(transfers) != 0 {
		t.Errorf("created %d transfer(s) despite insufficient storage", len(transfers))
	}
}

// The accept/reject handlers must honour an explicit transferId field.
func TestRouterFileOfferAcceptByTransferIdField(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()
	c := fakeClient("s1", "d1")

	offerPayload, _ := json.Marshal(FileOfferPayload{
		OfferID: "offer-tid",
		Files:   []FileOfferFile{{ClientFileID: "cf1", Name: "f.txt", Size: 10}},
	})
	r.OnMessage(c, &Envelope{Type: MsgFileOffer, Payload: offerPayload})
	select {
	case <-c.send: // drain transfer.created
	case <-time.After(time.Second):
		t.Fatal("no transfer.created reply")
	}
	transfers, _ := db.ListTransfersForSession(ctx, "s1")
	if len(transfers) != 1 {
		t.Fatalf("expected 1 transfer, got %d", len(transfers))
	}
	tid := transfers[0].ID
	if tr, _ := db.GetTransfer(ctx, tid); tr.Status != string(transfer.StatusWaitingAccept) {
		t.Fatalf("fresh offer status = %s, want waiting_accept", tr.Status)
	}

	payload, _ := json.Marshal(map[string]string{"transferId": tid})
	r.OnMessage(c, &Envelope{Type: MsgFileOfferAccept, Payload: payload})

	tr, _ := db.GetTransfer(ctx, tid)
	if tr.Status != string(transfer.StatusPreparing) {
		t.Errorf("after accept: status = %s, want preparing", tr.Status)
	}
}

func TestRouterFileOfferRejectByTransferIdField(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()
	c := fakeClient("s1", "d1")

	offerPayload, _ := json.Marshal(FileOfferPayload{
		OfferID: "offer-tid-r",
		Files:   []FileOfferFile{{ClientFileID: "cf1", Name: "f.txt", Size: 10}},
	})
	r.OnMessage(c, &Envelope{Type: MsgFileOffer, Payload: offerPayload})
	select {
	case <-c.send: // drain transfer.created
	case <-time.After(time.Second):
		t.Fatal("no transfer.created reply")
	}
	transfers, _ := db.ListTransfersForSession(ctx, "s1")
	tid := transfers[0].ID

	payload, _ := json.Marshal(map[string]string{"transferId": tid, "reason": "not now"})
	r.OnMessage(c, &Envelope{Type: MsgFileOfferReject, Payload: payload})

	tr, _ := db.GetTransfer(ctx, tid)
	if tr.Status != string(transfer.StatusRejected) {
		t.Errorf("after reject: status = %s, want rejected", tr.Status)
	}
}

// State-machine guards: accept only from created/waiting_accept, reject
// only from waiting_accept — otherwise a 409-style error and no mutation.
func TestRouterFileOfferGuardsState(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, _ := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "o", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	tid := res.TransferID

	// Accept while transferring → error, status unchanged.
	db.UpdateTransferStatus(ctx, tid, string(transfer.StatusTransferring), 0, "", "")
	c := fakeClient("s1", "d1")
	payload, _ := json.Marshal(map[string]string{"transferId": tid})
	r.OnMessage(c, &Envelope{Type: MsgFileOfferAccept, Payload: payload})
	select {
	case msg := <-c.send:
		var reply Envelope
		_ = json.Unmarshal(msg, &reply)
		if reply.Type != MsgError {
			t.Fatalf("accept while transferring: reply type = %s, want error", reply.Type)
		}
		var p map[string]any
		_ = json.Unmarshal(reply.Payload, &p)
		if p["code"] != "TRANSFER_NOT_ACTIVE" {
			t.Errorf("accept while transferring: code = %v, want TRANSFER_NOT_ACTIVE", p["code"])
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply for accept while transferring")
	}
	if tr, _ := db.GetTransfer(ctx, tid); tr.Status != string(transfer.StatusTransferring) {
		t.Errorf("status = %s, want transferring (unchanged)", tr.Status)
	}

	// Reject while merely created (not waiting_accept) → error, unchanged.
	db.UpdateTransferStatus(ctx, tid, string(transfer.StatusCreated), 0, "", "")
	payload, _ = json.Marshal(map[string]string{"transferId": tid, "reason": "no"})
	r.OnMessage(c, &Envelope{Type: MsgFileOfferReject, Payload: payload})
	select {
	case msg := <-c.send:
		var reply Envelope
		_ = json.Unmarshal(msg, &reply)
		if reply.Type != MsgError {
			t.Fatalf("reject while created: reply type = %s, want error", reply.Type)
		}
		var p map[string]any
		_ = json.Unmarshal(reply.Payload, &p)
		if p["code"] != "TRANSFER_NOT_ACTIVE" {
			t.Errorf("reject while created: code = %v, want TRANSFER_NOT_ACTIVE", p["code"])
		}
	case <-time.After(time.Second):
		t.Fatal("no error reply for reject while created")
	}
	if tr, _ := db.GetTransfer(ctx, tid); tr.Status != string(transfer.StatusCreated) {
		t.Errorf("status = %s, want created (unchanged)", tr.Status)
	}
}

// 问题 7②: an inbound (client_to_server) sender must be able to report its
// own failure so the authoritative row does not linger as "transferring".
func TestRouterTransferFailedAcceptsInbound(t *testing.T) {
	r, _, db := newTestRouter(t)
	ctx := context.Background()

	tm := transfer.NewManager(db, 4*1024*1024, nil)
	res, err := tm.Create(ctx, "s1", "d1", transfer.DirClientToServer, "o", []transfer.FileSpec{
		{ClientFileID: "c1", Name: "f.txt", Size: 10},
	})
	if err != nil {
		t.Fatal(err)
	}
	tid := res.TransferID
	if err := db.UpdateTransferStatus(ctx, tid, string(transfer.StatusTransferring), 4, "", ""); err != nil {
		t.Fatal(err)
	}

	payload, _ := json.Marshal(map[string]string{
		"transferId": tid,
		"code":       "TRANSFER_FAILED",
		"reason":     "sender gave up",
	})

	// Another session must not be able to fail it (ownership check).
	other := fakeClient("s2", "d2")
	r.OnMessage(other, &Envelope{Type: MsgTransferFailed, Payload: payload})
	if tr, _ := db.GetTransfer(ctx, tid); tr.Status != string(transfer.StatusTransferring) {
		t.Fatalf("status after foreign report = %s, want unchanged", tr.Status)
	}

	// The owning session's report settles the transfer as failed.
	c := fakeClient("s1", "d1")
	r.OnMessage(c, &Envelope{Type: MsgTransferFailed, Payload: payload})

	tr, _ := db.GetTransfer(ctx, tid)
	if tr.Status != string(transfer.StatusFailed) {
		t.Errorf("status = %s, want failed", tr.Status)
	}
	if tr.ErrorCode != "TRANSFER_FAILED" {
		t.Errorf("error_code = %q, want TRANSFER_FAILED", tr.ErrorCode)
	}
	// Note: pushTransferEvent goes through the hub, which only delivers to
	// registered real connections — a fakeClient is not registered, so the
	// WS event itself cannot be asserted here (the DB row is the contract).
}
