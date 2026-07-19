package discovery

import (
	"context"
	"log"
)

// NoopPublisher is the Phase-1 default. It satisfies DiscoveryPublisher
// without advertising anything on the network. Phase 2 swaps this out for
// MdnsPublisher.
type NoopPublisher struct{}

func (NoopPublisher) Start(_ context.Context, _ ServiceInfo) error {
	log.Println("[discovery] noop publisher: mDNS disabled (Phase 1)")
	return nil
}
func (NoopPublisher) Stop() error { return nil }

// Compile-time check.
var _ DiscoveryPublisher = NoopPublisher{}
