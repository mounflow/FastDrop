//go:build !windows

package main

import "errors"

func revealInFileManager(string) error {
	return errors.New("当前平台不支持打开文件位置")
}
