package websocket

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Validator abstracts session-token verification. It is implemented by
// the session package; tests inject a stub.
type Validator interface {
	Validate(ctx context.Context, sessionID, token, sourceIP string, enforceIP bool) (deviceID string, err error)
}

// Client is a single authenticated WS connection.
type Client struct {
	conn       *websocket.Conn
	sessionID  string
	deviceID   string
	sourceIP   string
	send       chan []byte
	hub        *Hub
	lastPong   time.Time
	missedPongs int
	hmu        sync.Mutex // guards lastPong / missedPongs
}

// Hub routes messages between the server and connected clients, and runs
// the heartbeat loop (spec §19).
type Hub struct {
	mu          sync.RWMutex
	clients     map[string]*Client // sessionID -> client
	validator   Validator
	register    chan *Client
	unregister  chan *Client
	broadcast   chan broadcast
	authTimeout time.Duration

	// Per-session inbox for offline messages (waiting for reconnect).
	inboxesMu sync.Mutex
	inboxes   map[string][][]byte
}

type broadcast struct {
	sessionID string
	data      []byte
}

// NewHub constructs a Hub with the given validator.
func NewHub(v Validator) *Hub {
	return &Hub{
		clients:     make(map[string]*Client),
		validator:   v,
		register:    make(chan *Client, 16),
		unregister:  make(chan *Client, 16),
		broadcast:   make(chan broadcast, 64),
		authTimeout: 10 * time.Second,
		inboxes:     make(map[string][][]byte),
	}
}

// Run processes registration / unregistration / broadcast events. It runs
// until ctx is done.
func (h *Hub) Run(ctx context.Context) {
	ticker := time.NewTicker(HeartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case c := <-h.register:
			h.mu.Lock()
			// Drop any existing client on the same session (single-session policy).
			if old, ok := h.clients[c.sessionID]; ok {
				close(old.send)
				_ = old.conn.Close()
			}
			h.clients[c.sessionID] = c
			h.mu.Unlock()
			// Flush any queued messages.
			h.inboxesMu.Lock()
			if queued, ok := h.inboxes[c.sessionID]; ok {
				delete(h.inboxes, c.sessionID)
				h.inboxesMu.Unlock()
				for _, msg := range queued {
					select {
					case c.send <- msg:
					default:
					}
				}
			} else {
				h.inboxesMu.Unlock()
			}
		case c := <-h.unregister:
			h.mu.Lock()
			if existing, ok := h.clients[c.sessionID]; ok && existing == c {
				delete(h.clients, c.sessionID)
				close(c.send)
			}
			h.mu.Unlock()
		case b := <-h.broadcast:
			h.mu.RLock()
			c, ok := h.clients[b.sessionID]
			h.mu.RUnlock()
			if ok {
				select {
				case c.send <- b.data:
				default:
					// Backpressure: enqueue for next reconnect.
					h.enqueueInbox(b.sessionID, b.data)
				}
			} else {
				h.enqueueInbox(b.sessionID, b.data)
			}
		case <-ticker.C:
			h.sendHeartbeats(ctx)
		}
	}
}

// Send delivers a message to the session's WS client, or queues it if offline.
func (h *Hub) Send(sessionID string, msg *Envelope) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	select {
	case h.broadcast <- broadcast{sessionID: sessionID, data: data}:
	default:
		h.enqueueInbox(sessionID, data)
	}
	return nil
}

func (h *Hub) enqueueInbox(sessionID string, data []byte) {
	h.inboxesMu.Lock()
	defer h.inboxesMu.Unlock()
	q := h.inboxes[sessionID]
	if len(q) > 200 {
		// Drop oldest — bound memory.
		q = q[1:]
	}
	h.inboxes[sessionID] = append(q, data)
}

func (h *Hub) sendHeartbeats(ctx context.Context) {
	h.mu.RLock()
	clients := make([]*Client, 0, len(h.clients))
	for _, c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.RUnlock()
	for _, c := range clients {
		c.hmu.Lock()
		c.missedPongs++
		drop := c.missedPongs > MissedPongsThreshold
		c.hmu.Unlock()
		if drop {
			h.unregister <- c
			_ = c.conn.Close()
			continue
		}
		_ = c.writeControl(websocket.PingMessage, nil)
	}
}

// HandleConn runs the read/write loops for one WS connection. It blocks
// until the connection closes.
//
// On the very first frame, if headers didn't already authenticate, the
// client MUST send {type:"auth"}; any other type closes the connection.
func (h *Hub) HandleConn(ctx context.Context, conn *websocket.Conn, sourceIP string, preAuthed *PreAuth) error {
	c := &Client{
		conn:     conn,
		sourceIP: sourceIP,
		send:     make(chan []byte, 32),
		hub:      h,
		lastPong: time.Now(),
	}
	// Determine authentication state.
	if preAuthed != nil {
		c.sessionID = preAuthed.SessionID
		c.deviceID = preAuthed.DeviceID
	} else {
		// Wait for the first auth message.
		if err := h.awaitAuth(ctx, c); err != nil {
			return err
		}
	}

	// Register and start loops.
	h.register <- c
	defer func() { h.unregister <- c }()

	// Set pong handler to reset the missed counter.
	conn.SetPongHandler(func(string) error {
		c.hmu.Lock()
		c.missedPongs = 0
		c.lastPong = time.Now()
		c.hmu.Unlock()
		return nil
	})

	// Reader goroutine: pushes inbound messages to the hub (currently only
	// consumes them; routing is a no-op until business logic is added).
	done := make(chan struct{})
	go c.writeLoop(done)
	defer close(done)

	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				log.Printf("[ws] read error session=%s: %v", maskID(c.sessionID), err)
			}
			return err
		}
		var env Envelope
		if err := json.Unmarshal(data, &env); err != nil {
			_ = h.sendError(c, "INVALID_REQUEST", "malformed envelope")
			continue
		}
		// Heartbeats are handled at protocol level.
		switch env.Type {
		case MsgHeartbeatPing:
			pong, _ := NewEnvelope(MsgHeartbeatPong, nil)
			_ = c.sendEnvelope(pong)
			continue
		}
		// Forward to handler hook (set by callers via OnMessage). For now,
		// just log message type.
		log.Printf("[ws] received type=%s session=%s", env.Type, maskID(c.sessionID))
	}
}

// PreAuth is supplied when the WS handshake already carried valid
// Authorization headers (preferred per §7.3).
type PreAuth struct {
	SessionID string
	DeviceID  string
}

// awaitAuth blocks for the first message, validates it via the validator,
// and populates the client's session/device IDs.
func (h *Hub) awaitAuth(ctx context.Context, c *Client) error {
	_ = c.conn.SetReadDeadline(time.Now().Add(h.authTimeout))
	_, data, err := c.conn.ReadMessage()
	if err != nil {
		return err
	}
	var env Envelope
	if err := json.Unmarshal(data, &env); err != nil || env.Type != MsgAuth {
		return errors.New("first WS message must be auth")
	}
	var p AuthPayload
	if err := json.Unmarshal(env.Payload, &p); err != nil {
		return err
	}
	devID, err := h.validator.Validate(ctx, p.SessionID, p.AccessToken, c.sourceIP, true)
	if err != nil {
		res, _ := NewEnvelope(MsgAuthResult, AuthResultPayload{OK: false, Error: err.Error()})
		_ = c.sendEnvelope(res)
		return err
	}
	c.sessionID = p.SessionID
	c.deviceID = devID
	res, _ := NewEnvelope(MsgAuthResult, AuthResultPayload{OK: true})
	_ = c.sendEnvelope(res)
	_ = c.conn.SetReadDeadline(time.Time{})
	return nil
}

func (h *Hub) sendError(c *Client, code, message string) error {
	env, _ := NewEnvelope(MsgError, map[string]any{"code": code, "message": message})
	return c.sendEnvelope(env)
}

func (c *Client) sendEnvelope(env *Envelope) error {
	data, _ := json.Marshal(env)
	select {
	case c.send <- data:
		return nil
	default:
		return errors.New("client send buffer full")
	}
}

func (c *Client) writeLoop(done <-chan struct{}) {
	for {
		select {
		case <-done:
			return
		case msg, ok := <-c.send:
			if !ok {
				_ = c.conn.Close()
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		}
	}
}

func (c *Client) writeControl(msgType int, _ []byte) error {
	deadline := time.Now().Add(5 * time.Second)
	return c.conn.WriteControl(msgType, []byte{}, deadline)
}

// maskID returns the last 4 chars of an ID for safe logging (spec §33).
func maskID(id string) string {
	if len(id) <= 4 {
		return "****"
	}
	return "****" + id[len(id)-4:]
}
