package discovery

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/hashicorp/mdns"
)

// NearbyDevice is a verified FastDrop peer found on the LAN (问题 10).
type NearbyDevice struct {
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
	Platform   string `json:"platform"`
	Protocol   int    `json:"protocol"`
	Host       string `json:"host"`
	Port       int    `json:"port"`
	ViaMDNS    bool   `json:"viaMdns"`
}

// DefaultPort is the port the subnet sweep probes; mDNS answers may carry
// peers listening on other ports and are verified against their own port.
const DefaultPort = 9527

const (
	mdnsWindow = 2 * time.Second // how long to listen for mDNS answers
	// probeTimeout must tolerate Wi-Fi power-save wake-up (ARP + radio wake
	// can take >1s for the first packet to a dozing phone), so it is well
	// above a normal LAN RTT.
	probeTimeout     = 1500 * time.Millisecond
	sweepConcurrency = 64
	maxSubnets       = 2 // bound total sweep time on multi-NIC machines
	sweepPasses      = 2 // re-sweep once when the first pass finds nothing
)

type candidate struct {
	host    string
	port    int
	viaMDNS bool
}

type scanOptions struct {
	localDeviceID string
	client        *http.Client
	scanSubnets   bool
	skipIPs       map[string]bool
}

// DiscoverNearby finds FastDrop peers on the LAN: candidates are seeded from
// an mDNS query of "_fastdrop._tcp" plus a /24 subnet sweep of the health
// endpoint, and every candidate is verified against its /health identity
// before being returned (TXT records are hints only — the phone's discovery
// follows the same model to defeat fake-IP DNS proxies). Self is excluded by
// deviceId. When the first pass finds nothing, the sweep runs once more:
// power-save wake-up and ARP delays routinely swallow first probes.
func DiscoverNearby(ctx context.Context, localDeviceID string) ([]NearbyDevice, error) {
	client := &http.Client{Timeout: probeTimeout}
	opts := &scanOptions{
		localDeviceID: localDeviceID,
		client:        client,
		scanSubnets:   true,
		skipIPs:       localIPSet(),
	}

	var wg sync.WaitGroup
	candidates := make(chan candidate, 256)

	wg.Add(1)
	go func() {
		defer wg.Done()
		seedFromMDNS(candidates)
	}()
	wg.Add(1)
	go func() {
		defer wg.Done()
		seedFromSubnets(ctx, opts, candidates)
	}()

	go func() {
		wg.Wait()
		close(candidates)
	}()

	devices := verifyCandidates(ctx, opts, candidates)
	if len(devices) == 0 {
		// Second sweep pass: power-save wake-up swallows first probes, and
		// mDNS announcements are often missed across power-save cycles.
		select {
		case <-ctx.Done():
			return devices, nil
		default:
		}
		candidates2 := make(chan candidate, 256)
		var wg2 sync.WaitGroup
		wg2.Add(1)
		go func() {
			defer wg2.Done()
			seedFromSubnets(ctx, opts, candidates2)
		}()
		go func() {
			wg2.Wait()
			close(candidates2)
		}()
		devices = verifyCandidates(ctx, opts, candidates2)
	}
	return devices, nil
}

// seedFromMDNS listens for _fastdrop._tcp answers for mdnsWindow.
func seedFromMDNS(out chan<- candidate) {
	entries := make(chan *mdns.ServiceEntry, 64)
	qp := &mdns.QueryParam{
		Service: "_fastdrop._tcp",
		Domain:  "local",
		Timeout: mdnsWindow,
		Entries: entries,
	}
	go func() {
		_ = mdns.Query(qp)
		close(entries)
	}()
	for entry := range entries {
		if entry == nil || entry.AddrV4 == nil || entry.Port <= 0 {
			continue
		}
		out <- candidate{
			host:    entry.AddrV4.String(),
			port:    entry.Port,
			viaMDNS: true,
		}
	}
}

// seedFromSubnets sweeps each local /24 and emits every address as a
// candidate; verification happens once, in verifyCandidates.
func seedFromSubnets(ctx context.Context, opts *scanOptions, out chan<- candidate) {
	subnets := localSubnets()
	if len(subnets) == 0 {
		return
	}
	if len(subnets) > maxSubnets {
		subnets = subnets[:maxSubnets]
	}
	for _, subnet := range subnets {
		select {
		case <-ctx.Done():
			return
		default:
		}
		var wg sync.WaitGroup
		sem := make(chan struct{}, sweepConcurrency)
		for i := 1; i <= 254; i++ {
			host := subnet + "." + strconv.Itoa(i)
			wg.Add(1)
			go func(host string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				if opts.skipIPs[host] {
					return
				}
				out <- candidate{host: host, port: DefaultPort}
			}(host)
		}
		wg.Wait()
	}
}

// verifyCandidates consumes candidates and returns verified, deduped peers.
func verifyCandidates(ctx context.Context, opts *scanOptions, candidates <-chan candidate) []NearbyDevice {
	var mu sync.Mutex
	byID := map[string]NearbyDevice{}
	var wg sync.WaitGroup
	sem := make(chan struct{}, sweepConcurrency)
	for c := range candidates {
		wg.Add(1)
		go func(c candidate) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			dev, ok := verifyHost(ctx, opts, c.host, c.port, c.viaMDNS)
			if !ok {
				return
			}
			mu.Lock()
			defer mu.Unlock()
			if existing, seen := byID[dev.DeviceID]; seen {
				// Keep the mDNS sighting (may carry a non-default port).
				if !existing.ViaMDNS && dev.ViaMDNS {
					byID[dev.DeviceID] = dev
				}
				return
			}
			byID[dev.DeviceID] = dev
		}(c)
	}
	wg.Wait()

	out := make([]NearbyDevice, 0, len(byID))
	for _, dev := range byID {
		out = append(out, dev)
	}
	return out
}

// verifyHost probes /api/v1/health and returns a NearbyDevice when the host
// is a FastDrop peer with a usable identity distinct from ourselves.
func verifyHost(ctx context.Context, opts *scanOptions, host string, port int, viaMDNS bool) (NearbyDevice, bool) {
	if port <= 0 {
		port = DefaultPort
	}
	url := fmt.Sprintf("http://%s:%d/api/v1/health", host, port)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return NearbyDevice{}, false
	}
	resp, err := opts.client.Do(req)
	if err != nil {
		return NearbyDevice{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return NearbyDevice{}, false
	}
	var health struct {
		Status     string `json:"status"`
		DeviceID   string `json:"deviceId"`
		DeviceName string `json:"deviceName"`
		Platform   string `json:"platform"`
		Protocol   int    `json:"protocol"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		return NearbyDevice{}, false
	}
	if health.Status != "ok" ||
		health.DeviceID == "" ||
		health.DeviceName == "" ||
		health.Platform == "" ||
		health.Protocol != 1 ||
		health.DeviceID == opts.localDeviceID {
		return NearbyDevice{}, false
	}
	return NearbyDevice{
		DeviceID:   health.DeviceID,
		DeviceName: health.DeviceName,
		Platform:   health.Platform,
		Protocol:   health.Protocol,
		Host:       host,
		Port:       port,
		ViaMDNS:    viaMDNS,
	}, true
}

// localSubnets returns the /24 prefixes of private, non-loopback IPv4
// addresses on this machine (deduped). The machine's own addresses must NOT
// remove their whole /24 here — own-IP exclusion happens per candidate in
// seedFromSubnets (skipping own /32 would otherwise empty the sweep entirely
// on single-NIC machines).
func localSubnets() []string {
	seen := map[string]bool{}
	var out []string
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP.To4() == nil || ipNet.IP.IsLoopback() {
			continue
		}
		subnet := splitIPv4(ipNet.IP.To4().String())
		if subnet == "" {
			continue
		}
		if !seen[subnet] {
			seen[subnet] = true
			out = append(out, subnet)
		}
	}
	return out
}

// splitIPv4 returns the first three octets ("192.168.1") of a dotted IPv4
// address, or "" when the address is not private.
func splitIPv4(ip string) string {
	var a, b, c, d int
	if _, err := fmt.Sscanf(ip, "%d.%d.%d.%d", &a, &b, &c, &d); err != nil {
		return ""
	}
	isPrivate := a == 10 ||
		(a == 172 && b >= 16 && b <= 31) ||
		(a == 192 && b == 168)
	if !isPrivate {
		return ""
	}
	return fmt.Sprintf("%d.%d.%d", a, b, c)
}

// localIPSet returns every IPv4 address of this machine, so the sweep can
// skip the machine's own addresses.
func localIPSet() map[string]bool {
	set := map[string]bool{}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return set
	}
	for _, addr := range addrs {
		if ipNet, ok := addr.(*net.IPNet); ok && ipNet.IP.To4() != nil {
			set[ipNet.IP.To4().String()] = true
		}
	}
	return set
}
