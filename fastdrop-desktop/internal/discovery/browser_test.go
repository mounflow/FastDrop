package discovery

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
)

func healthServer(t *testing.T, deviceID string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/health" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"status":     "ok",
			"deviceId":   deviceID,
			"deviceName": "Peer Phone",
			"platform":   "android",
			"protocol":   1,
		})
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestVerifyHostAcceptsFastDropPeer(t *testing.T) {
	srv := healthServer(t, "peer-1")
	host, portStr, _ := net.SplitHostPort(srv.Listener.Addr().String())
	port, _ := strconv.Atoi(portStr)
	opts := &scanOptions{localDeviceID: "self", client: srv.Client()}

	dev, ok := verifyHost(context.Background(), opts, host, port, true)
	if !ok {
		t.Fatal("expected the peer to verify")
	}
	if dev.DeviceID != "peer-1" || dev.DeviceName != "Peer Phone" {
		t.Errorf("identity = %s/%s, want peer-1/Peer Phone", dev.DeviceID, dev.DeviceName)
	}
	if dev.Platform != "android" || dev.Protocol != 1 {
		t.Errorf("platform/protocol = %s/%d", dev.Platform, dev.Protocol)
	}
	if !dev.ViaMDNS {
		t.Error("ViaMDNS flag not preserved")
	}
}

func TestVerifyHostRejectsSelfAndNonFastDrop(t *testing.T) {
	srv := healthServer(t, "self")
	host, portStr, _ := net.SplitHostPort(srv.Listener.Addr().String())
	port, _ := strconv.Atoi(portStr)

	// Self: same deviceId as the scanner must be excluded.
	selfOpts := &scanOptions{localDeviceID: "self", client: srv.Client()}
	if _, ok := verifyHost(context.Background(), selfOpts, host, port, false); ok {
		t.Error("self should not verify as a nearby peer")
	}

	// A non-FastDrop HTTP server (wrong body) must be rejected.
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("hello"))
	}))
	defer plain.Close()
	plainHost, plainPortStr, _ := net.SplitHostPort(plain.Listener.Addr().String())
	plainPort, _ := strconv.Atoi(plainPortStr)
	if _, ok := verifyHost(context.Background(), selfOpts, plainHost, plainPort, false); ok {
		t.Error("non-FastDrop server should not verify")
	}
}

func TestSplitIPv4PrivateOnly(t *testing.T) {
	cases := map[string]string{
		"192.168.1.29": "192.168.1",
		"10.0.0.5":     "10.0.0",
		"172.16.3.4":   "172.16.3",
		"127.0.0.1":    "",
		"8.8.8.8":      "",
		"not-an-ip":    "",
		"198.18.0.1":   "",
		"172.32.0.1":   "",
	}
	for input, want := range cases {
		if got := splitIPv4(input); got != want {
			t.Errorf("splitIPv4(%q) = %q, want %q", input, got, want)
		}
	}
}

// Regression (问题 10 live test): the machine's own IP must exclude only that
// single host from the sweep — filtering it during subnet collection emptied
// the entire sweep on single-NIC machines.
func TestLocalSubnetsCoversOwnSubnet(t *testing.T) {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		t.Skipf("interface addrs unavailable: %v", err)
	}
	subnets := localSubnets()
	found := false
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP.To4() == nil || ipNet.IP.IsLoopback() {
			continue
		}
		subnet := splitIPv4(ipNet.IP.To4().String())
		if subnet == "" {
			continue
		}
		found = true
		covered := false
		for _, s := range subnets {
			if s == subnet {
				covered = true
				break
			}
		}
		if !covered {
			t.Errorf("localSubnets() missing own subnet %s (got %v)", subnet, subnets)
		}
	}
	if !found {
		t.Skip("no private IPv4 on this machine")
	}
}
