package websocket

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
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
		_ = h.HandleConn(ctx, conn, "1.2.3.4", nil)
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
		_ = h.HandleConn(ctx, conn, "1.2.3.4", nil)
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
		_ = h.HandleConn(ctx, conn, "1.2.3.4", nil)
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
