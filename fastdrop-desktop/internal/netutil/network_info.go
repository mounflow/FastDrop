package netutil

// NetworkInfo is local runtime metadata shown by the desktop UI. The network
// name is never published through mDNS, QR payloads, logs, or peer APIs.
type NetworkInfo struct {
	Name           string
	Type           string
	LocalAddresses []string
}

// CurrentNetworkInfo returns a privacy-scoped description of this PC's local
// network. Windows Internet Connection Sharing conventionally uses
// 192.168.137.1 for Mobile Hotspot, which is useful even when the upstream
// adapter has no Wi-Fi SSID.
func CurrentNetworkInfo() NetworkInfo {
	return buildNetworkInfo(LANIPv4Addresses(), platformNetworkName())
}

func buildNetworkInfo(addresses []string, wifiName string) NetworkInfo {
	info := NetworkInfo{
		Name:           wifiName,
		Type:           "lan",
		LocalAddresses: append([]string{}, addresses...),
	}
	if wifiName != "" {
		info.Type = "wifi"
	}
	for _, address := range addresses {
		if address == "192.168.137.1" {
			if info.Name == "" {
				info.Name = "Windows 热点"
				info.Type = "hotspot"
			}
			break
		}
	}
	if len(addresses) == 0 {
		info.Name = "未连接局域网"
		info.Type = "offline"
	} else if info.Name == "" {
		info.Name = "局域网"
	}
	return info
}
