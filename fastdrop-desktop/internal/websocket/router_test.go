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
	r.OnMessage(c, &Envelope{Type: MsgTransferPaused, Payload: payload})
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
