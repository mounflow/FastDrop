package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/transfer"
)

// DesktopBridge exposes operations that are only available to the embedded
// Windows desktop UI. They deliberately stay out of the LAN HTTP API.
type DesktopBridge struct {
	db         *database.DB
	revealPath func(string) error
}

func newDesktopBridge(db *database.DB) *DesktopBridge {
	return &DesktopBridge{db: db, revealPath: revealInFileManager}
}

// RevealTransfer selects the first completed file from an inbound transfer in
// Windows Explorer. The transfer ID is resolved through SQLite so the UI can
// never pass an arbitrary filesystem path to the native process.
func (b *DesktopBridge) RevealTransfer(transferID string) error {
	if transferID == "" {
		return errors.New("传输记录无效")
	}

	transferRow, err := b.db.GetTransfer(context.Background(), transferID)
	if err != nil {
		return errors.New("找不到这条传输记录")
	}
	if transferRow.Direction != string(transfer.DirClientToServer) {
		return errors.New("只有本机接收的文件可以定位")
	}
	if transferRow.Status != string(transfer.StatusCompleted) {
		return errors.New("文件尚未接收完成")
	}

	files, err := b.db.ListTransferFiles(context.Background(), transferID)
	if err != nil {
		return fmt.Errorf("读取文件记录失败: %w", err)
	}
	for _, file := range files {
		if file.Status != string(transfer.StatusCompleted) || file.TargetPath == "" {
			continue
		}
		info, statErr := os.Stat(file.TargetPath)
		if statErr != nil || info.IsDir() {
			continue
		}
		return b.revealPath(file.TargetPath)
	}
	return errors.New("接收文件已被移动或删除")
}
