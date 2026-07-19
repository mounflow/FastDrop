package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"fastdrop-desktop/internal/config"
	"fastdrop-desktop/internal/database"
	"fastdrop-desktop/internal/pairing"
	"fastdrop-desktop/internal/session"
	"fastdrop-desktop/internal/storage"
	"fastdrop-desktop/internal/transfer"
)

func newTestServer(t *testing.T) (*Server, *config.Config) {
	t.Helper()
	cfg := config.Default()
	cfg.Server.DeviceName = "TestPC"
	cfg.Server.BindAddress = "127.0.0.1"
	cfg.Server.Port = 19527
	cfg.Storage.DownloadDirectory = filepath.Join(t.TempDir(), "Downloads")

	db, err := database.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })

	// Seed the local server device.
	_ = db.UpsertDevice(database.Device{ID: "windows-local", Name: "TestPC", Platform: "windows", FirstSeenAt: 1, LastSeenAt: 1})

	pairMgr := pairing.NewManager(time.Minute)
	sessMgr := session.NewManager(db, time.Hour)
	storeMgr, err := storage.NewManager(cfg.Storage.DownloadDirectory)
	if err != nil {
		t.Fatal(err)
	}
	transferMgr := transfer.NewManager(db, cfg.Transfer.ChunkSize, nil)

	srv := &Server{
		Cfg: cfg, DB: db,
		Pairing: pairMgr, Session: sessMgr,
		Transfer: transferMgr, Storage: storeMgr,
	}
	return srv, cfg
}

func TestHealthAndInfo(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	resp, body := doReq(t, ts, "GET", "/api/v1/health", nil, "")
	if resp.StatusCode != 200 {
		t.Fatalf("health status %d", resp.StatusCode)
	}
	if !strings.Contains(body, "ok") {
		t.Errorf("body: %s", body)
	}

	resp, body = doReq(t, ts, "GET", "/api/v1/capabilities", nil, "")
	if resp.StatusCode != 200 || !strings.Contains(body, "chunkSize") {
		t.Errorf("capabilities: %d %s", resp.StatusCode, body)
	}
}

func TestPairFlowEndToEnd(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	// 1. Get a QR payload.
	resp, body := doReq(t, ts, "GET", "/api/v1/pair/qr", nil, "")
	if resp.StatusCode != 200 {
		t.Fatalf("qr: %s", body)
	}
	var qr map[string]any
	json.Unmarshal([]byte(body), &qr)

	// 2. Phone posts pair/request.
	pairBody := map[string]any{
		"pairId": qr["pairId"],
		"token":  qr["token"],
		"device": map[string]any{
			"deviceId": "android-1", "deviceName": "Pixel", "platform": "android", "appVersion": "0.1.0",
		},
	}
	resp, body = doReqJSON(t, ts, "POST", "/api/v1/pair/request", pairBody)
	if resp.StatusCode != 200 {
		t.Fatalf("pair request: %s", body)
	}
	var res map[string]any
	json.Unmarshal([]byte(body), &res)
	reqID := res["requestId"].(string)

	// 3. Polling should still say waiting.
	resp, body = doReq(t, ts, "GET", "/api/v1/pair/requests/"+reqID, nil, "")
	if !strings.Contains(body, "waiting_confirmation") {
		t.Errorf("status not waiting: %s", body)
	}

	// 4. Wrong token / unknown pairID should error.
	resp, body = doReqJSON(t, ts, "POST", "/api/v1/pair/request", map[string]any{
		"pairId": qr["pairId"], "token": "WRONG",
		"device": map[string]any{"deviceId": "x", "deviceName": "y", "platform": "android"},
	})
	if resp.StatusCode != 401 {
		t.Errorf("bad token: %d %s", resp.StatusCode, body)
	}
}

func TestRateLimit(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()
	// Reset the shared limiter.
	pairLimiter = newRateLimiter(3, time.Minute)
	for i := 0; i < 3; i++ {
		resp, _ := doReqJSON(t, ts, "POST", "/api/v1/pair/request", map[string]any{
			"pairId": "nope", "token": "x",
			"device": map[string]any{"deviceId": "x", "deviceName": "y", "platform": "android"},
		})
		if resp.StatusCode == http.StatusTooManyRequests {
			t.Fatalf("request %d rate-limited too early", i)
		}
	}
	resp, _ := doReqJSON(t, ts, "POST", "/api/v1/pair/request", map[string]any{
		"pairId": "nope", "token": "x",
		"device": map[string]any{"deviceId": "x", "deviceName": "y", "platform": "android"},
	})
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Errorf("4th request not rate-limited: %d", resp.StatusCode)
	}
}

func TestChunkUploadFlow(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	// Manually create a session to authenticate.
	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	// Create a transfer via API.
	createBody := map[string]any{
		"offerId": "o1", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "hello.txt", "size": 11, "mimeType": "text/plain"},
		},
	}
	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, createBody)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct {
		TransferID string `json:"transferId"`
		Files      []struct {
			FileID      string `json:"fileId"`
			TotalChunks int    `json:"totalChunks"`
		} `json:"files"`
	}
	json.Unmarshal([]byte(body), &res)
	if len(res.Files) != 1 || res.Files[0].TotalChunks != 1 {
		t.Fatalf("unexpected response: %s", body)
	}
	transferID := res.TransferID
	fileID := res.Files[0].FileID

	// Upload chunk 0.
	chunkURL := "/api/v1/transfers/" + transferID + "/files/" + fileID + "/chunks/0"
	resp, body = doReqAuth(t, ts, "PUT", chunkURL, sess.ID, sess.Token, []byte("hello world"))
	if resp.StatusCode != 200 {
		t.Fatalf("chunk upload: %d %s", resp.StatusCode, body)
	}

	// Complete the file.
	completeURL := "/api/v1/transfers/" + transferID + "/files/" + fileID + "/complete"
	// sha256("hello world")
	sha := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
	resp, body = doReqAuthJSON(t, ts, "POST", completeURL, sess.ID, sess.Token, map[string]any{"size": 11, "sha256": sha})
	if resp.StatusCode != 200 {
		t.Fatalf("complete: %d %s", resp.StatusCode, body)
	}

	// File should be in the downloads dir.
	entries, _ := listDir(srv.Storage.DownloadDir())
	found := false
	for _, e := range entries {
		if e == "hello.txt" {
			found = true
		}
	}
	if !found {
		t.Errorf("hello.txt not in %v", entries)
	}
}

func TestPathTraversalRejected(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	createBody := map[string]any{
		"offerId": "o2", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "../../etc/passwd", "size": 5},
		},
	}
	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, createBody)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct {
		TransferID string `json:"transferId"`
		Files      []struct{ FileID string `json:"fileId"` } `json:"files"`
	}
	json.Unmarshal([]byte(body), &res)

	// Upload + complete.
	transferID := res.TransferID
	fileID := res.Files[0].FileID
	doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+transferID+"/files/"+fileID+"/chunks/0", sess.ID, sess.Token, []byte("evil"))
	resp, body = doReqAuthJSON(t, ts, "POST", "/api/v1/transfers/"+transferID+"/files/"+fileID+"/complete", sess.ID, sess.Token, map[string]any{"size": 5, "sha256": ""})
	if resp.StatusCode != 200 {
		t.Fatalf("complete: %d %s", resp.StatusCode, body)
	}
	// The file must land in the downloads dir, NOT outside it.
	entries, _ := listDir(srv.Storage.DownloadDir())
	found := false
	for _, e := range entries {
		if e == "passwd" {
			found = true
		}
	}
	if !found {
		t.Errorf("sanitized file 'passwd' not in download dir: %v", entries)
	}
	// And nothing should appear at "etc/" inside the download dir.
	for _, e := range entries {
		if strings.Contains(e, "etc") || strings.Contains(e, "..") {
			t.Errorf("escape attempt partially succeeded: %s", e)
		}
	}
}

// --- helpers ---

func doReq(t *testing.T, ts *httptest.Server, method, path string, body io.Reader, contentType string) (*http.Response, string) {
	t.Helper()
	req, _ := http.NewRequest(method, ts.URL+path, body)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, string(b)
}

func doReqJSON(t *testing.T, ts *httptest.Server, method, path string, body any) (*http.Response, string) {
	t.Helper()
	data, _ := json.Marshal(body)
	return doReq(t, ts, method, path, bytes.NewReader(data), "application/json")
}

func doReqAuth(t *testing.T, ts *httptest.Server, method, path, sessID, token string, body []byte) (*http.Response, string) {
	t.Helper()
	req, _ := http.NewRequest(method, ts.URL+path, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Session-Id", sessID)
	if len(body) > 0 {
		req.Header.Set("Content-Type", "application/octet-stream")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, string(b)
}

func doReqAuthJSON(t *testing.T, ts *httptest.Server, method, path, sessID, token string, body any) (*http.Response, string) {
	t.Helper()
	data, _ := json.Marshal(body)
	return doReqAuth(t, ts, method, path, sessID, token, data)
}

func listDir(dir string) ([]string, error) {
	entries, err := filepath.Glob(filepath.Join(dir, "*"))
	if err != nil {
		return nil, err
	}
	out := make([]string, len(entries))
	for i, e := range entries {
		out[i] = filepath.Base(e)
	}
	return out, nil
}

func fileExists(path string) bool {
	_, err := filepath.Glob(path)
	return err == nil
}
