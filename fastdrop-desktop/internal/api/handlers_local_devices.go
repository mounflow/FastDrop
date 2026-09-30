package api

import (
	"context"
	"net/http"
	"time"
)

// 本机专用（withLocalDesktop）的设备管理接口，供内嵌的 Vue UI 使用。
//
// 背景：会话是"每服务器单向"的——手机配对进 PC 只让手机获得 PC 的会话，
// PC 要能向该手机发送，必须自己持有对方的会话。为此 PC 侧需要：
//   1) 知道"有哪台设备连过本机、它的地址是什么"（GET /local/devices）；
//   2) 用户删除设备时真正断开（DELETE /local/devices/{id}）。
//
// GET /api/v1/local/devices 返回 devices 表投影 + 是否仍持有有效会话 +
// 最后已知 IP（用于反向回连 http://<lastIp>:9527）。仅本机可访问。

type localDeviceView struct {
	DeviceID         string `json:"deviceId"`
	DeviceName       string `json:"deviceName"`
	Platform         string `json:"platform"`
	AppVersion       string `json:"appVersion,omitempty"`
	LastIP           string `json:"lastIp,omitempty"`
	LastSeenAt       int64  `json:"lastSeenAt"`
	Ignored          bool   `json:"ignored"`
	HasActiveSession bool   `json:"hasActiveSession"`
}

// isDeviceIgnored 报告该设备是否被用户明确删除过（ignored_at 非零）。
//
// 用于配对流程：被删除的设备即使全局"免确认"开启也不静默接受，必须由
// 用户在本机 UI 上显式确认。
//
// 同时按设备名匹配：用户删除的是"这台设备"，若对端重装后 deviceId 变了
// 但名称未变，仍应需要显式确认（否则换个 id 就能绕过删除）。
func (s *Server) isDeviceIgnored(ctx context.Context, deviceID, deviceName string) bool {
	if deviceID == "" && deviceName == "" {
		return false
	}
	if deviceID != "" {
		if dev, err := s.DB.GetDevice(ctx, deviceID); err == nil && dev != nil && dev.IgnoredAt > 0 {
			return true
		}
	}
	if deviceName == "" {
		return false
	}
	devices, err := s.DB.ListDevices(ctx)
	if err != nil {
		return false
	}
	for _, dev := range devices {
		if dev.Name == deviceName && dev.IgnoredAt > 0 {
			return true
		}
	}
	return false
}

// handleListLocalDevices lists known devices for the embedded UI, including
// the last observed IP so the UI can establish the reverse (sender) direction.
func (s *Server) handleListLocalDevices(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	devices, err := s.DB.ListDevices(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}

	out := make([]localDeviceView, 0, len(devices))
	for _, dev := range devices {
		sessions, err := s.DB.ListActiveSessionsForDevice(ctx, dev.ID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
			return
		}
		out = append(out, localDeviceView{
			DeviceID:         dev.ID,
			DeviceName:       dev.Name,
			Platform:         dev.Platform,
			AppVersion:       dev.AppVersion,
			LastIP:           dev.LastIP,
			LastSeenAt:       dev.LastSeenAt,
			Ignored:          dev.IgnoredAt > 0,
			HasActiveSession: len(sessions) > 0,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// handleDeleteLocalDevice implements "删除设备 = 双向真正断开 + 清除配对
// 记录 + 不自动恢复" on the PC side:
//
//  1. 吊销该设备在本机的全部会话 —— 对方立即失去访问权（其 HTTP 请求会
//     拿到 SESSION_REVOKED，而不只是本地删记录）；
//  2. 断开它在本机的 WebSocket 连接并推送 session.revoked（若在连）；
//  3. 把设备行标记为 ignored_at（tombstone：会话凭证已全部吊销，行内不再
//     持有任何可用凭证）——自动回连跳过它、它再连时需用户显式确认；
//  4. **不触碰任何传输记录表**（transfers / transfer_files /
//     file_chunk_states），历史页照常可查。
func (s *Server) handleDeleteLocalDevice(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	deviceID := r.PathValue("deviceId")
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "deviceId is required", requestID(r))
		return
	}

	revoked, err := s.DB.RevokeSessionsForDevice(ctx, deviceID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	if s.WSHub != nil {
		s.WSHub.DisconnectDevice(deviceID, "session revoked by host")
	}
	if err := s.DB.SetDeviceIgnored(ctx, deviceID, true); err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"deviceId":       deviceID,
		"revokedSessions": revoked,
		"ignored":        true,
		"deletedAt":      time.Now().Unix(),
		"autoReconnect":  false,
	})
}

// handleRestoreLocalDevice 清除忽略标记（用户主动重新配对时调用）。
func (s *Server) handleRestoreLocalDevice(w http.ResponseWriter, r *http.Request) {
	deviceID := r.PathValue("deviceId")
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "deviceId is required", requestID(r))
		return
	}
	if err := s.DB.SetDeviceIgnored(r.Context(), deviceID, false); err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", err.Error(), requestID(r))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deviceId": deviceID, "ignored": false})
}

// clearIgnoreOnManualAccept 在用户**显式确认**某设备的配对时清除忽略标记
// ——"用户主动重新配对即恢复"，删除不是永久黑名单。
func (s *Server) clearIgnoreOnManualAccept(ctx context.Context, deviceID, deviceName string) {
	if deviceID == "" && deviceName == "" {
		return
	}
	if !s.isDeviceIgnored(ctx, deviceID, deviceName) {
		return
	}
	if deviceID != "" {
		_ = s.DB.SetDeviceIgnored(ctx, deviceID, false)
	}
	if deviceName == "" {
		return
	}
	// 名称匹配命中的同名行也一并清除（对端 id 变更的场景）。
	if devices, err := s.DB.ListDevices(ctx); err == nil {
		for _, dev := range devices {
			if dev.Name == deviceName && dev.IgnoredAt > 0 {
				_ = s.DB.SetDeviceIgnored(ctx, dev.ID, false)
			}
		}
	}
}
