// Package websocket implements the FastDrop control channel (spec §4.1, §8).
package websocket

import (
	"encoding/json"
	"time"
)

// ProtocolVersion is the message envelope version (spec §8.1).
const ProtocolVersion = 1

// HeartbeatInterval matches spec §19 (15 seconds).
const HeartbeatInterval = 15 * time.Second

// MissedPongsThreshold — 3 missed pongs = disconnected (§19).
const MissedPongsThreshold = 3

// ReconnectGrace — 60s window before a transfer is marked failed (§19).
const ReconnectGrace = 60 * time.Second

// MessageType enumerates the wire-level type strings from §8.2.
type MessageType string

const (
	MsgAuth            MessageType = "auth"
	MsgAuthResult      MessageType = "auth.result"
	MsgHeartbeatPing   MessageType = "heartbeat.ping"
	MsgHeartbeatPong   MessageType = "heartbeat.pong"
	MsgDeviceInfo      MessageType = "device.info"
	MsgDeviceDisconnect MessageType = "device.disconnect"
	MsgFileOffer       MessageType = "file.offer"
	MsgFileOfferAccept MessageType = "file.offer.accept"
	MsgFileOfferReject MessageType = "file.offer.reject"
	MsgTransferCreated MessageType = "transfer.created"
	MsgTransferStarted MessageType = "transfer.started"
	MsgTransferProgress MessageType = "transfer.progress"
	MsgTransferPaused  MessageType = "transfer.paused"
	MsgTransferResume  MessageType = "transfer.resume"
	MsgTransferCancel  MessageType = "transfer.cancel"
	MsgTransferCancelled MessageType = "transfer.cancelled"
	MsgTransferFailed  MessageType = "transfer.failed"
	MsgTransferVerifying MessageType = "transfer.verifying"
	MsgTransferCompleted MessageType = "transfer.completed"
	MsgSessionRevoked  MessageType = "session.revoked"
	MsgError           MessageType = "error"
)

// Envelope is the universal message wrapper (§8.1).
type Envelope struct {
	Version   int             `json:"version"`
	Type      MessageType     `json:"type"`
	MessageID string          `json:"messageId,omitempty"`
	RequestID string          `json:"requestId,omitempty"`
	Timestamp int64           `json:"timestamp"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}

// NewEnvelope constructs an envelope with a fresh timestamp.
func NewEnvelope(t MessageType, payload any) (*Envelope, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return &Envelope{
		Version:   ProtocolVersion,
		Type:      t,
		Timestamp: time.Now().UnixMilli(),
		Payload:   raw,
	}, nil
}

// AuthPayload is the first-message authentication payload (§7.3).
type AuthPayload struct {
	SessionID    string `json:"sessionId"`
	AccessToken string `json:"accessToken"`
}

// AuthResultPayload is the server's response to an auth message.
type AuthResultPayload struct {
	OK      bool   `json:"ok"`
	Error   string `json:"error,omitempty"`
}
