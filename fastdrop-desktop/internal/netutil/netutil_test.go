package netutil

import (
	"net"
	"testing"
)

func TestClassifyAdapter(t *testing.T) {
	cases := []struct {
		name string
		want string
	}{
		// Real adapters → "".
		{"Ethernet", ""},
		{"Wi-Fi", ""},
		{"Local Area Connection", ""},
		{"Ethernet 2", ""},

		// Windows Mobile Hotspot → "hotspot".
		{"vEthernet (LAN Connection* 1)", "hotspot"},
		{"vEthernet (Local Area Connection* 2)", "hotspot"},
		{"vEthernet (LAN connection* 3)", "hotspot"},

		// Blocked virtual adapters.
		{"vEthernet (WSL)", "blocked"},
		{"vEthernet (Default Switch)", "blocked"},
		{"Docker Desktop", "blocked"},
		{"VirtualBox Host-Only", "blocked"},
		{"VMware Network Adapter", "blocked"},
		{"TAP-Windows Adapter V9", "blocked"},
		{"tunnel0", "blocked"},
		{"VPN-Adapter", "blocked"},
		{"Hyper-V Virtual Ethernet", "blocked"},
		{"vEthernet (WSL2)", "blocked"},
	}
	for _, tc := range cases {
		got := classifyAdapter(tc.name)
		if got != tc.want {
			t.Errorf("classifyAdapter(%q) = %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestIsPrivate(t *testing.T) {
	cases := []struct {
		ip   string
		want bool
	}{
		{"10.0.0.1", true},
		{"10.255.255.255", true},
		{"172.16.0.1", true},
		{"172.31.255.255", true},
		{"192.168.1.1", true},
		{"192.168.137.1", true},

		// Not private.
		{"172.15.0.1", false},
		{"172.32.0.1", false},
		{"11.0.0.1", false},
		{"192.169.1.1", false},
		{"8.8.8.8", false},
		{"1.1.1.1", false},
	}
	for _, tc := range cases {
		ip := net.ParseIP(tc.ip)
		if ip == nil {
			t.Fatalf("bad IP: %s", tc.ip)
		}
		got := isPrivate(ip.To4())
		if got != tc.want {
			t.Errorf("isPrivate(%s) = %v, want %v", tc.ip, got, tc.want)
		}
	}
}

func TestLANIPv4AddressesBasic(t *testing.T) {
	// Sanity check: on any real machine this should not panic.
	// We can't assert exact IPs since the test environment varies,
	// but the result must not be nil and must contain valid IPs.
	addrs := LANIPv4Addresses()
	if addrs == nil {
		t.Fatal("LANIPv4Addresses returned nil")
	}
	for _, a := range addrs {
		ip := net.ParseIP(a)
		if ip == nil {
			t.Errorf("invalid IP in result: %q", a)
		}
		if ip.To4() == nil {
			t.Errorf("non-IPv4 address in result: %q", a)
		}
		if !isPrivate(ip.To4()) {
			t.Errorf("non-private address in result: %q", a)
		}
	}
}

func TestPreferLANIPv4(t *testing.T) {
	// Should return either "" or a valid private IPv4.
	ip := PreferLANIPv4()
	if ip == "" {
		t.Skip("no LAN IPv4 found on this machine")
	}
	parsed := net.ParseIP(ip)
	if parsed == nil || parsed.To4() == nil {
		t.Errorf("PreferLANIPv4 returned invalid IP: %q", ip)
	}
}
