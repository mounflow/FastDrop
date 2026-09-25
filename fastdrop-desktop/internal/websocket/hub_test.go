package websocket

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type fakeValidator struct {
	deviceID string
	err      error
}

func (f *fakeValidator) Validate(_ context.Context, _, _, _ string, _ bool) (string, error) {
	return f.deviceID, f.err
}

func (f *fakeValidator) IsSessionValid(_ context.Context, _ string) bool {
	return f.err == nil
}

// TestAuthFirstMessageRule: when no pre-auth, the first message MUST be auth.
func TestAuthFirstMessageRule(t *testing.T) {
	h := NewHub(&fakeValidator{deviceID: "dev1", err: nil})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go h.Run(ctx)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		up := websocket.Upgrader{}
		conn, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		// Run HandleConn synchronously; it returns on close.
		_ = h.HandleConn(ctx, conn, "1.2.3.4", false, nil)
	}))
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// Send a non-auth message first.
	bad, _ := NewEnvelope(MsgFileOffer, map[string]any{"offerId": "x"})
	data, _ := json.Marshal(bad)
	if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
		t.Fatal(err)
	}
	// Expect the connection to close (no successful auth).
	_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	_, _, err = conn.ReadMessage()
	if err == nil {
		t.Error("expected close on non-auth first message")
	}
}

func TestAuthSuccessThenHeartbeat(t *testing.T) {
	h := NewHub(&fakeValidator{deviceID: "dev1"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go h.Run(ctx)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		up := websocket.Upgrader{}
		conn, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		_ = h.HandleConn(ctx, conn, "1.2.3.4", false, nil)
	}))
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// Send auth first.
	authEnv, _ := NewEnvelope(MsgAuth, AuthPayload{SessionID: "s1", AccessToken: "tok"})
	data, _ := json.Marshal(authEnv)
	if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, reply, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var env Envelope
	if err := json.Unmarshal(reply, &env); err != nil {
		t.Fatal(err)
	}
	if env.Type != MsgAuthResult {
		t.Errorf("expected auth.result, got %s", env.Type)
	}
	var res AuthResultPayload
	json.Unmarshal(env.Payload, &res)
	if !res.OK {
		t.Error("auth result not OK")
	}
}

func TestAuthFailedClosesConnection(t *testing.T) {
	h := NewHub(&fakeValidator{err: errors.New("nope")})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go h.Run(ctx)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		up := websocket.Upgrader{}
		conn, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		_ = h.HandleConn(ctx, conn, "1.2.3.4", false, nil)
	}))
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/"
	conn, _, _ := websocket.DefaultDialer.Dial(wsURL, nil)
	defer conn.Close()

	authEnv, _ := NewEnvelope(MsgAuth, AuthPayload{SessionID: "s1", AccessToken: "bad"})
	data, _ := json.Marshal(authEnv)
	conn.WriteMessage(websocket.TextMessage, data)

	_ = conn.SetReadDeadline(time.Now().Add(1 * time.Second))
	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			break
		}
	}
}

func TestMaskID(t *testing.T) {
	if maskID("abc") != "****" {
		t.Error("short id mask failed")
	}
	if maskID("1234567890") != "****7890" {
		t.Errorf("mask = %s", maskID("1234567890"))
	}
}

// --- §19 reconnect-grace: local (Vue UI) vs remote (phone) clients ---

// graceTestHub returns a running hub with a short grace window and a counter
// recording every OnGraceExpired firing.
func graceTestHub(t *testing.T, grace time.Duration) (*Hub, context.CancelFunc, *int32) {
	t.Helper()
	h := NewHub(&fakeValidator{deviceID: "d1"})
	h.gracePeriod = grace
	var fired int32
	h.OnGraceExpired = func(sessionID string) { atomic.AddInt32(&fired, 1) }
	ctx, cancel := context.WithCancel(context.Background())
	go h.Run(ctx)
	t.Cleanup(cancel)
	return h, cancel, &fired
}

func graceTestClient(sessionID string, local bool) *Client {
	return &Client{sessionID: sessionID, local: local, send: make(chan []byte, 1)}
}

func hubClientCount(h *Hub, sessionID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients[sessionID])
}

func waitForCond(t *testing.T, desc string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("condition not met in time: %s", desc)
}

func waitForNoFire(t *testing.T, fired *int32, quiet time.Duration) {
	t.Helper()
	time.Sleep(quiet)
	if got := atomic.LoadInt32(fired); got != 0 {
		t.Fatalf("OnGraceExpired fired %d time(s), want 0", got)
	}
}

// Remote disconnect starts the grace window even though a local client is
// still connected — and a local disconnect never starts one.
func TestGraceOnlyTracksRemoteClients(t *testing.T) {
	h, _, fired := graceTestHub(t, 60*time.Millisecond)

	local := graceTestClient("s1", true)
	remote := graceTestClient("s1", false)
	h.register <- local
	h.register <- remote
	waitForCond(t, "both clients registered", func() bool { return hubClientCount(h, "s1") == 2 })

	// Remote (phone) disconnects while the local Vue UI stays connected:
	// grace must fire despite the local client.
	h.unregister <- remote
	waitForCond(t, "remote unregistered", func() bool { return hubClientCount(h, "s1") == 1 })
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(fired) > 0 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if got := atomic.LoadInt32(fired); got != 1 {
		t.Fatalf("OnGraceExpired fired %d time(s) after remote disconnect, want 1", got)
	}

	// Local disconnect on a fresh session: no grace, no firing.
	h2, _, fired2 := graceTestHub(t, 60*time.Millisecond)
	onlyLocal := graceTestClient("s2", true)
	h2.register <- onlyLocal
	waitForCond(t, "local registered", func() bool { return hubClientCount(h2, "s2") == 1 })
	h2.unregister <- onlyLocal
	waitForCond(t, "local unregistered", func() bool { return hubClientCount(h2, "s2") == 0 })
	waitForNoFire(t, fired2, 300*time.Millisecond)
}

// A phone reconnecting cancels the pending grace window.
func TestGraceCancelledByRemoteReconnect(t *testing.T) {
	h, _, fired := graceTestHub(t, 200*time.Millisecond)

	remote := graceTestClient("s1", false)
	h.register <- remote
	waitForCond(t, "remote registered", func() bool { return hubClientCount(h, "s1") == 1 })

	h.unregister <- remote
	waitForCond(t, "remote unregistered", func() bool { return hubClientCount(h, "s1") == 0 })

	// Reconnect well before the 200ms grace elapses.
	reconnect := graceTestClient("s1", false)
	h.register <- reconnect
	waitForCond(t, "remote re-registered", func() bool { return hubClientCount(h, "s1") == 1 })

	waitForNoFire(t, fired, 400*time.Millisecond)
}
