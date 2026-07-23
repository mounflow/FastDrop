package discovery

import (
	"context"
	"log"
	"sync"
)

// Controller wraps the mDNS publisher and a NoopPublisher, allowing
// the active one to be swapped at runtime via SetEnabled without
// restarting the server. Thread-safe.
//
// Phase 1: starts with NoopPublisher (mDNS off).
// Phase 2: callers flip the toggle through PUT /api/v1/settings
// {mdnsEnabled: true/false} — the controller stops the old publisher
// and starts the new one in its place.
type Controller struct {
	mu      sync.Mutex
	enabled bool          // current state
	mdns    *MdnsPublisher
	noop    NoopPublisher
	info    ServiceInfo
	ctx     context.Context
}

// NewController returns a Controller whose initial enabled state
// matches the persisted config flag.
func NewController(enabled bool) *Controller {
	return &Controller{
		enabled: enabled,
		mdns:    NewMdnsPublisher(),
	}
}

// Start launches whichever publisher is currently active. Implements
// DiscoveryPublisher so callers (main.go) can use a Controller
// wherever they previously used a raw publisher.
func (c *Controller) Start(ctx context.Context, info ServiceInfo) error {
	c.mu.Lock()
	c.info = info
	c.ctx = ctx
	enabled := c.enabled
	c.mu.Unlock()

	if enabled {
		return c.mdns.Start(ctx, info)
	}
	return c.noop.Start(ctx, info)
}

// Stop shuts down whichever publisher is currently active.
func (c *Controller) Stop() error {
	c.mu.Lock()
	enabled := c.enabled
	c.mu.Unlock()

	if enabled {
		return c.mdns.Stop()
	}
	return c.noop.Stop()
}

// SetEnabled toggles mDNS on or off at runtime. If the new state
// matches the current state, it is a no-op. Otherwise the active
// publisher is stopped and the other is started using the ServiceInfo
// from the previous Start call.
func (c *Controller) SetEnabled(enabled bool) error {
	c.mu.Lock()
	if c.enabled == enabled {
		c.mu.Unlock()
		return nil
	}
	wasEnabled := c.enabled
	c.enabled = enabled
	info := c.info
	ctx := c.ctx
	c.mu.Unlock()

	// Tear down whatever's currently running.
	if wasEnabled {
		_ = c.mdns.Stop()
	} else {
		_ = c.noop.Stop()
	}

	// Start the other one.
	if enabled {
		log.Printf("[discovery] enabling mDNS (hot-toggle)")
		return c.mdns.Start(ctx, info)
	}
	log.Printf("[discovery] disabling mDNS (hot-toggle)")
	return c.noop.Start(ctx, info)
}

// IsEnabled reports whether mDNS broadcasting is currently active.
func (c *Controller) IsEnabled() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.enabled
}

// Compile-time check: Controller itself satisfies the publisher
// interface so it can be a drop-in replacement.
var _ DiscoveryPublisher = (*Controller)(nil)
