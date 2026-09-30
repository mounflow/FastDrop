package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"fastdrop-desktop/internal/database"
)

// 覆盖"一次连接=双向通道"与"删除设备=双向真正断开且不自动恢复"的 PC 侧契约：
//  1. /local/devices 暴露 lastIp（供 UI 反向回连）与 ignored / hasActiveSession
//  2. DELETE /local/devices/{id} 吊销该设备在本机的全部会话并打忽略标记
//  3. 被删除的设备再次配对时不静默接受（即使全局免确认），改由用户确认
//  4. 用户显式确认后清除忽略标记（删除不是永久黑名单）
//  5. 删除设备完全不触碰传输记录（回归守卫）

func seedDevice(t *testing.T, srv *Server, deviceID, name, ip string) {
	t.Helper()
	if err := srv.DB.UpsertDevice(database.Device{
		ID: deviceID, Name: name, Platform: "android", LastIP: ip,
		FirstSeenAt: 1, LastSeenAt: 2,
	}); err != nil {
		t.Fatal(err)
	}
}

func TestLocalDevicesExposesLastIPAndSessionState(t *testing.T) {
	srv, _ := newTestServer(t)
	seedDevice(t, srv, "phone-1", "Phone One", "192.168.1.50")
	if _, err := srv.Session.Create(context.Background(), "phone-1", "192.168.1.50"); err != nil {
		t.Fatal(err)
	}

	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	_, body := doReq(t, ts, "GET", "/api/v1/local/devices", nil, "")
	var payload struct {
		Devices []localDeviceView `json:"devices"`
	}
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		t.Fatalf("decode: %v (%s)", err, body)
	}

	var found *localDeviceView
	for i := range payload.Devices {
		if payload.Devices[i].DeviceID == "phone-1" {
			found = &payload.Devices[i]
		}
	}
	if found == nil {
		t.Fatalf("device not listed: %s", body)
	}
	// lastIp 是 PC 反向回连（建立发送方向）所需的地址来源。
	if found.LastIP != "192.168.1.50" {
		t.Fatalf("lastIp = %q, want 192.168.1.50", found.LastIP)
	}
	if !found.HasActiveSession {
		t.Fatalf("hasActiveSession = false, want true")
	}
	if found.Ignored {
		t.Fatalf("ignored = true, want false")
	}
}

func TestDeleteLocalDeviceRevokesAndIgnores(t *testing.T) {
	srv, cfg := newTestServer(t)
	// 关闭全局确认，以验证"忽略名单"能单独阻止静默接受。
	cfg.Security.RequirePairConfirmation = false
	seedDevice(t, srv, "phone-2", "Phone Two", "192.168.1.51")
	if _, err := srv.Session.Create(context.Background(), "phone-2", "192.168.1.51"); err != nil {
		t.Fatal(err)
	}

	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	sessions, err := srv.DB.ListActiveSessionsForDevice(context.Background(), "phone-2")
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 1 {
		t.Fatalf("precondition: %d active sessions, want 1", len(sessions))
	}

	resp, body := doReq(t, ts, "DELETE", "/api/v1/local/devices/phone-2", nil, "")
	if resp.StatusCode != 200 {
		t.Fatalf("delete status %d: %s", resp.StatusCode, body)
	}
	var del struct {
		RevokedSessions int64 `json:"revokedSessions"`
		Ignored         bool  `json:"ignored"`
	}
	if err := json.Unmarshal([]byte(body), &del); err != nil {
		t.Fatalf("decode: %v (%s)", err, body)
	}
	if del.RevokedSessions != 1 {
		t.Fatalf("revokedSessions = %d, want 1", del.RevokedSessions)
	}
	if !del.Ignored {
		t.Fatalf("ignored = false, want true")
	}

	after, err := srv.DB.ListActiveSessionsForDevice(context.Background(), "phone-2")
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 0 {
		t.Fatalf("still %d active sessions after delete, want 0", len(after))
	}

	pairBody, _ := json.Marshal(map[string]any{
		"device": map[string]any{
			"deviceId": "phone-2", "deviceName": "Phone Two", "platform": "android",
		},
	})
	resp2, body2 := doReq(t, ts, "POST", "/api/v1/pair/discover", bytes.NewReader(pairBody), "application/json")
	if resp2.StatusCode != 200 {
		t.Fatalf("discover status %d: %s", resp2.StatusCode, body2)
	}
	var pr struct {
		RequestID string `json:"requestId"`
		Status    string `json:"status"`
	}
	if err := json.Unmarshal([]byte(body2), &pr); err != nil {
		t.Fatalf("decode: %v (%s)", err, body2)
	}
	if pr.Status != "waiting_confirmation" {
		t.Fatalf("status = %q, want waiting_confirmation", pr.Status)
	}

	resp3, body3 := doReq(t, ts, "POST", "/api/v1/pair/requests/"+pr.RequestID+"/accept", nil, "")
	if resp3.StatusCode != 200 {
		t.Fatalf("accept status %d: %s", resp3.StatusCode, body3)
	}
	dev, err := srv.DB.GetDevice(context.Background(), "phone-2")
	if err != nil {
		t.Fatal(err)
	}
	if dev.IgnoredAt != 0 {
		t.Fatalf("ignoredAt = %d after manual accept, want 0", dev.IgnoredAt)
	}
}

// 忽略判定按名称匹配：对端换了 deviceId 也不能绕过删除。
func TestDeleteLocalDeviceIgnoreMatchesByName(t *testing.T) {
	srv, cfg := newTestServer(t)
	cfg.Security.RequirePairConfirmation = false
	seedDevice(t, srv, "phone-3", "Phone Three", "192.168.1.52")

	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	if resp, body := doReq(t, ts, "DELETE", "/api/v1/local/devices/phone-3", nil, ""); resp.StatusCode != 200 {
		t.Fatalf("delete status %d: %s", resp.StatusCode, body)
	}

	pairBody, _ := json.Marshal(map[string]any{
		"device": map[string]any{
			"deviceId": "phone-3-reinstalled", "deviceName": "Phone Three", "platform": "android",
		},
	})
	resp, body := doReq(t, ts, "POST", "/api/v1/pair/discover", bytes.NewReader(pairBody), "application/json")
	if resp.StatusCode != 200 {
		t.Fatalf("discover status %d: %s", resp.StatusCode, body)
	}
	var pr struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal([]byte(body), &pr); err != nil {
		t.Fatalf("decode: %v (%s)", err, body)
	}
	if pr.Status != "waiting_confirmation" {
		t.Fatalf("status = %q, want waiting_confirmation", pr.Status)
	}
}

// 回归守卫：删除设备不得触碰传输记录。
func TestDeleteLocalDeviceKeepsTransferHistory(t *testing.T) {
	srv, _ := newTestServer(t)
	ctx := context.Background()
	seedDevice(t, srv, "phone-4", "Phone Four", "192.168.1.53")

	if _, err := srv.DB.ExecContext(ctx, `
INSERT INTO transfers (id, session_id, peer_device_id, direction, status,
    total_files, total_bytes, transferred_bytes, created_at, completed_at)
VALUES ('t-history-1', 'sess-1', 'phone-4', 'client_to_server', 'completed',
    3, 1234, 1234, 10, 20)`); err != nil {
		t.Fatal(err)
	}

	h := New(srv)
	ts := httptest.NewServer(h)
	defer ts.Close()

	if resp, body := doReq(t, ts, "DELETE", "/api/v1/local/devices/phone-4", nil, ""); resp.StatusCode != 200 {
		t.Fatalf("delete status %d: %s", resp.StatusCode, body)
	}

	_, body := doReq(t, ts, "GET", "/api/v1/local/transfers", nil, "")
	var hist struct {
		Transfers []database.TransferHistoryRow `json:"transfers"`
	}
	if err := json.Unmarshal([]byte(body), &hist); err != nil {
		t.Fatalf("decode: %v (%s)", err, body)
	}
	if len(hist.Transfers) != 1 || hist.Transfers[0].ID != "t-history-1" {
		t.Fatalf("transfer history affected by device delete: %s", body)
	}
}
