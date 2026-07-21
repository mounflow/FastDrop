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
	// IsSessionValid reports whether the session exists and is not expired
	// or revoked. Used for periodic WS connection liveness checks.
	IsSessionValid(ctx context.Context, sessionID string) bool
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

// MessageHandler receives authenticated WS messages for routing to business logic.
type MessageHandler func(c *Client, env *Envelope)

// Hub routes messages between the server and connected clients, and runs
// the heartbeat loop (spec §19).
//
// Multiple WS connections may share the same sessionID (e.g. the PC Vue UI
// and the phone both connect with the session created during pairing). The
// Hub delivers messages to ALL connected clients on a session.
type Hub struct {
	mu          sync.RWMutex
	clients     map[string]map[*Client]bool // sessionID -> set of clients
	validator   Validator
	register    chan *Client
	unregister  chan *Client
	broadcast   chan broadcast
	authTimeout time.Duration

	// OnMessage is called for every non-heartbeat message after auth.
	OnMessage MessageHandler

	// OnGraceExpired is called when a session's 60s reconnect grace period
	// expires without a new connection (§19). The callback should fail
	// active transfers for that session.
	OnGraceExpired func(sessionID string)

	// OnClientConnected / OnClientDisconnected are called after a client
	// registers / unregisters. Used to broadcast device.info /
	// device.disconnect to the session.
	OnClientConnected    func(sessionID, deviceID string)
	OnClientDisconnected func(sessionID, deviceID string)

	// Per-session inbox for offline messages (waiting for reconnect).
	inboxesMu sync.Mutex
	inboxes   map[string][][]byte

	// Grace timers keyed by sessionID — started when the last client
	// disconnects, cancelled on reconnect.
	graceMu     sync.Mutex
	graceTimers map[string]*time.Timer
}

type broadcast struct {
	sessionID string
	data      []byte
}

// NewHub constructs a Hub with the given validator.
func NewHub(v Validator) *Hub {
	return &Hub{
		clients:     make(map[string]map[*Client]bool),
		validator:   v,
		register:    make(chan *Client, 16),
		unregister:  make(chan *Client, 16),
		broadcast:   make(chan broadcast, 64),
		authTimeout: 10 * time.Second,
		inboxes:     make(map[string][][]byte),
		graceTimers: make(map[string]*time.Timer),
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
			// Cancel any pending reconnect-grace timer for this session.
			h.graceMu.Lock()
			if timer, ok := h.graceTimers[c.sessionID]; ok {
				timer.Stop()
				delete(h.graceTimers, c.sessionID)
			}
			h.graceMu.Unlock()
			h.mu.Lock()
			set := h.clients[c.sessionID]
			if set == nil {
				set = make(map[*Client]bool)
				h.clients[c.sessionID] = set
			}
			set[c] = true
			h.mu.Unlock()
			// Flush any queued messages to the newly connected client.
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
			lastClient := false
			if set, ok := h.clients[c.sessionID]; ok {
				if set[c] {
					delete(set, c)
					close(c.send)
				}
				if len(set) == 0 {
					delete(h.clients, c.sessionID)
					lastClient = true
				}
			}
			h.mu.Unlock()
			// §19: Start 60s reconnect grace when the last client disconnects.
			if lastClient {
				h.startGraceTimer(c.sessionID)
			}
		case b := <-h.broadcast:
			h.mu.RLock()
			set := h.clients[b.sessionID]
			delivered := false
			for c := range set {
				select {
				case c.send <- b.data:
					delivered = true
				default:
				}
			}
			h.mu.RUnlock()
			if !delivered {
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

// startGraceTimer begins the 60s reconnect-grace window for a session.
// If no client reconnects before it fires, OnGraceExpired is called.
func (h *Hub) startGraceTimer(sessionID string) {
	h.graceMu.Lock()
	defer h.graceMu.Unlock()
	if _, exists := h.graceTimers[sessionID]; exists {
		return // already ticking
	}
	h.graceTimers[sessionID] = time.AfterFunc(ReconnectGrace, func() {
		h.graceMu.Lock()
		delete(h.graceTimers, sessionID)
		h.graceMu.Unlock()
		if h.OnGraceExpired != nil {
			h.OnGraceExpired(sessionID)
		}
	})
}

func (h *Hub) sendHeartbeats(ctx context.Context) {
	h.mu.RLock()
	clients := make([]*Client, 0)
	for _, set := range h.clients {
		for c := range set {
			clients = append(clients, c)
		}
	}
	h.mu.RUnlock()
	for _, c := range clients {
		// Periodic session-expiry check: if the session has been revoked
		// or expired, disconnect the client.
		if h.validator != nil && !h.validator.IsSessionValid(ctx, c.sessionID) {
			_ = h.sendError(c, "SESSION_EXPIRED", "session expired or revoked")
			h.unregister <- c
			_ = c.conn.Close()
			continue
		}
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
	if h.OnClientConnected != nil {
		h.OnClientConnected(c.sessionID, c.deviceID)
	}
	defer func() {
		if h.OnClientDisconnected != nil {
			h.OnClientDisconnected(c.sessionID, c.deviceID)
		}
		h.unregister <- c
	}()

	// Set pong handler to reset the missed counter.
	conn.SetPongHandler(func(string) error {
		c.hmu.Lock()
		c.missedPongs = 0
		c.lastPong = time.Now()
		c.hmu.Unlock()
		return nil
	})

	// Reader goroutine: inbound messages are decoded here. Heartbeats are
	// answered inline; everything else is forwarded to OnMessage (set by
	// the caller — typically *websocket.Router).
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
		if h.OnMessage != nil {
			h.OnMessage(c, &env)
		}
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
	// enforceIP=false: the same session is shared by the PC browser
	// (127.0.0.1) and the phone (LAN IP), so strict IP binding would
	// reject valid WS connections.
	devID, err := h.validator.Validate(ctx, p.SessionID, p.AccessToken, c.sourceIP, false)
	if err != nil {
		res, _ := NewEnvelope(MsgAuthResult, AuthResultPayload{OK: false, Error: err.Error()})
		// Write directly to the conn — writeLoop isn't running yet
		// because it only starts after successful auth.
		data, _ := json.Marshal(res)
		_ = c.conn.WriteMessage(websocket.TextMessage, data)
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
