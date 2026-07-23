package discovery

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"

	"github.com/hashicorp/mdns"
)

// ServiceType is the spec-mandated mDNS service name (§30.1).
const ServiceType = "_fastdrop._tcp.local."

// MdnsPublisher advertises this FastDrop instance on the LAN as
// `_fastdrop._tcp.local.`. TXT records carry the deviceId, name,
// protocol version, platform and pairing requirement — NEVER any token
// (spec §30.2).
type MdnsPublisher struct {
	mu      sync.Mutex
	server  *mdns.Server
	running bool
}

func NewMdnsPublisher() *MdnsPublisher { return &MdnsPublisher{} }

// Start registers the service. info.Host may be empty; if so, the host's
// hostname is used.
func (p *MdnsPublisher) Start(_ context.Context, info ServiceInfo) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.running {
		return fmt.Errorf("mdns publisher already running")
	}
	host := info.DeviceName
	if host == "" {
		host = "FastDrop"
	}
	// hashicorp/mdns rejects non-FQDN hostNames (must end in a dot).
	// info.Host from main.go is a literal IP like "192.168.1.19", which
	// the library won't accept — synthesize "<deviceName>.local."
	// instead and let the library pick the actual interface IPs.
	fqdn := strings.ReplaceAll(host, " ", "-") + ".local."
	// TXT keys follow §30.2.
	txt := []string{
		"id=" + info.DeviceID,
		"name=" + info.DeviceName,
		"version=0.2.0",
		fmt.Sprintf("protocol=%d", info.ProtocolVersion),
		"platform=" + info.Platform,
		"pairing=required",
		"tls=0",
	}
	service, err := mdns.NewMDNSService(
		host,                                      // instance name (human-readable)
		strings.TrimSuffix(ServiceType, ".local."), // "_fastdrop._tcp"
		"",                                        // domain
		fqdn,                                      // hostName (FQDN)
		info.Port,                                 // port
		nil,                                       // IPs (let mdns pick)
		txt,
	)
	if err != nil {
		return fmt.Errorf("new mdns service: %w", err)
	}
	server, err := mdns.NewServer(&mdns.Config{Zone: service})
	if err != nil {
		return fmt.Errorf("new mdns server: %w", err)
	}
	p.server = server
	p.running = true
	log.Printf("[discovery] visible as %s.%s on %s:%d (TXT: id=%s platform=%s protocol=%d)",
		host, ServiceType, hostOrLocal(info.Host), info.Port, info.DeviceID, info.Platform, info.ProtocolVersion)
	return nil
}

// hostOrLocal falls back to "localhost" when info.Host is empty so
// the log line is still readable in single-NIC setups.
func hostOrLocal(h string) string {
	if h == "" {
		return "localhost"
	}
	return h
}

func (p *MdnsPublisher) Stop() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.running || p.server == nil {
		return nil
	}
	err := p.server.Shutdown()
	p.server = nil
	p.running = false
	log.Println("[discovery] mdns publisher stopped")
	return err
}

var _ DiscoveryPublisher = (*MdnsPublisher)(nil)
