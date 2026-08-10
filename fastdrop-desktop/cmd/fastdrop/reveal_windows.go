//go:build windows

package main

import (
	"fmt"
	"os/exec"
)

func revealInFileManager(path string) error {
	if err := exec.Command("explorer.exe", "/select,"+path).Start(); err != nil {
		return fmt.Errorf("打开资源管理器失败: %w", err)
	}
	return nil
}
