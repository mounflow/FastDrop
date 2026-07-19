// Package discovery holds the service/abstract types for device
// discovery. Phase 1 ships only the interfaces; Phase 2 adds mDNS.
package discovery

import "context"

// ServiceInfo describes this FastDrop server's announcement.
type ServiceInfo struct {
	DeviceID        string
	DeviceName      string
	Host            string
	Port            int
	ProtocolVersion int
	Platform        string
}

// DiscoveryPublisher advertises this service on the local network.
// Phase-1 implementation: stub publisher (does nothing, never errors).
// Phase-2 implementation: MdnsPublisher registered with _fastdrop._tcp.local.
type DiscoveryPublisher interface {
	Start(ctx context.Context, info ServiceInfo) error
	Stop() error
}

// DiscoveredDevice is what a (mobile) client observes on the network.
// Server-side we keep the type for symmetry and for future browser UI.
type DiscoveredDevice struct {
	DeviceID        string
	DeviceName      string
	Host            string
	Port            int
	ProtocolVersion int
	Platform        string
	PairingRequired bool
	TLS             bool
}

// DeviceDiscovery is the client-side browse API. Implemented by the
// Flutter app; stubbed here for symmetry.
type DeviceDiscovery interface {
	Discover(ctx context.Context) ([]DiscoveredDevice, error)
	Stop() error
}
