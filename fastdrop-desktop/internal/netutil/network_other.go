//go:build !windows

package netutil

func platformNetworkName() string { return "" }
