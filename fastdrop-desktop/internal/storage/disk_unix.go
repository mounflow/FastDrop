//go:build !windows

package storage

import "syscall"

// freeBytesWindows is the unix fallback for tests on non-Windows hosts.
func freeBytesWindows(path string) (int64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, err
	}
	return int64(stat.Bavail) * int64(stat.Bsize), nil
}
