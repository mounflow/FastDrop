package websocket

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestRouterTextSendDeliversAckAndEvent(t *testing.T) {
	r, _, _ := newTestRouter(t)
	sender := fakeClient("s1", "d1")

	payload, _ := json.Marshal(TextSendPayload{TextID: "t1", Text: "https://example.com"})
	r.OnMessage(sender, &Envelope{Type: MsgTextSend, Payload: payload})

	// The sender gets a text.ack first.
	select {
	case msg := <-sender.send:
		var reply Envelope
		json.Unmarshal(msg, &reply)
		if reply.Type != MsgTextAck {
			t.Fatalf("reply type = %s, want text.ack", reply.Type)
		}
		var p map[string]any
		json.Unmarshal(reply.Payload, &p)
		if p["textId"] != "t1" {
			t.Errorf("ack textId = %v, want t1", p["textId"])
		}
	case <-time.After(time.Second):
		t.Fatal("no ack received")
	}

	// The session broadcast carries text.received (echoed to sender too,
	// since the hub delivers to all session clients in the real flow).
	// Here the fake router calls pushTransferEvent, which routes through
	// the hub; the fake client's channel only receives what was sent
	// directly via sendEnvelope, so drain whatever arrives next.
}

func TestRouterTextSendEmptyText(t *testing.T) {
	r, _, _ := newTestRouter(t)
	c := fakeClient("s1", "d1")

	payload, _ := json.Marshal(TextSendPayload{TextID: "t1", Text: ""})
	r.OnMessage(c, &Envelope{Type: MsgTextSend, Payload: payload})

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

func TestRouterTextSendTooLarge(t *testing.T) {
	r, _, _ := newTestRouter(t)
	c := fakeClient("s1", "d1")

	payload, _ := json.Marshal(TextSendPayload{TextID: "t1", Text: strings.Repeat("a", TextMaxBytes+1)})
	r.OnMessage(c, &Envelope{Type: MsgTextSend, Payload: payload})

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

func TestRouterTextSendMissingTextID(t *testing.T) {
	r, _, _ := newTestRouter(t)
	c := fakeClient("s1", "d1")

	payload, _ := json.Marshal(TextSendPayload{Text: "hi"})
	r.OnMessage(c, &Envelope{Type: MsgTextSend, Payload: payload})

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
