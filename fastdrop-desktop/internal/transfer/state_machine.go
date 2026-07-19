// Package transfer runs the FastDrop transfer state machine, scheduler,
// progress aggregation, and chunk-retry logic (spec §9, §12, §13, §14, §15).
package transfer

import (
	"errors"
	"fmt"
)

// Status is the canonical state-machine value from §12.
type Status string

const (
	StatusCreated        Status = "created"
	StatusWaitingAccept  Status = "waiting_accept"
	StatusPreparing      Status = "preparing"
	StatusTransferring   Status = "transferring"
	StatusPaused         Status = "paused"
	StatusRetrying       Status = "retrying"
	StatusVerifying      Status = "verifying"
	StatusCompleted      Status = "completed"
	StatusFailed         Status = "failed"
	StatusCancelled      Status = "cancelled"
	StatusRejected       Status = "rejected"
)

// IsTerminal reports whether s represents an end state.
func (s Status) IsTerminal() bool {
	switch s {
	case StatusCompleted, StatusFailed, StatusCancelled, StatusRejected:
		return true
	}
	return false
}

// validTransitions is the closed set of legal (from -> set of to) edges
// from §12.
var validTransitions = map[Status]map[Status]bool{
	StatusCreated: {
		StatusWaitingAccept: true,
		StatusCancelled:     true,
	},
	StatusWaitingAccept: {
		StatusPreparing: true,
		StatusRejected:  true,
		StatusCancelled: true,
		StatusFailed:    true,
	},
	StatusPreparing: {
		StatusTransferring: true,
		StatusFailed:       true,
		StatusCancelled:    true,
	},
	StatusTransferring: {
		StatusPaused:    true,
		StatusVerifying: true,
		StatusFailed:    true,
		StatusCancelled: true,
		StatusRetrying:  true,
	},
	StatusPaused: {
		StatusTransferring: true,
		StatusCancelled:    true,
		StatusFailed:       true,
	},
	StatusRetrying: {
		StatusTransferring: true,
		StatusFailed:       true,
		StatusCancelled:    true,
	},
	StatusVerifying: {
		StatusCompleted: true,
		StatusFailed:    true,
		StatusCancelled: true,
	},
	// Terminal states have no outgoing edges.
}

// CanTransition reports whether transitioning from->to is legal per §12.
func CanTransition(from, to Status) bool {
	if from == to {
		return true // idempotent self-transition allowed (no-op)
	}
	if dests, ok := validTransitions[from]; ok {
		return dests[to]
	}
	return false
}

// TransitionError is returned by Advance when the requested move is illegal.
type TransitionError struct{ From, To Status }

func (e *TransitionError) Error() string {
	return fmt.Sprintf("illegal transfer transition %s -> %s", e.From, e.To)
}

// Advance validates the transition and returns the new status, or
// TransitionError if illegal.
func Advance(from, to Status) (Status, error) {
	if !CanTransition(from, to) {
		return from, &TransitionError{From: from, To: to}
	}
	return to, nil
}

// ErrFileNotFound / ErrTransferNotFound — sentinel errors for callers.
var (
	ErrTransferNotFound = errors.New("transfer not found")
	ErrFileNotFound     = errors.New("file not found")
)
