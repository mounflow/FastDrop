//go:build windows

package netutil

import (
	"bytes"
	"os/exec"
	"strings"
	"syscall"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

func platformNetworkName() string {
	command := exec.Command("netsh.exe", "wlan", "show", "interfaces")
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	output, err := command.Output()
	if err != nil {
		return ""
	}
	return parseSSID(decodeCommandOutput(output))
}

func decodeCommandOutput(output []byte) string {
	if utf8.Valid(output) {
		return string(output)
	}
	decoded, _, err := transform.Bytes(simplifiedchinese.GBK.NewDecoder(), output)
	if err != nil {
		return string(bytes.ToValidUTF8(output, []byte{}))
	}
	return string(decoded)
}

func parseSSID(output string) string {
	for _, line := range strings.Split(output, "\n") {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) != "SSID" {
			continue
		}
		name := strings.Trim(strings.TrimSpace(parts[1]), "\"")
		if name != "" && !strings.EqualFold(name, "<unknown ssid>") {
			return name
		}
	}
	return ""
}
