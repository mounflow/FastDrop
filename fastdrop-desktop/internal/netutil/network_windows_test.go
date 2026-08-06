//go:build windows

package netutil

import "testing"

func TestParseSSID(t *testing.T) {
	output := `
    Name                   : Wi-Fi
    State                  : connected
    SSID                   : FastDrop Lab
    BSSID                  : 00:11:22:33:44:55
`
	if got := parseSSID(output); got != "FastDrop Lab" {
		t.Fatalf("parseSSID=%q", got)
	}
	if got := parseSSID("SSID : <unknown ssid>"); got != "" {
		t.Fatalf("unknown SSID=%q", got)
	}
}
