package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/transfer"
)

func TestDesktopBridgeRevealTransfer(t *testing.T) {
	db, targetPath, transferID := completedInboundTransfer(t)
	defer db.Close()

	var revealed string
	bridge := &DesktopBridge{
		db: db,
		revealPath: func(path string) error {
			revealed = path
			return nil
		},
	}
	if err := bridge.RevealTransfer(transferID); err != nil {
		t.Fatalf("RevealTransfer: %v", err)
	}
	if revealed != targetPath {
		t.Fatalf("revealed %q, want %q", revealed, targetPath)
	}
}

func TestDesktopBridgeRejectsOutgoingTransfer(t *testing.T) {
	db, _, transferID := completedInboundTransfer(t)
	defer db.Close()
	if _, err := db.Exec(`UPDATE transfers SET direction = 'server_to_client' WHERE id = ?`, transferID); err != nil {
		t.Fatal(err)
	}

	bridge := &DesktopBridge{db: db, revealPath: func(string) error {
		t.Fatal("reveal should not be called")
		return nil
	}}
	if err := bridge.RevealTransfer(transferID); err == nil {
		t.Fatal("expected outgoing transfer to be rejected")
	}
}

func completedInboundTransfer(t *testing.T) (*database.DB, string, string) {
	t.Helper()
	dir := t.TempDir()
	db, err := database.Open(filepath.Join(dir, "fastdrop.db"))
	if err != nil {
		t.Fatal(err)
	}
	targetPath := filepath.Join(dir, "received.txt")
	if err := os.WriteFile(targetPath, []byte("received"), 0o600); err != nil {
		db.Close()
		t.Fatal(err)
	}
	transferID := "transfer-1"
	if err := db.InsertTransfer(context.Background(), database.TransferRow{
		ID: transferID, PeerDeviceID: "phone-1", Direction: string(transfer.DirClientToServer),
		Status: string(transfer.StatusCompleted), TotalFiles: 1, TotalBytes: 8, TransferredBytes: 8,
		CreatedAt: database.Now(),
	}); err != nil {
		db.Close()
		t.Fatal(err)
	}
	if err := db.InsertTransferFile(context.Background(), database.TransferFileRow{
		ID: "file-1", TransferID: transferID, OriginalName: "received.txt",
		TargetPath: targetPath, TotalBytes: 8, TransferredBytes: 8,
		ChunkSize: 4194304, TotalChunks: 1, CompletedChunks: 1,
		Status: string(transfer.StatusCompleted), CreatedAt: database.Now(),
	}); err != nil {
		db.Close()
		t.Fatal(err)
	}
	return db, targetPath, transferID
}
