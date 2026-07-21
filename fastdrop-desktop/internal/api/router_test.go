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

// ---------------------------------------------------------------------------
// parseRange unit tests
// ---------------------------------------------------------------------------

func TestParseRange(t *testing.T) {
	const size = 1000
	cases := []struct {
		header         string
		wantS, wantE   int64
		wantOK         bool
	}{
		{"bytes=0-499", 0, 499, true},
		{"bytes=500-999", 500, 999, true},
		{"bytes=0-", 0, 999, true},
		{"bytes=999-", 999, 999, true},
		{"bytes=-100", 900, 999, true},
		{"bytes=-1000", 0, 999, true},
		// Invalid ranges.
		{"bytes=1000-", 0, 0, false},   // start >= size
		{"bytes=1000-1001", 0, 0, false},
		{"bytes=500-499", 0, 0, false}, // end < start
		{"bytes=0-1000", 0, 0, false},  // end >= size
		{"bytes=-0", 0, 0, false},      // suffix of 0
		{"bytes=-1001", 0, 0, false},   // suffix > size
		{"chars=0-100", 0, 0, false},   // wrong unit
		{"", 0, 0, false},
		{"bytes=abc", 0, 0, false},
		{"bytes=abc-def", 0, 0, false},
		// Multi-range: only first is used.
		{"bytes=0-99,200-299", 0, 99, true},
	}
	for _, c := range cases {
		s, e, ok := parseRange(c.header, size)
		if ok != c.wantOK || s != c.wantS || e != c.wantE {
			t.Errorf("parseRange(%q, %d) = (%d, %d, %v), want (%d, %d, %v)",
				c.header, size, s, e, ok, c.wantS, c.wantE, c.wantOK)
		}
	}
}

func TestParseRangeSmallFile(t *testing.T) {
	// 1-byte file.
	s, e, ok := parseRange("bytes=0-0", 1)
	if !ok || s != 0 || e != 0 {
		t.Errorf("1-byte file: got (%d,%d,%v)", s, e, ok)
	}
	// Suffix on 1-byte file.
	s, e, ok = parseRange("bytes=-1", 1)
	if !ok || s != 0 || e != 0 {
		t.Errorf("suffix 1-byte: got (%d,%d,%v)", s, e, ok)
	}
}

// ---------------------------------------------------------------------------
// withAuth middleware edge cases
// ---------------------------------------------------------------------------

func TestWithAuthMissingBearer(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	// No Authorization header at all.
	req, _ := http.NewRequest("GET", ts.URL+"/api/v1/transfers", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("no auth header: status %d, want 401", resp.StatusCode)
	}
}

func TestWithAuthMissingSessionID(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	req, _ := http.NewRequest("GET", ts.URL+"/api/v1/transfers", nil)
	req.Header.Set("Authorization", "Bearer sometoken")
	// No X-Session-Id.
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("no session id: status %d, want 401", resp.StatusCode)
	}
}

func TestWithAuthBadToken(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	// Valid session ID, wrong token.
	req, _ := http.NewRequest("GET", ts.URL+"/api/v1/transfers", nil)
	req.Header.Set("Authorization", "Bearer WRONGTOKEN")
	req.Header.Set("X-Session-Id", sess.ID)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("bad token: status %d, want 401", resp.StatusCode)
	}
}

// ---------------------------------------------------------------------------
// Cross-session security: transferOwned / fileOwned denial
// ---------------------------------------------------------------------------

func TestCrossSessionTransferDenial(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone1", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	srv.DB.UpsertDevice(database.Device{ID: "d2", Name: "phone2", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess1, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")
	sess2, _ := srv.Session.Create(ctx, "d2", "127.0.0.1")

	// Create a transfer under session 1.
	createBody := map[string]any{
		"offerId": "o1", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "secret.txt", "size": 5},
		},
	}
	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess1.ID, sess1.Token, createBody)
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct {
		TransferID string `json:"transferId"`
		Files      []struct{ FileID string `json:"fileId"` } `json:"files"`
	}
	json.Unmarshal([]byte(body), &res)

	// Session 2 tries to GET session 1's transfer → 403.
	resp, body = doReqAuth(t, ts, "GET", "/api/v1/transfers/"+res.TransferID, sess2.ID, sess2.Token, nil)
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("cross-session GET transfer: %d, want 403. body: %s", resp.StatusCode, body)
	}

	// Session 2 tries to cancel session 1's transfer → 403.
	resp, body = doReqAuth(t, ts, "POST", "/api/v1/transfers/"+res.TransferID+"/cancel", sess2.ID, sess2.Token, nil)
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("cross-session cancel: %d, want 403. body: %s", resp.StatusCode, body)
	}

	// Session 2 tries to upload a chunk to session 1's file → 403.
	fileID := res.Files[0].FileID
	chunkURL := "/api/v1/transfers/" + res.TransferID + "/files/" + fileID + "/chunks/0"
	resp, body = doReqAuth(t, ts, "PUT", chunkURL, sess2.ID, sess2.Token, []byte("evil"))
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("cross-session chunk PUT: %d, want 403. body: %s", resp.StatusCode, body)
	}

	// Session 2 tries to GET session 1's file → 403.
	fileURL := "/api/v1/transfers/" + res.TransferID + "/files/" + fileID
	resp, body = doReqAuth(t, ts, "GET", fileURL, sess2.ID, sess2.Token, nil)
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("cross-session GET file: %d, want 403. body: %s", resp.StatusCode, body)
	}

	// Session 2 tries to list chunks → 403.
	chunksURL := "/api/v1/transfers/" + res.TransferID + "/files/" + fileID + "/chunks"
	resp, body = doReqAuth(t, ts, "GET", chunksURL, sess2.ID, sess2.Token, nil)
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("cross-session list chunks: %d, want 403. body: %s", resp.StatusCode, body)
	}
}

// fileOwned: mismatched transferId + fileId → 404.
func TestFileOwnedMismatchedTransfer(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	// Create two transfers.
	mk := func(offer string) (string, string) {
		resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
			"offerId": offer, "direction": "client_to_server",
			"files": []map[string]any{{"clientFileId": "c1", "name": "f.txt", "size": 5}},
		})
		if resp.StatusCode != 201 {
			t.Fatalf("create %s: %d %s", offer, resp.StatusCode, body)
		}
		var r struct {
			TransferID string `json:"transferId"`
			Files      []struct{ FileID string `json:"fileId"` } `json:"files"`
		}
		json.Unmarshal([]byte(body), &r)
		return r.TransferID, r.Files[0].FileID
	}
	t1, _ := mk("o1")
	_, f2 := mk("o2")

	// Use transfer1's ID with transfer2's fileId → 404.
	url := "/api/v1/transfers/" + t1 + "/files/" + f2
	resp, body := doReqAuth(t, ts, "GET", url, sess.ID, sess.Token, nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("mismatched transfer+file: %d, want 404. body: %s", resp.StatusCode, body)
	}
}

// ---------------------------------------------------------------------------
// Download with Range header
// ---------------------------------------------------------------------------

func TestDownloadFileWithRange(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	// Upload "hello world" (11 bytes).
	content := []byte("hello world")
	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
		"offerId": "dl1", "direction": "client_to_server",
		"files": []map[string]any{{"clientFileId": "c1", "name": "dl.txt", "size": len(content)}},
	})
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct {
		TransferID string `json:"transferId"`
		Files      []struct{ FileID string `json:"fileId"` } `json:"files"`
	}
	json.Unmarshal([]byte(body), &res)
	tid, fid := res.TransferID, res.Files[0].FileID

	doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+fid+"/chunks/0", sess.ID, sess.Token, content)
	sha := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
	doReqAuthJSON(t, ts, "POST", "/api/v1/transfers/"+tid+"/files/"+fid+"/complete", sess.ID, sess.Token,
		map[string]any{"size": len(content), "sha256": sha})

	dlURL := "/api/v1/transfers/" + tid + "/files/" + fid + "/content"

	// Full download (no Range).
	resp, body = doReqAuth(t, ts, "GET", dlURL, sess.ID, sess.Token, nil)
	if resp.StatusCode != 200 {
		t.Fatalf("full download: %d", resp.StatusCode)
	}
	if body != "hello world" {
		t.Errorf("full body = %q", body)
	}
	if resp.Header.Get("Accept-Ranges") != "bytes" {
		t.Error("missing Accept-Ranges header")
	}

	// Partial download: bytes=0-4 → "hello".
	req, _ := http.NewRequest("GET", ts.URL+dlURL, nil)
	req.Header.Set("Authorization", "Bearer "+sess.Token)
	req.Header.Set("X-Session-Id", sess.ID)
	req.Header.Set("Range", "bytes=0-4")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	b2, _ := io.ReadAll(resp2.Body)
	if resp2.StatusCode != http.StatusPartialContent {
		t.Fatalf("range download: %d, want 206", resp2.StatusCode)
	}
	if string(b2) != "hello" {
		t.Errorf("range body = %q, want %q", string(b2), "hello")
	}
	cr := resp2.Header.Get("Content-Range")
	if cr != "bytes 0-4/11" {
		t.Errorf("Content-Range = %q, want 'bytes 0-4/11'", cr)
	}

	// Suffix range: bytes=-5 → "world".
	req3, _ := http.NewRequest("GET", ts.URL+dlURL, nil)
	req3.Header.Set("Authorization", "Bearer "+sess.Token)
	req3.Header.Set("X-Session-Id", sess.ID)
	req3.Header.Set("Range", "bytes=-5")
	resp3, err := http.DefaultClient.Do(req3)
	if err != nil {
		t.Fatal(err)
	}
	defer resp3.Body.Close()
	b3, _ := io.ReadAll(resp3.Body)
	if resp3.StatusCode != http.StatusPartialContent {
		t.Fatalf("suffix range: %d, want 206", resp3.StatusCode)
	}
	if string(b3) != "world" {
		t.Errorf("suffix body = %q, want %q", string(b3), "world")
	}

	// Invalid range → 416.
	req4, _ := http.NewRequest("GET", ts.URL+dlURL, nil)
	req4.Header.Set("Authorization", "Bearer "+sess.Token)
	req4.Header.Set("X-Session-Id", sess.ID)
	req4.Header.Set("Range", "bytes=100-200")
	resp4, err := http.DefaultClient.Do(req4)
	if err != nil {
		t.Fatal(err)
	}
	defer resp4.Body.Close()
	if resp4.StatusCode != http.StatusRequestedRangeNotSatisfiable {
		t.Errorf("bad range: %d, want 416", resp4.StatusCode)
	}

	// HEAD request.
	req5, _ := http.NewRequest("HEAD", ts.URL+dlURL, nil)
	req5.Header.Set("Authorization", "Bearer "+sess.Token)
	req5.Header.Set("X-Session-Id", sess.ID)
	resp5, err := http.DefaultClient.Do(req5)
	if err != nil {
		t.Fatal(err)
	}
	defer resp5.Body.Close()
	if resp5.StatusCode != 200 {
		t.Errorf("HEAD: %d, want 200", resp5.StatusCode)
	}
	if resp5.Header.Get("Content-Length") != "11" {
		t.Errorf("HEAD Content-Length = %q, want 11", resp5.Header.Get("Content-Length"))
	}
}

// ---------------------------------------------------------------------------
// Multi-file transfer E2E
// ---------------------------------------------------------------------------

func TestMultiFileTransfer(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	// Create a transfer with 2 files.
	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
		"offerId": "mf1", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "file1.txt", "size": 5},
			{"clientFileId": "c2", "name": "file2.txt", "size": 6},
		},
	})
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct {
		TransferID string `json:"transferId"`
		Files      []struct {
			FileID       string `json:"fileId"`
			ClientFileID string `json:"clientFileId"`
		} `json:"files"`
	}
	json.Unmarshal([]byte(body), &res)
	if len(res.Files) != 2 {
		t.Fatalf("expected 2 files, got %d", len(res.Files))
	}
	tid := res.TransferID

	// Upload both files.
	doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+res.Files[0].FileID+"/chunks/0", sess.ID, sess.Token, []byte("aaaaa"))
	doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+res.Files[1].FileID+"/chunks/0", sess.ID, sess.Token, []byte("bbbbbb"))

	// Complete file 1.
	sha1 := "ed968e840d10d2d313a870bc131a4e2c311d7ad09bdf32b3418147221f51a6e2" // sha256("aaaaa")
	resp, body = doReqAuthJSON(t, ts, "POST", "/api/v1/transfers/"+tid+"/files/"+res.Files[0].FileID+"/complete",
		sess.ID, sess.Token, map[string]any{"size": 5, "sha256": sha1})
	if resp.StatusCode != 200 {
		t.Fatalf("complete file1: %d %s", resp.StatusCode, body)
	}

	// Transfer should NOT be completed yet (file2 still pending).
	resp, body = doReqAuth(t, ts, "GET", "/api/v1/transfers/"+tid, sess.ID, sess.Token, nil)
	var tr map[string]any
	json.Unmarshal([]byte(body), &tr)
	if tr["status"] == "completed" {
		t.Error("transfer completed after only 1 of 2 files")
	}

	// Complete file 2.
	sha2 := "4625fd63b0e96fc0d656ae7381605e48d4a0f63a319fc743adf22688613883c7" // sha256("bbbbbb")
	resp, body = doReqAuthJSON(t, ts, "POST", "/api/v1/transfers/"+tid+"/files/"+res.Files[1].FileID+"/complete",
		sess.ID, sess.Token, map[string]any{"size": 6, "sha256": sha2})
	if resp.StatusCode != 200 {
		t.Fatalf("complete file2: %d %s", resp.StatusCode, body)
	}

	// Now transfer should be completed.
	resp, body = doReqAuth(t, ts, "GET", "/api/v1/transfers/"+tid, sess.ID, sess.Token, nil)
	json.Unmarshal([]byte(body), &tr)
	if tr["status"] != "completed" {
		t.Errorf("transfer status = %v, want completed", tr["status"])
	}

	// Both files should exist in downloads.
	entries, _ := listDir(srv.Storage.DownloadDir())
	found1, found2 := false, false
	for _, e := range entries {
		if e == "file1.txt" {
			found1 = true
		}
		if e == "file2.txt" {
			found2 = true
		}
	}
	if !found1 || !found2 {
		t.Errorf("missing files in downloads: %v (file1=%v, file2=%v)", entries, found1, found2)
	}
}

// ---------------------------------------------------------------------------
// Breakpoint resume: partial upload → query missing → upload rest → complete
// ---------------------------------------------------------------------------

func TestBreakpointResume(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	// Create a file that spans 3 chunks (chunk size = 4MB, so use a small
	// test chunk size by creating a transfer with size > 2*chunkSize).
	// Instead, we use a 1-chunk file but upload chunk 0, then verify
	// the bitmap shows it complete. For a true multi-chunk test we'd need
	// >4MB data. Let's test the bitmap query flow with a 1-chunk file:
	// upload chunk 0, query chunks (should show 0 missing), complete.
	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
		"offerId": "bp1", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "resume.bin", "size": 11},
		},
	})
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct {
		TransferID string `json:"transferId"`
		Files      []struct{ FileID string `json:"fileId"` } `json:"files"`
	}
	json.Unmarshal([]byte(body), &res)
	tid, fid := res.TransferID, res.Files[0].FileID

	// Before uploading: query chunks → all missing.
	chunksURL := "/api/v1/transfers/" + tid + "/files/" + fid + "/chunks"
	resp, body = doReqAuth(t, ts, "GET", chunksURL, sess.ID, sess.Token, nil)
	if resp.StatusCode != 200 {
		t.Fatalf("list chunks: %d %s", resp.StatusCode, body)
	}
	var chunkRes struct {
		CompletedChunks []int `json:"completedChunks"`
		MissingChunks   []int `json:"missingChunks"`
	}
	json.Unmarshal([]byte(body), &chunkRes)
	if len(chunkRes.MissingChunks) != 1 || chunkRes.MissingChunks[0] != 0 {
		t.Errorf("before upload: missing=%v, want [0]", chunkRes.MissingChunks)
	}
	if len(chunkRes.CompletedChunks) != 0 {
		t.Errorf("before upload: completed=%v, want []", chunkRes.CompletedChunks)
	}

	// Upload chunk 0.
	doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+fid+"/chunks/0", sess.ID, sess.Token, []byte("hello world"))

	// After uploading: query chunks → 0 missing, 1 completed.
	resp, body = doReqAuth(t, ts, "GET", chunksURL, sess.ID, sess.Token, nil)
	json.Unmarshal([]byte(body), &chunkRes)
	if len(chunkRes.CompletedChunks) != 1 || chunkRes.CompletedChunks[0] != 0 {
		t.Errorf("after upload: completed=%v, want [0]", chunkRes.CompletedChunks)
	}
	if len(chunkRes.MissingChunks) != 0 {
		t.Errorf("after upload: missing=%v, want []", chunkRes.MissingChunks)
	}

	// Complete the file.
	sha := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
	resp, body = doReqAuthJSON(t, ts, "POST", "/api/v1/transfers/"+tid+"/files/"+fid+"/complete",
		sess.ID, sess.Token, map[string]any{"size": 11, "sha256": sha})
	if resp.StatusCode != 200 {
		t.Fatalf("complete: %d %s", resp.StatusCode, body)
	}
}

// ---------------------------------------------------------------------------
// Retry flow: create → upload → mark retrying → upload again → complete
// ---------------------------------------------------------------------------

func TestRetryTransferFlow(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
		"offerId": "rt1", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "retry.txt", "size": 4},
		},
	})
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct {
		TransferID string `json:"transferId"`
		Files      []struct{ FileID string `json:"fileId"` } `json:"files"`
	}
	json.Unmarshal([]byte(body), &res)
	tid, fid := res.TransferID, res.Files[0].FileID

	// Upload chunk.
	doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+fid+"/chunks/0", sess.ID, sess.Token, []byte("data"))

	// Mark as retrying.
	resp, body = doReqAuth(t, ts, "POST", "/api/v1/transfers/"+tid+"/retry", sess.ID, sess.Token, nil)
	if resp.StatusCode != 200 {
		t.Fatalf("retry: %d %s", resp.StatusCode, body)
	}
	var retryRes map[string]any
	json.Unmarshal([]byte(body), &retryRes)
	if retryRes["status"] != "retrying" {
		t.Errorf("retry status = %v, want retrying", retryRes["status"])
	}

	// Re-upload the chunk (retrying → transferring auto-transition).
	resp, body = doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+fid+"/chunks/0", sess.ID, sess.Token, []byte("data"))
	if resp.StatusCode != 200 {
		t.Fatalf("re-upload: %d %s", resp.StatusCode, body)
	}

	// Transfer should be back to transferring.
	resp, body = doReqAuth(t, ts, "GET", "/api/v1/transfers/"+tid, sess.ID, sess.Token, nil)
	var tr map[string]any
	json.Unmarshal([]byte(body), &tr)
	if tr["status"] != "transferring" {
		t.Errorf("after re-upload: status = %v, want transferring", tr["status"])
	}
}

// ---------------------------------------------------------------------------
// Cancel and delete flows
// ---------------------------------------------------------------------------

func TestCancelAndDeleteTransfer(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
		"offerId": "cd1", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "cancel.txt", "size": 5},
		},
	})
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct{ TransferID string `json:"transferId"` }
	json.Unmarshal([]byte(body), &res)
	tid := res.TransferID

	// Cancel.
	resp, body = doReqAuth(t, ts, "POST", "/api/v1/transfers/"+tid+"/cancel", sess.ID, sess.Token, nil)
	if resp.StatusCode != 200 {
		t.Fatalf("cancel: %d %s", resp.StatusCode, body)
	}

	// Verify cancelled.
	resp, body = doReqAuth(t, ts, "GET", "/api/v1/transfers/"+tid, sess.ID, sess.Token, nil)
	var tr map[string]any
	json.Unmarshal([]byte(body), &tr)
	if tr["status"] != "cancelled" {
		t.Errorf("status = %v, want cancelled", tr["status"])
	}

	// Cancel again → should fail (already terminal).
	resp, _ = doReqAuth(t, ts, "POST", "/api/v1/transfers/"+tid+"/cancel", sess.ID, sess.Token, nil)
	if resp.StatusCode == 200 {
		t.Error("double cancel should fail")
	}

	// Delete.
	resp, body = doReqAuth(t, ts, "DELETE", "/api/v1/transfers/"+tid, sess.ID, sess.Token, nil)
	if resp.StatusCode != 200 {
		t.Fatalf("delete: %d %s", resp.StatusCode, body)
	}

	// GET after delete → 404.
	resp, _ = doReqAuth(t, ts, "GET", "/api/v1/transfers/"+tid, sess.ID, sess.Token, nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("GET after delete: %d, want 404", resp.StatusCode)
	}
}

// ---------------------------------------------------------------------------
// Chunk index validation
// ---------------------------------------------------------------------------

func TestChunkIndexValidation(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
		"offerId": "ci1", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "idx.txt", "size": 5},
		},
	})
	if resp.StatusCode != 201 {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	var res struct {
		TransferID string `json:"transferId"`
		Files      []struct{ FileID string `json:"fileId"` } `json:"files"`
	}
	json.Unmarshal([]byte(body), &res)
	tid, fid := res.TransferID, res.Files[0].FileID

	// Negative index.
	resp, _ = doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+fid+"/chunks/-1", sess.ID, sess.Token, []byte("x"))
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("negative index: %d, want 400", resp.StatusCode)
	}

	// Non-numeric index.
	resp, _ = doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+fid+"/chunks/abc", sess.ID, sess.Token, []byte("x"))
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("non-numeric index: %d, want 400", resp.StatusCode)
	}

	// Out of range (file is 5 bytes → 1 chunk, so index 1 is out of range).
	resp, _ = doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+fid+"/chunks/1", sess.ID, sess.Token, []byte("x"))
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("out-of-range index: %d, want 400", resp.StatusCode)
	}
}

// ---------------------------------------------------------------------------
// Active transfers listing
// ---------------------------------------------------------------------------

func TestListActiveTransfers(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	// Create two transfers.
	mk := func(offer string) string {
		resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
			"offerId": offer, "direction": "client_to_server",
			"files": []map[string]any{{"clientFileId": "c1", "name": "f.txt", "size": 5}},
		})
		if resp.StatusCode != 201 {
			t.Fatalf("create %s: %d", offer, resp.StatusCode)
		}
		var r struct{ TransferID string `json:"transferId"` }
		json.Unmarshal([]byte(body), &r)
		return r.TransferID
	}
	t1 := mk("a1")
	mk("a2")

	// Cancel the first one.
	doReqAuth(t, ts, "POST", "/api/v1/transfers/"+t1+"/cancel", sess.ID, sess.Token, nil)

	// Active list should only contain the second (non-cancelled) transfer.
	resp, body := doReqAuth(t, ts, "GET", "/api/v1/transfers/active", sess.ID, sess.Token, nil)
	if resp.StatusCode != 200 {
		t.Fatalf("active: %d %s", resp.StatusCode, body)
	}
	var activeRes struct {
		Transfers []map[string]any `json:"transfers"`
	}
	json.Unmarshal([]byte(body), &activeRes)
	if len(activeRes.Transfers) != 1 {
		t.Errorf("active count = %d, want 1", len(activeRes.Transfers))
	}
}

// ---------------------------------------------------------------------------
// Complete with incomplete bitmap → 400
// ---------------------------------------------------------------------------

func TestCompleteWithMissingChunks(t *testing.T) {
	srv, _ := newTestServer(t)
	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	ctx := context.Background()
	srv.DB.UpsertDevice(database.Device{ID: "d1", Name: "phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1})
	sess, _ := srv.Session.Create(ctx, "d1", "127.0.0.1")

	// Create a file that needs >1 chunk: size = 4MB + 1 → 2 chunks.
	bigSize := 4*1024*1024 + 1
	resp, body := doReqAuthJSON(t, ts, "POST", "/api/v1/transfers", sess.ID, sess.Token, map[string]any{
		"offerId": "inc1", "direction": "client_to_server",
		"files": []map[string]any{
			{"clientFileId": "c1", "name": "big.bin", "size": bigSize},
		},
	})
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
	tid, fid := res.TransferID, res.Files[0].FileID
	if res.Files[0].TotalChunks != 2 {
		t.Fatalf("totalChunks = %d, want 2", res.Files[0].TotalChunks)
	}

	// Upload only chunk 0 (skip chunk 1).
	chunk0 := make([]byte, 4*1024*1024)
	doReqAuth(t, ts, "PUT", "/api/v1/transfers/"+tid+"/files/"+fid+"/chunks/0", sess.ID, sess.Token, chunk0)

	// Try to complete → should fail because chunk 1 is missing.
	resp, body = doReqAuthJSON(t, ts, "POST", "/api/v1/transfers/"+tid+"/files/"+fid+"/complete",
		sess.ID, sess.Token, map[string]any{"size": bigSize, "sha256": ""})
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("complete with missing chunks: %d, want 400. body: %s", resp.StatusCode, body)
	}
}
