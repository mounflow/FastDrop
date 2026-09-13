# FastDrop 应用直达 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变 FastDrop 默认文件传输行为的前提下，实现 Android 手机将单张或多张图片投递到 Windows 微信当前会话或 Chrome/Edge 指定 Gemini 标签页的可选功能。

**Architecture:** 保留现有 HTTP 文件通道和 WebSocket 控制通道，在 Go 桌面服务中增加独立 `delivery` 领域、串行投递队列和 Windows 自动化边界。手机通过会话绑定的短期 `targetId` 选择目标；浏览器扩展只负责枚举/激活 Gemini 标签页，实际粘贴仍由 Windows 桌面端执行。

**Tech Stack:** Go 1.26, SQLite, Gorilla WebSocket, Wails v2, Vue 3 + TypeScript + Vite/Vitest, Flutter + Riverpod, Chrome/Edge Manifest V3, Windows User32/Clipboard API via `golang.org/x/sys/windows`.

**Design:** `docs/superpowers/specs/2026-08-15-application-delivery-design.md`

---

## 执行前约束

- 执行时先使用 `using-git-worktrees` 创建隔离工作区。当前主工作区存在大量未提交改动，不得在其上直接执行本计划。
- 严格按 TDD 顺序执行：先写失败测试，再写最小实现，然后回归并提交。
- 现有 4 MB chunk、3 chunks/file、2 files、6 global HTTP、传输状态机和会话认证常量不得改动。
- 不携带 `deliveryIntent` 的请求必须与当前版本完全兼容。
- 投递失败不得将已完成的文件传输改为失败。
- 本计划按四个可验收里程碑组织：协议与权限基础、Windows/微信投递、浏览器/Gemini 投递、手机交互与全链路验收。

## 文件边界总览

### 桌面核心

- Create `fastdrop-desktop/internal/delivery/model.go`: 目标、意图、状态、适配器接口。
- Create `fastdrop-desktop/internal/delivery/registry.go`: 支持列表、会话绑定目标快照。
- Create `fastdrop-desktop/internal/delivery/service.go`: 权限、意图接受、重投和传输完成入队。
- Create `fastdrop-desktop/internal/delivery/coordinator.go`: 单 FIFO 队列与投递状态机。
- Create `fastdrop-desktop/internal/delivery/automation.go`: 可测试的 Windows 自动化接口。
- Create `fastdrop-desktop/internal/delivery/automation_windows.go`: 窗口、前台、剪贴板和 `Ctrl+V` 实现。
- Create `fastdrop-desktop/internal/delivery/automation_other.go`: 非 Windows 编译保底。
- Create `fastdrop-desktop/internal/delivery/wechat.go`: 微信正式适配器。
- Create `fastdrop-desktop/internal/delivery/extension_pairing.go`: 本机浏览器扩展配对。
- Create `fastdrop-desktop/internal/delivery/extension_hub.go`: 回环 WebSocket 扩展通道。
- Create `fastdrop-desktop/internal/api/handlers_delivery.go`: 能力、目标、设备授权和重投 API。
- Modify `fastdrop-desktop/internal/api/handlers_transfer.go`: 可选 `deliveryIntent` 和完成回调。
- Modify `fastdrop-desktop/internal/websocket/protocol.go`: `delivery.status` 消息常量。
- Modify `fastdrop-desktop/internal/database/db.go` and add `fastdrop-desktop/migrations/0002_app_delivery.sql`: 设备授权与 `delivery_jobs`。

### Windows 桌面 UI

- Create `fastdrop-desktop/web/src/components/AppDeliverySettings.vue`: 开关、设备授权、适配器和扩展状态。
- Create `fastdrop-desktop/web/src/components/AppDeliverySettings.test.ts`: 组件行为测试。
- Create `fastdrop-desktop/web/src/components/DeliveryConfirmationDialog.vue`: 可选投递前确认。
- Modify `fastdrop-desktop/web/src/api.ts`, `types.ts`, `DesktopApp.vue`, `package.json`: API 类型、集成与 Vitest。

### 浏览器扩展

- Create `fastdrop-browser-extension/manifest.json`: Manifest V3 和 Gemini 最小站点权限。
- Create `fastdrop-browser-extension/src/background.ts`: 配对、本机 WS、Gemini 目标上报和标签页激活。
- Create `fastdrop-browser-extension/src/gemini_content.ts`: 聚焦 Gemini 输入区，不读取正文。
- Create `fastdrop-browser-extension/src/popup.ts` and `popup.html`: 输入一次性配对码。
- Create `fastdrop-browser-extension/src/protocol.ts`: 扩展消息类型。
- Create `fastdrop-browser-extension/tests/background.test.ts` and `gemini_content.test.ts`: Chrome API/DOM 测试。

### Android 手机

- Create `fastdrop-mobile/lib/features/app_delivery/models.dart`: 能力、目标、意图和状态模型。
- Create `fastdrop-mobile/lib/features/app_delivery/delivery_client.dart`: REST 协议封装。
- Create `fastdrop-mobile/lib/features/app_delivery/delivery_providers.dart`: Riverpod 设置和投递状态。
- Create `fastdrop-mobile/lib/features/app_delivery/delivery_target_sheet.dart`: 按电脑选择目标。
- Modify `fastdrop-mobile/lib/shared/models/transfer.dart`: `deliveryIntent` 与接受结果。
- Modify `fastdrop-mobile/lib/features/transfer/transfer_service.dart`: 发送可选意图。
- Modify `fastdrop-mobile/lib/features/devices/multi_device_connection.dart`: 每台电脑的目标、意图和 `delivery.status`。
- Modify `fastdrop-mobile/lib/features/file_picker/file_picker_screen.dart`, `transfer_screen.dart`, `settings_screen.dart`, `history_screen.dart`: 附加入口、状态和重投。

---

## 里程碑 A：协议、数据和权限基础

### Task 1: 定义 delivery 领域模型和适配器合同

**Files:**
- Create: `fastdrop-desktop/internal/delivery/model.go`
- Create: `fastdrop-desktop/internal/delivery/model_test.go`

- [ ] **Step 1: 先写状态和 JSON 合同的失败测试**

```go
package delivery

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestTargetJSONNeverExposesLocator(t *testing.T) {
	target := Target{
		TargetID: "target-1", Kind: TargetNativeApp,
		AdapterID: "wechat.windows", AppName: "微信",
		DisplayName: "微信当前会话",
	}
	raw, err := json.Marshal(target)
	if err != nil { t.Fatal(err) }
	for _, forbidden := range []string{"NativeWindow", "BrowserTabID", "BrowserWindowID"} {
		if bytes.Contains(raw, []byte(forbidden)) { t.Fatalf("leaked locator: %s", raw) }
	}
}

func TestDeliveryStatusTerminal(t *testing.T) {
	if StatusPasting.IsTerminal() { t.Fatal("pasting must not be terminal") }
	if !StatusDelivered.IsTerminal() { t.Fatal("delivered must be terminal") }
	if !StatusManualPasteRequired.IsTerminal() { t.Fatal("fallback must be terminal") }
}

func TestDeliveryErrorCodesAreStable(t *testing.T) {
	if ErrorCodeOf(ErrTargetUnavailable) != ErrorCodeTargetUnavailable {
		t.Fatalf("code=%s", ErrorCodeOf(ErrTargetUnavailable))
	}
	if ErrorCodeOf(ErrClipboard) != ErrorCodeClipboardFailed {
		t.Fatalf("code=%s", ErrorCodeOf(ErrClipboard))
	}
}
```

- [ ] **Step 2: 运行测试并确认因类型不存在而失败**

Run: `Set-Location fastdrop-desktop; go test ./internal/delivery -run "TestTargetJSON|TestDeliveryStatus" -v`

Expected: FAIL，包含 `undefined: Target` 或包不存在。

- [ ] **Step 3: 写入最小领域合同**

```go
package delivery

import (
	"context"
	"errors"
)

type TargetKind string
const (
	TargetNativeApp TargetKind = "native_app"
	TargetBrowserTab TargetKind = "browser_tab"
)

type Stability string
const (
	StabilityStable Stability = "stable"
	StabilityExperimental Stability = "experimental"
)

type Capabilities struct {
	Images bool `json:"images"`
	MultipleImages bool `json:"multipleImages"`
}

type Target struct {
	TargetID string `json:"targetId"`
	Kind TargetKind `json:"kind"`
	AdapterID string `json:"adapterId"`
	AppName string `json:"appName"`
	DisplayName string `json:"displayName"`
	Domain string `json:"domain,omitempty"`
	IconKey string `json:"iconKey"`
	Stability Stability `json:"stability"`
	Capabilities Capabilities `json:"capabilities"`
}

type Locator struct {
	NativeWindow uintptr
	BrowserTabID int64
	BrowserWindowID int64
}

type Candidate struct {
	Target Target
	Locator Locator
}

type AdapterMetadata struct {
	ID string
	Enabled bool
	Stability Stability
}

type Adapter interface {
	Metadata() AdapterMetadata
	Discover(context.Context) ([]Candidate, error)
	Deliver(context.Context, Candidate, []string) error
}

type Intent struct {
	Mode string `json:"mode"`
	TargetID string `json:"targetId"`
	TargetRevision string `json:"targetRevision"`
}

type ErrorCode string
const (
	ErrorCodeDisabled ErrorCode = "DELIVERY_DISABLED"
	ErrorCodeNotAuthorized ErrorCode = "DELIVERY_NOT_AUTHORIZED"
	ErrorCodeTargetUnavailable ErrorCode = "DELIVERY_TARGET_UNAVAILABLE"
	ErrorCodeTargetChanged ErrorCode = "DELIVERY_TARGET_CHANGED"
	ErrorCodeExtensionUnavailable ErrorCode = "DELIVERY_EXTENSION_UNAVAILABLE"
	ErrorCodeFocusDenied ErrorCode = "DELIVERY_FOCUS_DENIED"
	ErrorCodeClipboardFailed ErrorCode = "DELIVERY_CLIPBOARD_FAILED"
	ErrorCodeUnsupported ErrorCode = "DELIVERY_UNSUPPORTED"
)

var (
	ErrDeliveryDisabled = errors.New(string(ErrorCodeDisabled))
	ErrNotAuthorized = errors.New(string(ErrorCodeNotAuthorized))
	ErrTargetUnavailable = errors.New(string(ErrorCodeTargetUnavailable))
	ErrTargetChanged = errors.New(string(ErrorCodeTargetChanged))
	ErrExtensionUnavailable = errors.New(string(ErrorCodeExtensionUnavailable))
	ErrFocusDenied = errors.New(string(ErrorCodeFocusDenied))
	ErrClipboard = errors.New(string(ErrorCodeClipboardFailed))
	ErrUnsupported = errors.New(string(ErrorCodeUnsupported))
)

func ErrorCodeOf(err error) ErrorCode {
	for _, item := range []struct{ err error; code ErrorCode }{
		{ErrDeliveryDisabled, ErrorCodeDisabled}, {ErrNotAuthorized, ErrorCodeNotAuthorized},
		{ErrTargetUnavailable, ErrorCodeTargetUnavailable}, {ErrTargetChanged, ErrorCodeTargetChanged},
		{ErrExtensionUnavailable, ErrorCodeExtensionUnavailable}, {ErrFocusDenied, ErrorCodeFocusDenied},
		{ErrClipboard, ErrorCodeClipboardFailed}, {ErrUnsupported, ErrorCodeUnsupported},
	} {
		if errors.Is(err, item.err) { return item.code }
	}
	return ""
}

type Status string
const (
	StatusPending Status = "pending"
	StatusWaitingConfirm Status = "waiting_confirm"
	StatusActivating Status = "activating"
	StatusPasting Status = "pasting"
	StatusDelivered Status = "delivered"
	StatusTargetUnavailable Status = "target_unavailable"
	StatusManualPasteRequired Status = "manual_paste_required"
	StatusCancelled Status = "cancelled"
	StatusFailed Status = "failed"
)

func (s Status) IsTerminal() bool {
	switch s {
	case StatusDelivered, StatusTargetUnavailable, StatusManualPasteRequired, StatusCancelled, StatusFailed:
		return true
	default:
		return false
	}
}
```

`ErrorCodeOf` 返回空串表示非预期内部错误；API 层沿用现有闭集 `INTERNAL_ERROR`，只记录 requestId 和脱敏上下文，不把原始 OS/窗口错误发送到手机。

- [ ] **Step 4: 运行 delivery 包测试**

Run: `go test ./internal/delivery -v`

Expected: PASS。

- [ ] **Step 5: 提交领域合同**

```powershell
git add fastdrop-desktop/internal/delivery/model.go fastdrop-desktop/internal/delivery/model_test.go
git commit -m "feat: define app delivery domain contracts"
```

### Task 2: 增加配置、设备授权和 delivery_jobs 迁移

**Files:**
- Modify: `fastdrop-desktop/internal/config/config.go`
- Modify: `fastdrop-desktop/internal/config/config_test.go`
- Modify: `fastdrop-desktop/internal/database/db.go`
- Modify: `fastdrop-desktop/internal/database/db_test.go`
- Create: `fastdrop-desktop/migrations/0002_app_delivery.sql`

- [ ] **Step 1: 写配置默认值和旧数据库升级的失败测试**

```go
func TestAppDeliveryDefaultsOff(t *testing.T) {
	cfg := Default()
	if cfg.Delivery.Enabled || cfg.Delivery.ConfirmBeforePaste || cfg.Delivery.ExperimentalEnabled {
		t.Fatalf("delivery defaults must be off: %+v", cfg.Delivery)
	}
}

func TestDeliveryMigrationPreservesExistingDevice(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old-fastdrop.db")
	raw, err := sql.Open("sqlite", "file:"+filepath.ToSlash(path))
	if err != nil { t.Fatal(err) }
	_, err = raw.Exec(`
CREATE TABLE devices (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL,
  app_version TEXT, last_ip TEXT, first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL
);
INSERT INTO devices(id,name,platform,first_seen_at,last_seen_at)
VALUES('phone-1','Phone','android',1,1);`)
	if err != nil { t.Fatal(err) }
	if err := raw.Close(); err != nil { t.Fatal(err) }

	db, err := Open(path)
	if err != nil { t.Fatal(err) }
	t.Cleanup(func() { _ = db.Close() })
	ctx := context.Background()
	got, err := db.GetDevice(ctx, "phone-1")
	if err != nil { t.Fatal(err) }
	if got.Name != "Phone" || got.AllowAppDelivery { t.Fatalf("migrated device=%+v", got) }
	if err := db.SetDeviceAppDeliveryPermission(ctx, got.ID, true); err != nil { t.Fatal(err) }
	updated, err := db.GetDevice(ctx, got.ID)
	if err != nil { t.Fatal(err) }
	if !updated.AllowAppDelivery { t.Fatal("permission was not persisted") }
}
```

- [ ] **Step 2: 确认新字段和 DB 方法缺失**

Run: `Set-Location fastdrop-desktop; go test ./internal/config ./internal/database -run "AppDelivery|DeliveryMigration" -v`

Expected: FAIL，包含 `cfg.Delivery undefined` 和 `SetDeviceAppDeliveryPermission undefined`。

- [ ] **Step 3: 增加配置和数据库模型**

```go
type DeliveryConfig struct {
	Enabled bool `json:"enabled"`
	ConfirmBeforePaste bool `json:"confirmBeforePaste"`
	ExperimentalEnabled bool `json:"experimentalEnabled"`
	ExtensionTokenHash string `json:"extensionTokenHash,omitempty"`
	ExtensionOrigin string `json:"extensionOrigin,omitempty"`
}

type DeliveryJobRow struct {
	ID string `json:"id"`
	TransferID string `json:"transferId"`
	RequestingDeviceID string `json:"requestingDeviceId"`
	AdapterID string `json:"adapterId"`
	TargetKind string `json:"targetKind"`
	Status string `json:"status"`
	CreatedAt int64 `json:"createdAt"`
	StartedAt *int64 `json:"startedAt,omitempty"`
	CompletedAt *int64 `json:"completedAt,omitempty"`
	ErrorCode string `json:"errorCode,omitempty"`
	ErrorMessage string `json:"errorMessage,omitempty"`
}
```

将 `Delivery DeliveryConfig` 加入 `config.Config`，默认三个开关均为 `false`。将 `AllowAppDelivery bool` 加入 `database.Device`，并在 `UpsertDevice` 中保留既有权限，不得被每次 last-seen upsert 重置。

- [ ] **Step 4: 写入可重入迁移**

`fastdrop-desktop/migrations/0002_app_delivery.sql` 内容：

```sql
ALTER TABLE devices ADD COLUMN allow_app_delivery INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS delivery_jobs (
    id                    TEXT PRIMARY KEY,
    transfer_id           TEXT NOT NULL,
    requesting_device_id  TEXT NOT NULL,
    adapter_id            TEXT NOT NULL,
    target_kind           TEXT NOT NULL,
    status                TEXT NOT NULL,
    created_at            INTEGER NOT NULL,
    started_at            INTEGER,
    completed_at          INTEGER,
    error_code            TEXT,
    error_message         TEXT,
    FOREIGN KEY(transfer_id) REFERENCES transfers(id)
);

CREATE INDEX IF NOT EXISTS idx_delivery_jobs_transfer ON delivery_jobs(transfer_id);
CREATE INDEX IF NOT EXISTS idx_delivery_jobs_status ON delivery_jobs(status);
```

`DB.Migrate` 先通过 `PRAGMA table_info(devices)` 确认列是否存在，缺失时才执行 `ALTER TABLE`；`CREATE TABLE/INDEX IF NOT EXISTS` 每次可执行。不通过忽略字符串化的 duplicate-column 错误实现迁移。

- [ ] **Step 5: 实现精确 CRUD 并覆盖重启恢复**

增加：

```go
func (d *DB) SetDeviceAppDeliveryPermission(ctx context.Context, deviceID string, allowed bool) error
func (d *DB) ListDevices(ctx context.Context) ([]Device, error)
func (d *DB) InsertDeliveryJob(ctx context.Context, row DeliveryJobRow) error
func (d *DB) UpdateDeliveryJobStatus(ctx context.Context, id string, status string, errorCode string, errorMessage string, at int64) error
func (d *DB) LatestDeliveryJob(ctx context.Context, transferID string) (*DeliveryJobRow, error)
func (d *DB) MarkInterruptedDeliveryJobsFailed(ctx context.Context) (int64, error)
```

`MarkInterruptedDeliveryJobsFailed` 只更新 `pending`/`waiting_confirm`/`activating`/`pasting`，错误码为 `DELIVERY_TARGET_UNAVAILABLE`，不修改 `transfers`。

- [ ] **Step 6: 运行 DB 和配置回归**

Run: `go test ./internal/config ./internal/database -v`

Expected: PASS。

- [ ] **Step 7: 提交迁移与权限存储**

```powershell
git add fastdrop-desktop/internal/config fastdrop-desktop/internal/database fastdrop-desktop/migrations/0002_app_delivery.sql
git commit -m "feat: persist app delivery settings and jobs"
```

### Task 3: 实现支持列表和会话隔离的目标注册表

**Files:**
- Create: `fastdrop-desktop/internal/delivery/registry.go`
- Create: `fastdrop-desktop/internal/delivery/registry_test.go`

- [ ] **Step 1: 先测试默认只显示正式适配器且 targetId 不能跨会话**

```go
func TestRegistryScopesTargetsToSession(t *testing.T) {
	adapter := &fakeAdapter{meta: AdapterMetadata{ID: "wechat.windows", Enabled: true, Stability: StabilityStable}}
	adapter.candidates = []Candidate{{Target: Target{Kind: TargetNativeApp, AdapterID: "wechat.windows", AppName: "微信"}}}
	registry := NewRegistry([]Adapter{adapter})
	snapshot, err := registry.Snapshot(context.Background(), "session-a", false)
	if err != nil { t.Fatal(err) }
	if len(snapshot.Targets) != 1 { t.Fatalf("targets=%d", len(snapshot.Targets)) }
	if _, err := registry.Resolve("session-b", snapshot.Revision, snapshot.Targets[0].TargetID); !errors.Is(err, ErrTargetUnavailable) {
		t.Fatalf("cross-session resolve err=%v", err)
	}
}

func TestRegistryHidesExperimentalAdaptersByDefault(t *testing.T) {
	adapter := &fakeAdapter{meta: AdapterMetadata{ID: "generic.windows", Enabled: true, Stability: StabilityExperimental}}
	registry := NewRegistry([]Adapter{adapter})
	snapshot, err := registry.Snapshot(context.Background(), "session-a", false)
	if err != nil { t.Fatal(err) }
	if len(snapshot.Targets) != 0 { t.Fatal("experimental target leaked") }
}

type fakeAdapter struct {
	meta AdapterMetadata
	candidates []Candidate
	deliver func(context.Context, Candidate, []string) error
}

func (a *fakeAdapter) Metadata() AdapterMetadata { return a.meta }
func (a *fakeAdapter) Discover(context.Context) ([]Candidate, error) { return a.candidates, nil }
func (a *fakeAdapter) Deliver(ctx context.Context, candidate Candidate, files []string) error {
	if a.deliver == nil { return nil }
	return a.deliver(ctx, candidate, files)
}
```

- [ ] **Step 2: 运行失败测试**

Run: `Set-Location fastdrop-desktop; go test ./internal/delivery -run Registry -v`

Expected: FAIL，包含 `undefined: NewRegistry`。

- [ ] **Step 3: 实现内存快照与解析**

```go
type Snapshot struct {
	Revision string `json:"revision"`
	Targets []Target `json:"targets"`
}

type resolvedTarget struct {
	adapter Adapter
	candidate Candidate
}

type sessionSnapshot struct {
	revision string
	targets map[string]resolvedTarget
}

type Registry struct {
	mu sync.RWMutex
	adapters []Adapter
	bySession map[string]sessionSnapshot
}

func NewRegistry(adapters []Adapter) *Registry {
	return &Registry{adapters: adapters, bySession: make(map[string]sessionSnapshot)}
}
```

`Snapshot` 为每次请求分别调用 `security.GenerateToken()` 生成新 revision 和 targetId（32 字节 `crypto/rand`、Base64URL），对适配器的 `Target.DisplayName` 进行长度上限和控制字符过滤。每个 session 只保留最新 `sessionSnapshot`，刷新后旧 revision 立即失效且不会累积 locator。`Resolve` 需同时匹配 session、revision 和 targetId；返回的 `resolvedTarget` 只在 Go 内存中使用。解析失败统一返回 Task 1 的 `ErrTargetUnavailable`。

- [ ] **Step 4: 测试关闭目标、刷新 revision 和实验开关**

Run: `go test ./internal/delivery -run Registry -v`

Expected: PASS。

- [ ] **Step 5: 提交目标注册表**

```powershell
git add fastdrop-desktop/internal/delivery/registry.go fastdrop-desktop/internal/delivery/registry_test.go
git commit -m "feat: add session-scoped delivery target registry"
```

### Task 4: 接入能力、目标和电脑端设备授权 API

**Files:**
- Create: `fastdrop-desktop/internal/delivery/service.go`
- Create: `fastdrop-desktop/internal/api/handlers_delivery.go`
- Create: `fastdrop-desktop/internal/api/handlers_delivery_test.go`
- Create: `fastdrop-desktop/internal/api/delivery_test_helpers_test.go`
- Modify: `fastdrop-desktop/internal/api/router.go`
- Modify: `fastdrop-desktop/internal/api/handlers_settings.go`
- Modify: `fastdrop-desktop/internal/api/router_test.go`
- Modify: `fastdrop-desktop/cmd/fastdrop/main.go`

- [ ] **Step 1: 先写三组权限测试**

```go
func TestDeliveryTargetsRequireDevicePermission(t *testing.T) {
	srv, ts, session := newDeliveryTestServer(t)
	resp, _ := doReqAuth(t, ts, http.MethodGet, "/api/v1/delivery/targets", session.ID, session.Token, nil)
	if resp.StatusCode != http.StatusForbidden { t.Fatalf("status=%d", resp.StatusCode) }
	if err := srv.DB.SetDeviceAppDeliveryPermission(context.Background(), session.DeviceID, true); err != nil { t.Fatal(err) }
	resp, _ = doReqAuth(t, ts, http.MethodGet, "/api/v1/delivery/targets", session.ID, session.Token, nil)
	if resp.StatusCode != http.StatusOK { t.Fatalf("status=%d", resp.StatusCode) }
}

func TestDeliveryCapabilitiesDoNotExposeTargets(t *testing.T) {
	_, ts, session := newDeliveryTestServer(t)
	resp, body := doReqAuth(t, ts, http.MethodGet, "/api/v1/delivery/capabilities", session.ID, session.Token, nil)
	if resp.StatusCode != http.StatusOK { t.Fatalf("status=%d", resp.StatusCode) }
	if strings.Contains(body, "displayName") { t.Fatalf("capabilities leaked targets: %s", body) }
}

func TestDeliveryPermissionEndpointIsLocalOnly(t *testing.T) {
	srv, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodPut, "/api/v1/settings/delivery/devices/phone-1", strings.NewReader(`{"allowed":true}`))
	req.RemoteAddr = "192.168.1.50:12345"
	res := httptest.NewRecorder()
	New(srv).ServeHTTP(res, req)
	if res.Code != http.StatusForbidden { t.Fatalf("status=%d", res.Code) }
}
```

`delivery_test_helpers_test.go` 提供本章后续 API 测试共用的真实 session：

```go
func newDeliveryTestServer(t *testing.T) (*Server, *httptest.Server, *session.Session) {
	t.Helper()
	srv, cfg := newTestServer(t)
	cfg.Delivery.Enabled = true
	device := database.Device{ID: "phone-1", Name: "Phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1}
	if err := srv.DB.UpsertDevice(device); err != nil { t.Fatal(err) }
	sess, err := srv.Session.Create(context.Background(), device.ID, "")
	if err != nil { t.Fatal(err) }
	srv.Delivery = delivery.NewService(cfg, srv.DB, delivery.NewRegistry(nil))
	ts := httptest.NewServer(New(srv))
	t.Cleanup(ts.Close)
	return srv, ts, sess
}
```

- [ ] **Step 2: 确认端点尚不存在**

Run: `Set-Location fastdrop-desktop; go test ./internal/api -run Delivery -v`

Expected: FAIL 或返回 404。

- [ ] **Step 3: 实现服务能力与权限检查**

```go
type Service struct {
	cfg *config.Config
	db *database.DB
	registry *Registry
}

type CapabilityResponse struct {
	Supported bool `json:"supported"`
	Enabled bool `json:"enabled"`
	Authorized bool `json:"authorized"`
	ConfirmBeforePaste bool `json:"confirmBeforePaste"`
	ExperimentalEnabled bool `json:"experimentalEnabled"`
	ExtensionConnected bool `json:"extensionConnected"`
	Adapters []AdapterCapability `json:"adapters"`
}

func (s *Service) Authorized(ctx context.Context, deviceID string) bool {
	if !s.cfg.Delivery.Enabled { return false }
	device, err := s.db.GetDevice(ctx, deviceID)
	return err == nil && device.AllowAppDelivery
}
```

- [ ] **Step 4: 挂载端点**

```go
mux.HandleFunc("GET /api/v1/delivery/capabilities", s.withAuth(s.handleDeliveryCapabilities))
mux.HandleFunc("GET /api/v1/delivery/targets", s.withAuth(s.handleDeliveryTargets))
mux.HandleFunc("PUT /api/v1/settings/delivery/devices/{deviceId}", withLocalDesktop(s.withSizeLimit(64*1024, s.handleSetDeliveryDevicePermission)))
```

`settingsResponse`/`updateSettingsRequest` 增加 `appDeliveryEnabled`、`deliveryConfirmBeforePaste`、`experimentalDeliveryEnabled`、`deliveryDevices`和适配器/扩展健康状态。本机设置 API 继续使用 `withLocalDesktop`；LAN 请求不得改权限。

- [ ] **Step 5: 在 main 中组装 delivery.Service**

```go
deliveryRegistry := delivery.NewRegistry(nil)
deliveryService := delivery.NewService(cfg, db, deliveryRegistry)
apiSrv.Delivery = deliveryService
if _, err := db.MarkInterruptedDeliveryJobsFailed(context.Background()); err != nil {
	log.Printf("[delivery] recover interrupted jobs: %v", err)
}
```

`api.Server` 增加 `Delivery *delivery.Service`，所有 handler 对 nil 保持可测试的 `DELIVERY_DISABLED` 响应，不 panic。

- [ ] **Step 6: 运行 API 与全部 Go 回归**

Run: `go test ./internal/api ./internal/delivery ./internal/database ./internal/config -v`

Expected: PASS。

- [ ] **Step 7: 提交协议基础**

```powershell
git add fastdrop-desktop/internal/api fastdrop-desktop/internal/delivery fastdrop-desktop/cmd/fastdrop/main.go
git commit -m "feat: expose authorized app delivery targets"
```

### Task 5: 将 deliveryIntent 与投递任务接入文件完成点

**Files:**
- Modify: `fastdrop-desktop/internal/api/handlers_transfer.go`
- Modify: `fastdrop-desktop/internal/api/router.go`
- Modify: `fastdrop-desktop/internal/api/router_test.go`
- Modify: `fastdrop-desktop/internal/websocket/protocol.go`
- Modify: `fastdrop-desktop/internal/delivery/service.go`
- Create: `fastdrop-desktop/internal/delivery/service_test.go`

- [ ] **Step 1: 写“投递失败不阻止传输”的失败测试**

```go
func TestValidButUnavailableIntentStillCreatesTransfer(t *testing.T) {
	srv, ts, session := newDeliveryTestServer(t)
	body := map[string]any{
		"offerId": "offer-1", "direction": "client_to_server",
		"files": []map[string]any{{"clientFileId": "f1", "name": "photo.jpg", "size": 3, "mimeType": "image/jpeg"}},
		"deliveryIntent": map[string]any{"mode": "app", "targetId": "expired", "targetRevision": "old"},
	}
	resp, raw := doReqAuthJSON(t, ts, http.MethodPost, "/api/v1/transfers", session.ID, session.Token, body)
	if resp.StatusCode != http.StatusCreated { t.Fatalf("status=%d body=%s", resp.StatusCode, raw) }
	var got struct { Delivery struct { Accepted bool `json:"accepted"`; ErrorCode string `json:"errorCode"` } `json:"delivery"` }
	if err := json.Unmarshal([]byte(raw), &got); err != nil { t.Fatal(err) }
	if got.Delivery.Accepted || got.Delivery.ErrorCode != "DELIVERY_TARGET_UNAVAILABLE" { t.Fatalf("delivery=%+v", got.Delivery) }
	if transfers, _ := srv.DB.ListTransfersForSession(context.Background(), session.ID); len(transfers) != 1 { t.Fatalf("transfers=%d", len(transfers)) }
}

func TestMalformedIntentRejectsBeforeTransferCreation(t *testing.T) {
	srv, ts, session := newDeliveryTestServer(t)
	body := map[string]any{
		"offerId": "offer-malformed", "direction": "client_to_server",
		"files": []map[string]any{{"clientFileId": "f1", "name": "photo.jpg", "size": 3, "mimeType": "image/jpeg"}},
		"deliveryIntent": map[string]any{"mode": "app", "targetRevision": "r1"},
	}
	resp, raw := doReqAuthJSON(t, ts, http.MethodPost, "/api/v1/transfers", session.ID, session.Token, body)
	if resp.StatusCode != http.StatusBadRequest { t.Fatalf("status=%d body=%s", resp.StatusCode, raw) }
	transfers, err := srv.DB.ListTransfersForSession(context.Background(), session.ID)
	if err != nil { t.Fatal(err) }
	if len(transfers) != 0 { t.Fatalf("transfers=%d", len(transfers)) }
}
```

- [ ] **Step 2: 确认当前响应没有 delivery 结果**

Run: `Set-Location fastdrop-desktop; go test ./internal/api -run "Intent|Delivery" -v`

Expected: FAIL。

- [ ] **Step 3: 增加请求/响应合同与意图绑定**

```go
type createTransferBody struct {
	OfferID string `json:"offerId"`
	Direction string `json:"direction"`
	Files []createTransferFile `json:"files"`
	DeliveryIntent *delivery.Intent `json:"deliveryIntent,omitempty"`
}

type DeliveryAcceptance struct {
	Accepted bool `json:"accepted"`
	JobID string `json:"jobId,omitempty"`
	Status delivery.Status `json:"status,omitempty"`
	ErrorCode string `json:"errorCode,omitempty"`
}
```

`Intent.Validate` 要求 `mode == "app"`、targetId/revision 非空且长度有上限。文件列表含非 `image/*` 时，普通传输继续，投递接受结果为 `DELIVERY_UNSUPPORTED`。

- [ ] **Step 4: 在文件全部完成后入队**

`handleCompleteFile` 现有 `if allDone` 分支改为：

```go
if allDone {
	s.pushWSEvent(callerSession, ws.MsgTransferCompleted, map[string]any{"transferId": transferID})
	if s.Delivery != nil {
		s.Delivery.OnTransferCompleted(context.Background(), transferID)
	}
}
```

`OnTransferCompleted` 读取 `ListTransferFiles`，只把 status=completed 且 `TargetPath` 非空的文件路径交给队列。不从手机请求接收任意本地路径。

- [ ] **Step 5: 增加重投和状态查询端点**

```go
mux.HandleFunc("POST /api/v1/transfers/{transferId}/deliveries", s.withAuth(s.withSizeLimit(64*1024, s.handleCreateDelivery)))
mux.HandleFunc("GET /api/v1/transfers/{transferId}/deliveries", s.withAuth(s.handleGetLatestDelivery))
```

两个 handler 都必须校验 transfer 属于当前 session、direction 为 `client_to_server`、status 为 `completed`。重投只创建 `delivery_jobs`，不创建 transfer/file/chunk 记录。

- [ ] **Step 6: 增加 WebSocket 常量并回归**

```go
const MsgDeliveryStatus MessageType = "delivery.status"
```

Run: `go test ./internal/api ./internal/delivery ./internal/websocket ./internal/transfer -v`

Expected: PASS，现有传输测试无改动地通过。

- [ ] **Step 7: 提交传输意图集成**

```powershell
git add fastdrop-desktop/internal/api fastdrop-desktop/internal/delivery fastdrop-desktop/internal/websocket/protocol.go
git commit -m "feat: bind delivery jobs to completed transfers"
```

---

## 里程碑 B：Windows 投递引擎与微信

### Task 6: 使用 fake automation 实现串行投递协调器

**Files:**
- Create: `fastdrop-desktop/internal/delivery/automation.go`
- Create: `fastdrop-desktop/internal/delivery/coordinator.go`
- Create: `fastdrop-desktop/internal/delivery/coordinator_test.go`
- Modify: `fastdrop-desktop/internal/delivery/service.go`
- Modify: `fastdrop-desktop/internal/api/handlers_delivery.go`
- Modify: `fastdrop-desktop/internal/api/router.go`
- Modify: `fastdrop-desktop/internal/api/handlers_delivery_test.go`

- [ ] **Step 1: 先测试 FIFO、成功恢复剪贴板和失败保留图片**

```go
func TestCoordinatorSerializesJobs(t *testing.T) {
	automation := newFakeAutomation()
	adapter := newRecordingAdapter()
	coordinator := NewCoordinator(automation, allowImmediately, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go coordinator.Run(ctx)
	coordinator.Enqueue(jobForTest("one", adapter, "one.jpg"))
	coordinator.Enqueue(jobForTest("two", adapter, "two.jpg"))
	got := adapter.waitCalls(t, 2)
	if !reflect.DeepEqual(got, []string{"one", "two"}) { t.Fatalf("order=%v", got) }
}

func TestCoordinatorRestoresClipboardOnlyAfterSuccess(t *testing.T) {
	automation := newFakeAutomation()
	adapter := newRecordingAdapter()
	coordinator := NewCoordinator(automation, allowImmediately, nil)
	if err := coordinator.execute(context.Background(), jobForTest("ok", adapter, "photo.jpg")); err != nil { t.Fatal(err) }
	if automation.restoreCalls != 1 { t.Fatalf("restore=%d", automation.restoreCalls) }
	adapter.deliverErr = ErrTargetChanged
	_ = coordinator.execute(context.Background(), jobForTest("failed", adapter, "photo.jpg"))
	if automation.restoreCalls != 1 { t.Fatal("failed job restored clipboard") }
}

func TestCoordinatorWaitsForConfirmationWhenRequired(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	confirm := func(context.Context, Job) error { close(started); <-release; return nil }
	coordinator := NewCoordinator(newFakeAutomation(), confirm, nil)
	done := make(chan error, 1)
	go func() { done <- coordinator.execute(context.Background(), jobForTest("confirm", newRecordingAdapter(), "photo.jpg")) }()
	select { case <-started: case <-time.After(time.Second): t.Fatal("confirmation was not requested") }
	select { case <-done: t.Fatal("job ran before confirmation"); default: }
	close(release)
	if err := <-done; err != nil { t.Fatal(err) }
}

type fakeAutomation struct{ restoreCalls int }
func newFakeAutomation() *fakeAutomation { return &fakeAutomation{} }
func (a *fakeAutomation) SnapshotClipboard(context.Context) (ClipboardSnapshot, error) { return ClipboardSnapshot{}, nil }
func (a *fakeAutomation) SetImageFiles(context.Context, []string) error { return nil }
func (a *fakeAutomation) ActivateAndVerify(context.Context, Candidate) error { return nil }
func (a *fakeAutomation) CaptureForeground(context.Context, []string) (uintptr, error) { return 1, nil }
func (a *fakeAutomation) Paste(context.Context, Candidate) error { return nil }
func (a *fakeAutomation) RestoreClipboard(context.Context, ClipboardSnapshot) error { a.restoreCalls++; return nil }

type recordingAdapter struct {
	calls chan string
	deliverErr error
}
func newRecordingAdapter() *recordingAdapter { return &recordingAdapter{calls: make(chan string, 4)} }
func (a *recordingAdapter) Metadata() AdapterMetadata { return AdapterMetadata{ID: "recording", Enabled: true, Stability: StabilityStable} }
func (a *recordingAdapter) Discover(context.Context) ([]Candidate, error) { return nil, nil }
func (a *recordingAdapter) Deliver(_ context.Context, candidate Candidate, _ []string) error { a.calls <- candidate.Target.TargetID; return a.deliverErr }
func (a *recordingAdapter) waitCalls(t *testing.T, count int) []string {
	t.Helper()
	result := make([]string, 0, count)
	for len(result) < count {
		select { case value := <-a.calls: result = append(result, value); case <-time.After(time.Second): t.Fatal("timed out waiting for delivery") }
	}
	return result
}

func jobForTest(id string, adapter Adapter, file string) Job {
	return Job{ID: id, Target: resolvedTarget{adapter: adapter, candidate: Candidate{Target: Target{TargetID: id}}}, Files: []string{file}}
}

func allowImmediately(context.Context, Job) error { return nil }
```

- [ ] **Step 2: 运行失败测试**

Run: `Set-Location fastdrop-desktop; go test ./internal/delivery -run Coordinator -v`

Expected: FAIL，包含 `undefined: NewCoordinator`。

- [ ] **Step 3: 定义可替换的自动化接口**

```go
type ClipboardSnapshot struct{ value any }

type DesktopAutomation interface {
	SnapshotClipboard(context.Context) (ClipboardSnapshot, error)
	SetImageFiles(context.Context, []string) error
	ActivateAndVerify(context.Context, Candidate) error
	CaptureForeground(context.Context, []string) (uintptr, error)
	Paste(context.Context, Candidate) error
	RestoreClipboard(context.Context, ClipboardSnapshot) error
}
```

`automation.go` 复用 Task 1 的 `ErrFocusDenied`、`ErrTargetChanged`、`ErrClipboard` 等哨兵错误；Windows 边界用 `%w` 包装底层错误，协调器只通过 `errors.Is`/`ErrorCodeOf` 分类，不解析错误字符串。

- [ ] **Step 4: 实现单 worker 队列与状态回调**

```go
type Job struct {
	ID string
	TransferID string
	SessionID string
	DeviceID string
	Target resolvedTarget
	Files []string
}

type StatusCallback func(Job, Status, string)
type ConfirmationFunc func(context.Context, Job) error

type Coordinator struct {
	automation DesktopAutomation
	confirm ConfirmationFunc
	status StatusCallback
	queue chan Job
}

func (c *Coordinator) SetStatusCallback(callback StatusCallback) {
	c.status = callback
}
```

`execute` 严格按 `ConfirmIfRequired → SnapshotClipboard → SetImageFiles → Adapter.Deliver → RestoreClipboard` 调用。适配器负责目标激活和 Paste，协调器只管剪贴板生命周期和串行。只有 `Adapter.Deliver` 成功才恢复；`ErrTargetUnavailable`/`ErrTargetChanged`/`ErrExtensionUnavailable` 映射为 `target_unavailable`，图片已写入后出现的 `ErrFocusDenied` 映射为 `manual_paste_required`，无法建立图片剪贴板的 `ErrClipboard` 映射为 `failed/DELIVERY_CLIPBOARD_FAILED`，拒绝或超时映射为 `cancelled`，未分类错误映射为 `failed/INTERNAL_ERROR`。`Run` 是唯一从 queue 读取的 goroutine，不得为每个 job 启动并行 goroutine。

`ConfirmationFunc` 在设置关闭时立即返回 nil；开启时将 job 放入待确认内存表、推送 `waiting_confirm`，最多等待 30 秒。用户拒绝或超时返回 `StatusCancelled`，不修改 transfer。

`Service` 将 coordinator 状态同时写入 DB 和 WebSocket，不让 `delivery` 包直接依赖 `websocket` 包：

```go
type StatusEvent struct {
	JobID string `json:"jobId"`
	TransferID string `json:"transferId"`
	Status Status `json:"status"`
	ErrorCode string `json:"errorCode,omitempty"`
}

type StatusPublisher func(sessionID string, event StatusEvent)

func (s *Service) handleCoordinatorStatus(job Job, status Status, errorCode string) {
	_ = s.db.UpdateDeliveryJobStatus(context.Background(), job.ID, string(status), errorCode, "", database.Now())
	if s.publish != nil {
		s.publish(job.SessionID, StatusEvent{JobID: job.ID, TransferID: job.TransferID, Status: status, ErrorCode: errorCode})
	}
}

func (s *Service) SetCoordinator(coordinator *Coordinator) {
	coordinator.SetStatusCallback(s.handleCoordinatorStatus)
	s.coordinator = coordinator
}

func (s *Service) SetStatusPublisher(publisher StatusPublisher) {
	s.publish = publisher
}
```

`main.go` 的 publisher 只把 `StatusEvent` 包装为 `websocket.MsgDeliveryStatus` 后调用 `wsHub.Send`。入队前再次检查总开关、设备授权、目标解析和文件路径；权限在传输期间被撤销时，job 终止为 `failed/DELIVERY_NOT_AUTHORIZED`，transfer 保持 `completed`。

- [ ] **Step 5: 接入仅本机可用的确认 API**

```go
mux.HandleFunc("GET /api/v1/local/delivery/confirmations", withLocalDesktop(s.handleListDeliveryConfirmations))
mux.HandleFunc("POST /api/v1/local/delivery/confirmations/{jobId}/accept", withLocalDesktop(s.handleAcceptDeliveryConfirmation))
mux.HandleFunc("POST /api/v1/local/delivery/confirmations/{jobId}/reject", withLocalDesktop(s.handleRejectDeliveryConfirmation))
```

`GET` 只返回 jobId、发起设备的脱敏显示名、adapterId、图片数量和剩余确认时间，不返回图片路径、窗口/标签标题。accept/reject 只能解析当前存在的待确认 job，第二次解析返回 409。`handlers_delivery_test.go` 增加 LAN 禁止和单次解析测试。

- [ ] **Step 6: 运行队列、确认和 race 测试**

Run: `go test -race ./internal/delivery ./internal/api -run "Coordinator|DeliveryConfirmation" -v`

Expected: PASS，无 race report。

- [ ] **Step 7: 提交可测试投递核心**

```powershell
git add fastdrop-desktop/internal/delivery/automation.go fastdrop-desktop/internal/delivery/coordinator.go fastdrop-desktop/internal/delivery/coordinator_test.go fastdrop-desktop/internal/api
git commit -m "feat: add serialized delivery coordinator"
```

### Task 7: 实现 Windows 窗口/剪贴板投递探针

**Files:**
- Modify: `fastdrop-desktop/go.mod`
- Modify: `fastdrop-desktop/go.sum`
- Create: `fastdrop-desktop/internal/delivery/automation_windows.go`
- Create: `fastdrop-desktop/internal/delivery/automation_other.go`
- Create: `fastdrop-desktop/internal/delivery/automation_windows_test.go`
- Create: `fastdrop-desktop/cmd/deliveryprobe/main_windows.go`
- Create: `fastdrop-desktop/cmd/deliveryprobe/main_other.go`

- [ ] **Step 1: 先写 Windows 数据编码的纯函数测试**

```go
//go:build windows

func TestEncodeDropFilesContainsEveryAbsolutePath(t *testing.T) {
	raw, err := encodeDropFiles([]string{`C:\Photos\one.jpg`, `C:\Photos\two.png`})
	if err != nil { t.Fatal(err) }
	decoded := decodeDropFilesForTest(raw)
	want := []string{`C:\Photos\one.jpg`, `C:\Photos\two.png`}
	if !reflect.DeepEqual(decoded, want) { t.Fatalf("decoded=%v", decoded) }
}

func TestSupportedClipboardFormatsExcludePrivateData(t *testing.T) {
	formats := restorableClipboardFormats()
	for _, format := range formats {
		if format == 0 || format >= 0xC000 && formatNameForTest(format) == "" {
			t.Fatalf("unidentified private format %d", format)
		}
	}
}
```

- [ ] **Step 2: 确认 Windows 实现缺失**

Run: `Set-Location fastdrop-desktop; go test ./internal/delivery -run "DropFiles|ClipboardFormats" -v`

Expected: FAIL，包含 `undefined: encodeDropFiles`。

- [ ] **Step 3: 实现 Windows API 边界**

先运行 `Set-Location fastdrop-desktop; go get golang.org/x/sys@v0.46.0; go mod tidy`，把现有间接依赖提升为代码直接依赖，不新增第二套 Win32 封装库。

`automation_windows.go` 使用 `golang.org/x/sys/windows` 和 `windows.NewLazySystemDLL("user32.dll")`/`kernel32.dll`，封装以下调用：

```go
type windowsAutomation struct {
	foreground func() uintptr
}

func NewDesktopAutomation() DesktopAutomation { return &windowsAutomation{foreground: getForegroundWindow} }

func (a *windowsAutomation) ActivateAndVerify(ctx context.Context, candidate Candidate) error
func (a *windowsAutomation) CaptureForeground(ctx context.Context, expectedExecutables []string) (uintptr, error)
func (a *windowsAutomation) SnapshotClipboard(ctx context.Context) (ClipboardSnapshot, error)
func (a *windowsAutomation) SetImageFiles(ctx context.Context, paths []string) error
func (a *windowsAutomation) Paste(ctx context.Context, candidate Candidate) error
func (a *windowsAutomation) RestoreClipboard(ctx context.Context, snapshot ClipboardSnapshot) error
```

`SetImageFiles` 一次写入 `CF_HDROP` 多文件列表和 `Preferred DropEffect=COPY`；对第一张 JPEG/PNG 图片使用标准库 `image/jpeg`/`image/png` 解码、转为 BGRA DIBV5 并同时写入 `CF_DIBV5`，覆盖只接受位图粘贴的应用。GIF/WebP 仍通过 `CF_HDROP` 投递，不伪造不可解码位图。所有路径必须来自 DB `transfer_files.target_path`，在写剪贴板前逐个 `os.Stat` 并校验是普通文件。

`SnapshotClipboard` 备份 `CF_UNICODETEXT`、`CF_TEXT`、`CF_HDROP`、`CF_DIB`、`CF_DIBV5`、`HTML Format`和 `PNG`；其他私有格式不复制。`CaptureForeground` 读取当前 HWND 并校验所属进程可执行文件名在参数白名单中，专供浏览器扩展激活标签页后绑定实际前台窗口。`Paste` 在 `SendInput(Ctrl+V)` 前后都校验 `GetForegroundWindow()` 等于 candidate window，不发送 Enter；键事件派发后等待固定 `1500ms` 消费窗口再返回，协调器随后才恢复剪贴板。

- [ ] **Step 4: 增加平台保底**

`automation_other.go` 需在非 Windows 编译时返回明确 `DELIVERY_UNSUPPORTED`，使 `go test ./...` 不因 build tag 失败。

- [ ] **Step 5: 创建手动探针**

`deliveryprobe` 提供：

```go
type options struct {
	AdapterID string
	GenerateTestImage bool
}
```

`-generate-test-image` 在 `%TEMP%\FastDrop\delivery-probe.png` 生成 256x256 蓝绿渐变 PNG，只执行激活和粘贴，不发送。日志只输出 adapterId、状态和错误码，不输出目标标题或完整文件路径。

- [ ] **Step 6: 编译并运行自动化测试**

Run: `go test ./internal/delivery ./cmd/deliveryprobe -v`

Expected: PASS。

Run: `go build ./cmd/deliveryprobe`

Expected: PASS，生成可运行探针。

- [ ] **Step 7: 提交 Windows 自动化边界**

```powershell
git add fastdrop-desktop/internal/delivery/automation_windows.go fastdrop-desktop/internal/delivery/automation_other.go fastdrop-desktop/internal/delivery/automation_windows_test.go fastdrop-desktop/cmd/deliveryprobe fastdrop-desktop/go.mod fastdrop-desktop/go.sum
git commit -m "feat: add safe Windows clipboard delivery automation"
```

### Task 8: 实现微信正式适配器

**Files:**
- Create: `fastdrop-desktop/internal/delivery/window_provider.go`
- Create: `fastdrop-desktop/internal/delivery/window_provider_windows.go`
- Create: `fastdrop-desktop/internal/delivery/window_provider_other.go`
- Create: `fastdrop-desktop/internal/delivery/wechat.go`
- Create: `fastdrop-desktop/internal/delivery/wechat_test.go`
- Create: `fastdrop-desktop/internal/delivery/generic_windows.go`
- Create: `fastdrop-desktop/internal/delivery/generic_other.go`
- Create: `fastdrop-desktop/internal/delivery/generic_test.go`
- Modify: `fastdrop-desktop/cmd/fastdrop/main.go`

- [ ] **Step 1: 先测试只匹配支持列表且不泄露会话标题**

```go
func TestWeChatAdapterReturnsCurrentConversationWithoutTitle(t *testing.T) {
	provider := &fakeWindowProvider{windows: []WindowInfo{
		{Handle: 11, ExecutableName: "WeChat.exe", Title: "工作群 - 微信", Visible: true},
		{Handle: 12, ExecutableName: "notepad.exe", Title: "secret.txt", Visible: true},
	}}
	adapter := NewWeChatAdapter(provider, newFakeAutomation())
	targets, err := adapter.Discover(context.Background())
	if err != nil { t.Fatal(err) }
	if len(targets) != 1 { t.Fatalf("targets=%d", len(targets)) }
	if targets[0].Target.DisplayName != "微信当前会话" { t.Fatalf("name=%q", targets[0].Target.DisplayName) }
	if targets[0].Target.Domain != "" { t.Fatalf("domain=%q", targets[0].Target.Domain) }
}
```

- [ ] **Step 2: 运行失败测试**

Run: `Set-Location fastdrop-desktop; go test ./internal/delivery -run WeChat -v`

Expected: FAIL，包含 `undefined: NewWeChatAdapter`。

- [ ] **Step 3: 实现最小窗口发现**

```go
type WindowInfo struct {
	Handle uintptr
	ExecutableName string
	ClassName string
	Title string
	Visible bool
	Elevated bool
}

type WindowProvider interface {
	FindByExecutableNames(context.Context, []string) ([]WindowInfo, error)
}
```

Windows provider 使用 `EnumWindows`，先读取 PID/进程可执行文件名并与 `WeChat.exe`/`Weixin.exe` 匹配，只对匹配进程读取窗口类和标题。过滤隐藏、无可交互主窗口、高权限和 FastDrop 自身窗口。

- [ ] **Step 4: 实现微信适配器并注册**

```go
func (a *WeChatAdapter) Metadata() AdapterMetadata {
	return AdapterMetadata{ID: "wechat.windows", Enabled: true, Stability: StabilityStable}
}

func (a *WeChatAdapter) Deliver(ctx context.Context, candidate Candidate, files []string) error {
	if err := a.automation.ActivateAndVerify(ctx, candidate); err != nil { return err }
	return a.automation.Paste(ctx, candidate)
}
```

Coordinator 已在调用 `Deliver` 前将 `files` 写入剪贴板，适配器不得再次清空或覆盖剪贴板。

- [ ] **Step 5: 实现默认禁用的实验性通用适配器**

```go
func (a *GenericWindowsAdapter) Metadata() AdapterMetadata {
	return AdapterMetadata{ID: "generic.windows", Enabled: true, Stability: StabilityExperimental}
}

func (a *GenericWindowsAdapter) Discover(ctx context.Context) ([]Candidate, error) {
	windows, err := a.provider.ListVisibleInteractiveWindows(ctx)
	if err != nil { return nil, err }
	return filterGenericCandidates(windows, []string{"FastDrop.exe", "WeChat.exe", "Weixin.exe"}), nil
}
```

`filterGenericCandidates` 排除系统安全窗口、高权限窗口、FastDrop 自身窗口和已由正式适配器接管的微信窗口。`generic_test.go` 必须验证 Registry 在 `experimental=false` 时完全不调用通用 adapter 的 `Discover`，在 `experimental=true` 时才返回标记为 `experimental` 的目标。

`main.go` 用 `delivery.NewRegistry([]delivery.Adapter{wechatAdapter, genericAdapter})` 替换空注册表，将 coordinator 注入 service，并在 `rootCtx` 下启动唯一 `Coordinator.Run` goroutine。

- [ ] **Step 6: 真机探针验收**

Run: `go run ./cmd/deliveryprobe -adapter wechat.windows -generate-test-image`

Expected: 微信当前会话输入区出现测试图，不自动发送；原剪贴板在成功后恢复。

Run again after switching focus during the activation window.

Expected: 不向新窗口粘贴，返回 `DELIVERY_FOCUS_DENIED` 或 `DELIVERY_TARGET_CHANGED`，剪贴板保留测试图。

- [ ] **Step 7: 回归并提交微信/通用适配器**

Run: `go test ./...`

Expected: PASS。

```powershell
git add fastdrop-desktop/internal/delivery fastdrop-desktop/cmd/fastdrop/main.go
git commit -m "feat: add WeChat and opt-in generic delivery adapters"
```

### Task 9: 增加 Windows 桌面端功能开关和设备授权 UI

**Files:**
- Modify: `fastdrop-desktop/web/package.json`
- Modify: `fastdrop-desktop/web/package-lock.json`
- Create: `fastdrop-desktop/web/vitest.config.ts`
- Create: `fastdrop-desktop/web/src/components/AppDeliverySettings.vue`
- Create: `fastdrop-desktop/web/src/components/AppDeliverySettings.test.ts`
- Create: `fastdrop-desktop/web/src/components/DeliveryConfirmationDialog.vue`
- Create: `fastdrop-desktop/web/src/components/DeliveryConfirmationDialog.test.ts`
- Modify: `fastdrop-desktop/web/src/api.ts`
- Modify: `fastdrop-desktop/web/src/types.ts`
- Modify: `fastdrop-desktop/web/src/DesktopApp.vue`
- Modify: `fastdrop-desktop/web/src/desktop.css`

- [ ] **Step 1: 添加 Vitest 依赖和失败组件测试**

`package.json` 增加 `"test": "vitest run"`，devDependencies 增加 `vitest`、`@vue/test-utils`、`jsdom`。

```ts
it('keeps delivery disabled until the user explicitly enables it', async () => {
  const wrapper = mount(AppDeliverySettings, {
    props: {
      modelValue: { enabled: false, confirmBeforePaste: false, experimentalEnabled: false },
      devices: [{ deviceId: 'phone-1', name: 'Phone', allowed: false }],
      adapters: [{ id: 'wechat.windows', name: '微信', status: 'ready' }],
      extensionStatus: 'not_installed',
    },
  })
  expect(wrapper.find('[data-test="device-permission-phone-1"]').attributes('disabled')).toBeDefined()
  await wrapper.find('[data-test="delivery-enabled"]').setValue(true)
  expect(wrapper.emitted('update:modelValue')).toBeTruthy()
})

it('requires an explicit click before accepting a pending delivery', async () => {
  const wrapper = mount(DeliveryConfirmationDialog, {
    props: { confirmation: { jobId: 'job-1', deviceName: 'Phone', adapterId: 'wechat.windows', imageCount: 2, expiresIn: 20 } },
  })
  expect(wrapper.emitted('accept')).toBeUndefined()
  await wrapper.find('[data-test="accept-delivery"]').trigger('click')
  expect(wrapper.emitted('accept')).toEqual([['job-1']])
})
```

- [ ] **Step 2: 运行失败测试**

Run: `Set-Location fastdrop-desktop/web; npm install; npm test -- --run`

Expected: FAIL，组件不存在。

- [ ] **Step 3: 扩展 API 类型**

```ts
export interface AppDeliverySettingsValue {
  enabled: boolean
  confirmBeforePaste: boolean
  experimentalEnabled: boolean
}

export interface DeliveryDevicePermission {
  deviceId: string
  name: string
  allowed: boolean
}

export async function setDeliveryDevicePermission(deviceId: string, allowed: boolean): Promise<void> {
  await asJson(await fetch(localUrl(`/api/v1/settings/delivery/devices/${encodeURIComponent(deviceId)}`), {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ allowed }),
  }))
}

export async function listDeliveryConfirmations(): Promise<DeliveryConfirmation[]> {
  const data = await asJson<{ confirmations: DeliveryConfirmation[] }>(await fetch(localUrl('/api/v1/local/delivery/confirmations')))
  return data.confirmations
}

export async function resolveDeliveryConfirmation(jobId: string, accepted: boolean): Promise<void> {
  const action = accepted ? 'accept' : 'reject'
  await asJson(await fetch(localUrl(`/api/v1/local/delivery/confirmations/${encodeURIComponent(jobId)}/${action}`), { method: 'POST' }))
}
```

- [ ] **Step 4: 实现设置组件并接入 DesktopApp**

`AppDeliverySettings.vue` 必须显示总开关、隐私说明、每台已配对设备权限、微信/Gemini 适配器健康状态、扩展状态、“投递前确认”和“实验性通用投递”。总开关关闭时，设备授权和两个高级开关禁用。

`DesktopApp.vue` 只管理 API 加载/保存和错误提示，不将组件内部状态再复制一套。

`DesktopApp.vue` 每 500 ms 轮询待确认列表（只在 `deliveryConfirmBeforePaste=true` 时启动），使用 `DeliveryConfirmationDialog` 展示队首任务。accept/reject 请求完成前禁用按钮；超时后自动关闭并刷新列表。

- [ ] **Step 5: 运行测试和生产构建**

Run: `npm test -- --run`

Expected: PASS。

Run: `npm run build`

Expected: PASS，`web/dist` 生成。

- [ ] **Step 6: 提交电脑设置 UI**

```powershell
git add fastdrop-desktop/web/package.json fastdrop-desktop/web/package-lock.json fastdrop-desktop/web/vitest.config.ts fastdrop-desktop/web/src
git commit -m "feat: add desktop app delivery settings"
```

---

## 里程碑 C：浏览器扩展与 Gemini

### Task 10: 实现回环限定的扩展配对和 WebSocket 通道

**Files:**
- Create: `fastdrop-desktop/internal/delivery/extension_pairing.go`
- Create: `fastdrop-desktop/internal/delivery/extension_pairing_test.go`
- Create: `fastdrop-desktop/internal/delivery/extension_hub.go`
- Create: `fastdrop-desktop/internal/delivery/extension_hub_test.go`
- Modify: `fastdrop-desktop/internal/api/handlers_delivery.go`
- Modify: `fastdrop-desktop/internal/api/router.go`
- Modify: `fastdrop-desktop/cmd/fastdrop/main.go`
- Modify: `fastdrop-desktop/web/src/components/AppDeliverySettings.vue`

- [ ] **Step 1: 先测试一次性配对、哈希存储和回环限制**

```go
func TestExtensionPairingTokenIsSingleUse(t *testing.T) {
	m := NewExtensionPairingManager(time.Minute)
	issued, err := m.Issue()
	if err != nil { t.Fatal(err) }
	secret, err := m.Exchange(issued.Code, "chrome-extension://dev-id")
	if err != nil || secret == "" { t.Fatalf("exchange err=%v", err) }
	if _, err := m.Exchange(issued.Code, "chrome-extension://dev-id"); !errors.Is(err, ErrExtensionPairCodeUsed) { t.Fatalf("reuse err=%v", err) }
}

func TestExtensionEndpointsRejectLANAddress(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/local/delivery/extension/pair", strings.NewReader(`{"code":"ABC"}`))
	req.RemoteAddr = "192.168.1.55:50000"
	res := httptest.NewRecorder()
	loopbackOnly(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})).ServeHTTP(res, req)
	if res.Code != http.StatusForbidden { t.Fatalf("status=%d", res.Code) }
}
```

- [ ] **Step 2: 运行失败测试**

Run: `Set-Location fastdrop-desktop; go test ./internal/delivery -run Extension -v`

Expected: FAIL，扩展类型不存在。

- [ ] **Step 3: 实现扩展配对**

```go
type ExtensionPairingManager struct {
	mu sync.Mutex
	ttl time.Duration
	pending map[string]extensionPairCode
	config *config.Config
}

type extensionPairCode struct {
	Hash string
	ExpiresAt time.Time
	Used bool
}
```

`Issue` 用 `crypto/rand` 在不偏置的 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` 字符集中生成 10 位易输入一次性码，只向本机电脑 UI 返回明文，TTL 60 秒，5 次失败后锁定。`Exchange` 成功后再使用 `security.GenerateToken()` 产生 32 字节扩展密钥，返回扩展一次；电脑配置只保存 `security.HashToken(secret)` 和已批准的 extension origin。

- [ ] **Step 4: 实现独立扩展 WS 协议**

WebSocket 路径为 `/extension/v1/ws`，不与手机 `/ws/v1` 共用 session 认证。第一条消息必须是：

```json
{"type":"extension.auth","payload":{"secret":"base64url-secret"}}
```

支持的后续消息是 `extension.targets`、`extension.activate`、`extension.target_ready`、`extension.error`。服务端检查 RemoteAddr 为 loopback、Origin 等于已配对 origin，并使用 constant-time 哈希比较。

- [ ] **Step 5: 挂载本机端点并连接设置 UI**

```go
mux.Handle("/extension/v1/ws", loopbackOnly(extensionHub.Handler()))
mux.Handle("POST /extension/v1/pair", loopbackOnly(withExtensionPairCORS(extensionPairing.ExchangeHandler())))
```

`api.New` 另行挂载 `POST /api/v1/local/delivery/extension/pair-code`，并用 `withLocalDesktop` 保护。`withExtensionPairCORS` 只对 loopback pair 端点接受语法有效的 `chrome-extension://<id>` Origin，回显具体 Origin 而不使用 `*`。配对成功后将该 Origin 锁定到扩展密钥；WebSocket 只接受该 Origin。Desktop UI 的“连接扩展”按钮请求 pair-code 并显示 60 秒倒计时；不把扩展长期 secret 暴露给 Vue UI。

- [ ] **Step 6: 运行安全测试和回归**

Run: `go test ./internal/delivery ./internal/api -run Extension -v`

Expected: PASS。

Run: `go test ./...`

Expected: PASS。

- [ ] **Step 7: 提交扩展本地通道**

```powershell
git add fastdrop-desktop/internal/delivery fastdrop-desktop/internal/api fastdrop-desktop/cmd/fastdrop/main.go fastdrop-desktop/web/src
git commit -m "feat: add secure browser extension bridge"
```

### Task 11: 建立 Chrome/Edge 扩展和 Gemini 适配器

**Files:**
- Create: `fastdrop-browser-extension/package.json`
- Create: `fastdrop-browser-extension/package-lock.json`
- Create: `fastdrop-browser-extension/tsconfig.json`
- Create: `fastdrop-browser-extension/vitest.config.ts`
- Create: `fastdrop-browser-extension/manifest.json`
- Create: `fastdrop-browser-extension/src/protocol.ts`
- Create: `fastdrop-browser-extension/src/background.ts`
- Create: `fastdrop-browser-extension/src/gemini_content.ts`
- Create: `fastdrop-browser-extension/src/popup.ts`
- Create: `fastdrop-browser-extension/popup.html`
- Create: `fastdrop-browser-extension/scripts/build.mjs`
- Create: `fastdrop-browser-extension/tests/setup.ts`
- Create: `fastdrop-browser-extension/tests/background.test.ts`
- Create: `fastdrop-browser-extension/tests/gemini_content.test.ts`
- Create: `fastdrop-desktop/internal/delivery/gemini.go`
- Create: `fastdrop-desktop/internal/delivery/gemini_test.go`
- Create: `fastdrop-desktop/internal/delivery/generic_browser.go`
- Create: `fastdrop-desktop/internal/delivery/generic_browser_test.go`
- Modify: `fastdrop-desktop/cmd/fastdrop/main.go`

- [ ] **Step 1: 创建扩展测试工具和失败测试**

`package.json` 使用 `typescript`、`vite`、`vitest`、`jsdom`、`@types/chrome`，scripts 为 `test`、`typecheck`、`build`。

`vitest.config.ts` 使用 `environment: "jsdom"` 和 `setupFiles: ["./tests/setup.ts"]`。`tests/setup.ts` 在每个测试前安装最小 Chrome API 假对象，避免依赖真实浏览器：

```ts
import { beforeEach, vi } from 'vitest'

beforeEach(() => {
  Object.defineProperty(globalThis, 'chrome', {
    configurable: true,
    value: {
      tabs: { query: vi.fn(), update: vi.fn(), sendMessage: vi.fn() },
      windows: { update: vi.fn() },
      storage: { local: { get: vi.fn(), set: vi.fn() } },
      permissions: { contains: vi.fn(), request: vi.fn() },
    },
  })
})
```

```ts
it('queries only Gemini tabs and activates the selected tab', async () => {
  chrome.tabs.query = vi.fn().mockResolvedValue([{ id: 7, windowId: 3, title: 'Gemini' }])
  chrome.tabs.update = vi.fn().mockResolvedValue({ id: 7 })
  chrome.windows.update = vi.fn().mockResolvedValue({ id: 3 })
  const targets = await listGeminiTargets()
  expect(chrome.tabs.query).toHaveBeenCalledWith({ url: ['https://gemini.google.com/*'] })
  expect(targets).toEqual([{ tabId: 7, windowId: 3, title: 'Gemini', domain: 'gemini.google.com' }])
  await activateGeminiTarget(targets[0])
  expect(chrome.tabs.update).toHaveBeenCalledWith(7, { active: true })
  expect(chrome.windows.update).toHaveBeenCalledWith(3, { focused: true })
})
```

```ts
it('focuses the Gemini composer without reading its text', () => {
  document.body.innerHTML = '<div role="textbox" contenteditable="true">private prompt</div>'
  const composer = document.querySelector('[role="textbox"]') as HTMLElement
  const focus = vi.spyOn(composer, 'focus')
  expect(focusGeminiComposer()).toBe(true)
  expect(focus).toHaveBeenCalled()
  expect(document.body.textContent).toContain('private prompt')
})
```

- [ ] **Step 2: 运行失败测试**

Run: `Set-Location fastdrop-browser-extension; npm install; npm test -- --run`

Expected: FAIL，`listGeminiTargets` 和 `focusGeminiComposer` 不存在。

- [ ] **Step 3: 实现最小权限 manifest**

```json
{
  "manifest_version": 3,
  "name": "FastDrop 应用直达",
  "version": "1.0.0",
  "permissions": ["storage"],
  "optional_permissions": ["tabs"],
  "host_permissions": ["https://gemini.google.com/*", "http://127.0.0.1:9527/*"],
  "background": {"service_worker": "background.js", "type": "module"},
  "content_scripts": [{
    "matches": ["https://gemini.google.com/*"],
    "js": ["gemini_content.js"],
    "run_at": "document_idle"
  }],
  "action": {"default_popup": "popup.html"}
}
```

- [ ] **Step 4: 实现配对、自动重连和标签页操作**

```ts
export async function listGeminiTargets(): Promise<GeminiTarget[]> {
  const tabs = await chrome.tabs.query({ url: ['https://gemini.google.com/*'] })
  return tabs
    .filter((tab): tab is chrome.tabs.Tab & { id: number; windowId: number } => tab.id !== undefined && tab.windowId !== undefined)
    .map(tab => ({ tabId: tab.id, windowId: tab.windowId, title: sanitizeTitle(tab.title ?? 'Gemini'), domain: 'gemini.google.com' }))
}

export async function activateGeminiTarget(target: GeminiTarget): Promise<void> {
  await chrome.tabs.update(target.tabId, { active: true })
  await chrome.windows.update(target.windowId, { focused: true })
  const reply = await chrome.tabs.sendMessage(target.tabId, { type: 'fastdrop.focus_composer' })
  if (reply?.ok !== true) throw new Error('DELIVERY_TARGET_CHANGED')
}
```

popup 将一次性码 POST 到 `http://127.0.0.1:9527/extension/v1/pair`，获得的长期 secret 只存入 `chrome.storage.local`。background 连接 `ws://127.0.0.1:9527/extension/v1/ws`，第一帧发送 `extension.auth`。连接成功、标签页创建/关闭/更新时发送脱敏 `extension.targets`；窗口和 tab ID 只发往本机 Go 服务，不发往手机。

默认不申请宽泛 `tabs` 权限，只依靠 Gemini host permission 查询 Gemini。当用户在电脑端开启“实验性通用投递”后，popup 才通过明确用户手势调用 `chrome.permissions.request({permissions: ['tabs']})`。只在该权限已批准且电脑开关已开启时枚举其他标签页，对手机只返回截断标题与域名，不返回完整 URL。

- [ ] **Step 5: 实现 Gemini 桌面适配器**

`gemini.go` 将 extension hub 上报的目标转换为 `Candidate{Kind: TargetBrowserTab, AdapterID: "gemini.web"}`。`Deliver` 先通过 hub 发送 activate，等待 `target_ready`，然后调用 `CaptureForeground(ctx, []string{"chrome.exe", "msedge.exe"})` 将实际前台 HWND 写入 candidate 的内存 locator，最后调用 `Paste`。剪贴板由 coordinator 在进入 adapter 前写入，Gemini adapter 不再次覆盖。等待超时、tab 关闭、前台进程不是 Chrome/Edge 或 content script 未就绪时返回 `DELIVERY_TARGET_UNAVAILABLE`。

`generic_browser.go` 注册 `generic.browser`/`StabilityExperimental`，只消费扩展在可选 `tabs` 权限下上报的非 Gemini 标签页。它只激活标签页、绑定 Chrome/Edge 前台窗口并执行粘贴，不注入任意站点 content script；页面没有已聚焦输入区时降级为 `manual_paste_required`。

- [ ] **Step 6: 构建扩展并运行单元测试**

Run: `npm test -- --run`

Expected: PASS。

Run: `npm run typecheck`

Expected: PASS。

Run: `npm run build`

Expected: `fastdrop-browser-extension/dist/manifest.json`、`background.js`、`gemini_content.js`、`popup.html` 全部存在。

Run: `Set-Location ../fastdrop-desktop; go test ./internal/delivery -run Gemini -v`

Expected: PASS。

- [ ] **Step 7: 本机 Gemini 真机验收**

1. 在 Chrome 和 Edge 中分别以“加载已解压的扩展程序”加载 `dist`。
2. 用电脑 FastDrop 生成一次性码，在扩展 popup 中完成配对。
3. 打开两个 Gemini 标签页，确认 target list 只显示这两个，不显示其他标签页。
4. 向第二个 target 投递测试图，图片出现但不自动提交。

- [ ] **Step 8: 提交浏览器与 Gemini 适配器**

```powershell
git add fastdrop-browser-extension fastdrop-desktop/internal/delivery/gemini.go fastdrop-desktop/internal/delivery/gemini_test.go fastdrop-desktop/cmd/fastdrop/main.go
git commit -m "feat: add Gemini browser delivery adapter"
```

---

## 里程碑 D：Android 交互、重投和全链路验收

### Task 12: 实现手机 delivery 模型、API 客户端和传输意图

**Files:**
- Create: `fastdrop-mobile/lib/features/app_delivery/models.dart`
- Create: `fastdrop-mobile/lib/features/app_delivery/delivery_client.dart`
- Create: `fastdrop-mobile/test/features/app_delivery/delivery_client_test.dart`
- Modify: `fastdrop-mobile/lib/shared/models/transfer.dart`
- Modify: `fastdrop-mobile/lib/features/transfer/transfer_service.dart`
- Modify: `fastdrop-mobile/test/features/transfer/transfer_service_test.dart`

- [ ] **Step 1: 先测试可选 deliveryIntent 的序列化与传输兼容性**

```dart
test('CreateTransferBody omits deliveryIntent for normal transfer', () {
  final body = CreateTransferBody(
    offerId: 'o1', direction: 'client_to_server', files: const [],
  );
  expect(body.toJson().containsKey('deliveryIntent'), isFalse);
});

test('CreateTransferBody serializes selected app target', () {
  final body = CreateTransferBody(
    offerId: 'o1', direction: 'client_to_server', files: const [],
    deliveryIntent: const DeliveryIntent(mode: 'app', targetId: 't1', targetRevision: 'r1'),
  );
  expect(body.toJson()['deliveryIntent'], {
    'mode': 'app', 'targetId': 't1', 'targetRevision': 'r1',
  });
});
```

Mock server 再增加断言：传入 intent 时 POST body 包含完整字段；不传 intent 时请求 body 与当前版本一致。

- [ ] **Step 2: 运行失败测试**

Run: `Set-Location fastdrop-mobile; flutter test test/features/transfer/transfer_service_test.dart`

Expected: FAIL，`DeliveryIntent` 或新参数不存在。

- [ ] **Step 3: 实现手机合同模型**

```dart
class DeliveryIntent {
  const DeliveryIntent({required this.mode, required this.targetId, required this.targetRevision});
  final String mode;
  final String targetId;
  final String targetRevision;
  Map<String, dynamic> toJson() => {
    'mode': mode,
    'targetId': targetId,
    'targetRevision': targetRevision,
  };
}

class DeliveryTarget {
  const DeliveryTarget({
    required this.targetId, required this.kind, required this.adapterId,
    required this.appName, required this.displayName, required this.iconKey,
    required this.stability, required this.supportsMultipleImages, this.domain,
  });
  final String targetId;
  final String kind;
  final String adapterId;
  final String appName;
  final String displayName;
  final String iconKey;
  final String stability;
  final bool supportsMultipleImages;
  final String? domain;
}
```

`DeliveryCapabilities`、`DeliveryTargetSnapshot`、`DeliveryAcceptance`、`DeliveryStatusEvent` 按 Go JSON 字段实现 `fromJson`，未知状态保留原始字符串而不崩溃。

- [ ] **Step 4: 实现 delivery REST 客户端**

```dart
class DeliveryClient {
  const DeliveryClient(this.httpClient);
  final FastDropHttpClient httpClient;

  Future<DeliveryCapabilities> capabilities() async {
    final response = await httpClient.get('/api/v1/delivery/capabilities');
    return DeliveryCapabilities.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<DeliveryTargetSnapshot> targets() async {
    final response = await httpClient.get('/api/v1/delivery/targets');
    return DeliveryTargetSnapshot.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<DeliveryAcceptance> redeliver(String transferId, DeliveryIntent intent) async {
    final safeId = Uri.encodeComponent(transferId);
    final response = await httpClient.post('/api/v1/transfers/$safeId/deliveries', body: intent.toJson());
    return DeliveryAcceptance.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<DeliveryStatusEvent?> latest(String transferId) async {
    final safeId = Uri.encodeComponent(transferId);
    final response = await httpClient.get('/api/v1/transfers/$safeId/deliveries');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final value = json['delivery'];
    return value is Map<String, dynamic> ? DeliveryStatusEvent.fromJson(value) : null;
  }
}
```

方法分别调用 `/api/v1/delivery/capabilities`、`/api/v1/delivery/targets`、`POST /api/v1/transfers/{id}/deliveries`、`GET /api/v1/transfers/{id}/deliveries`，错误继续使用 `AppError`。

- [ ] **Step 5: 将意图传入 TransferService**

```dart
Future<void> uploadFiles(
  List<String> filePaths, {
  String? offerId,
  DeliveryIntent? deliveryIntent,
}) async
```

`CreateTransferBody` 只在 `deliveryIntent != null` 时写字段。解析 create response 的可选 `delivery` 结果，通过新 `DeliveryAcceptanceCallback` 通知上层，不将 `accepted=false` 当作文件上传失败。

- [ ] **Step 6: 运行手机协议测试**

Run: `flutter test test/features/app_delivery/delivery_client_test.dart test/features/transfer/transfer_service_test.dart`

Expected: PASS。

- [ ] **Step 7: 提交手机协议层**

```powershell
git add fastdrop-mobile/lib/features/app_delivery fastdrop-mobile/lib/shared/models/transfer.dart fastdrop-mobile/lib/features/transfer/transfer_service.dart fastdrop-mobile/test/features/app_delivery fastdrop-mobile/test/features/transfer/transfer_service_test.dart
git commit -m "feat: add mobile app delivery protocol client"
```

### Task 13: 实现按电脑选择目标、状态推送和免上传重投

**Files:**
- Create: `fastdrop-mobile/lib/features/app_delivery/delivery_providers.dart`
- Create: `fastdrop-mobile/test/features/app_delivery/delivery_providers_test.dart`
- Modify: `fastdrop-mobile/lib/features/devices/multi_device_connection.dart`
- Modify: `fastdrop-mobile/lib/features/transfer/transfer_screen.dart`
- Modify: `fastdrop-mobile/lib/core/storage/transfer_history_store.dart`
- Modify: `fastdrop-mobile/lib/shared/models/transfer.dart`
- Modify: `fastdrop-mobile/test/core/storage/transfer_history_store_test.dart`

- [ ] **Step 1: 先测试每台电脑使用自己的 intent**

```dart
test('fan-out selects only the intent mapped to the current peer', () {
  const intents = {
    'pc-1': DeliveryIntent(mode: 'app', targetId: 'wechat', targetRevision: 'r1'),
    'pc-2': DeliveryIntent(mode: 'app', targetId: 'gemini', targetRevision: 'r2'),
  };
  expect(deliveryIntentForDevice('pc-1', intents)?.targetId, 'wechat');
  expect(deliveryIntentForDevice('pc-2', intents)?.targetId, 'gemini');
  expect(deliveryIntentForDevice('phone-1', intents), isNull);
});
```

- [ ] **Step 2: 先测试 delivery.status 不覆盖 transfer.completed**

```dart
test('delivery failure remains separate from completed transfer status', () {
  final controller = DeliveryStatusController();
  controller.recordTransferStatus('pc-1', 't1', 'completed');
  controller.handleWs('pc-1', {
    'type': 'delivery.status',
    'payload': {'transferId': 't1', 'jobId': 'j1', 'status': 'manual_paste_required'},
  });
  expect(controller.state['pc-1::t1']?.transferStatus, 'completed');
  expect(controller.state['pc-1::t1']?.deliveryStatus, 'manual_paste_required');
});
```

- [ ] **Step 3: 运行失败测试**

Run: `Set-Location fastdrop-mobile; flutter test test/features/app_delivery test/features/transfer/transfer_service_test.dart`

Expected: FAIL，新 provider 和 fan-out 参数不存在。

- [ ] **Step 4: 实现 Riverpod 设置和状态**

```dart
abstract interface class AppDeliveryPreferenceStore {
  Future<bool> readEnabled();
  Future<void> writeEnabled(bool value);
}

class AppDeliverySettingsNotifier extends StateNotifier<bool> {
  AppDeliverySettingsNotifier(this._store) : super(false) { unawaited(load()); }
  final AppDeliveryPreferenceStore _store;
  Future<void> load() async { state = await _store.readEnabled(); }
  Future<void> setEnabled(bool value) async {
    state = value;
    await _store.writeEnabled(value);
  }
}

final deliveryStatusProvider = StateNotifierProvider<DeliveryStatusController, Map<String, DeliveryUiState>>(
  (ref) => DeliveryStatusController(),
);
```

`SharedPreferencesAppDeliveryStore` 实现 `AppDeliveryPreferenceStore`，使用唯一 key `fastdrop.app_delivery_enabled`；provider 生产环境注入该实现，测试注入内存 store，不在 widget 内直接读写 SharedPreferences。

- [ ] **Step 5: 扩展 MultiDeviceConnection**

```dart
Future<DeliveryCapabilities> getDeliveryCapabilities(String deviceId)
Future<DeliveryTargetSnapshot> getDeliveryTargets(String deviceId)
Future<DeliveryAcceptance> redeliver(String deviceId, String transferId, DeliveryIntent intent)

Future<void> uploadFilesToDevices({
  required List<String> deviceIds,
  required List<String> filePaths,
  Map<String, DeliveryIntent> deliveryIntentsByDevice = const {},
  MultiTransferProgressCallback? onProgress,
  MultiTransferStateCallback? onStateChange,
})
```

在同文件实现并使用纯函数，避免 fan-out 循环误用其他电脑的 target：

```dart
DeliveryIntent? deliveryIntentForDevice(
  String deviceId,
  Map<String, DeliveryIntent> intents,
) => intents[deviceId];
```

每个 peer 创建 `TransferService` 后，调用 `uploadFiles` 时只传入 `deliveryIntentForDevice(deviceId, deliveryIntentsByDevice)`。

`_onWsMessage` 增加 `case 'delivery.status'`，将事件转交 `deliveryStatusProvider.notifier`。不更改已有 `transfer.completed` 处理。

- [ ] **Step 6: 扩展本地历史记录**

`TransferRow` 增加可选 `deliveryJobId`、`deliveryStatus`、`deliveryErrorCode`。`TransferHistoryStore.fromJson` 对旧记录的缺失字段返回 null。当 WS delivery 事件到达时更新对应 deviceId+transferId 记录，不改 transfer status。

- [ ] **Step 7: 运行多机和历史回归**

Run: `flutter test test/features/app_delivery test/core/storage/transfer_history_store_test.dart test/features/transfer/transfer_screen_lifecycle_test.dart`

Expected: PASS。

- [ ] **Step 8: 提交手机状态编排**

```powershell
git add fastdrop-mobile/lib/features/app_delivery fastdrop-mobile/lib/features/devices/multi_device_connection.dart fastdrop-mobile/lib/features/transfer/transfer_screen.dart fastdrop-mobile/lib/core/storage/transfer_history_store.dart fastdrop-mobile/lib/shared/models/transfer.dart fastdrop-mobile/test
git commit -m "feat: coordinate per-device delivery intents"
```

### Task 14: 实现手机附加入口、目标选择和历史重投 UI

**Files:**
- Create: `fastdrop-mobile/lib/features/app_delivery/delivery_target_sheet.dart`
- Create: `fastdrop-mobile/test/features/app_delivery/delivery_target_sheet_test.dart`
- Modify: `fastdrop-mobile/lib/features/file_picker/file_picker_screen.dart`
- Modify: `fastdrop-mobile/lib/features/settings/settings_screen.dart`
- Modify: `fastdrop-mobile/lib/features/history/history_screen.dart`
- Modify: `fastdrop-mobile/test/widget_test.dart`

- [ ] **Step 1: 先写功能关闭与目标分组的失败测试**

```dart
test('normal send does not offer app delivery while feature is off', () {
  expect(canOfferAppDelivery(
    deliveryEnabled: false,
    selectedFileNames: const ['photo.jpg'],
    hasSelectedWindowsDevice: true,
  ), isFalse);
});

testWidgets('target sheet groups supported targets by Windows computer', (tester) async {
  DeliveryTarget target(String id, String name, String adapter) => DeliveryTarget(
    targetId: id, kind: adapter == 'gemini.web' ? 'browser_tab' : 'native_app',
    adapterId: adapter, appName: name, displayName: name, iconKey: adapter,
    stability: 'stable', supportsMultipleImages: true,
  );
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: DeliveryTargetSheet(
    groups: [
      DeliveryTargetGroup(deviceId: 'pc-1', deviceName: 'PC 1', revision: 'r1', targets: [
        target('w1', '微信当前会话', 'wechat.windows'), target('g1', 'Gemini', 'gemini.web'),
      ]),
      DeliveryTargetGroup(deviceId: 'pc-2', deviceName: 'PC 2', revision: 'r2', targets: [
        target('w2', '微信当前会话', 'wechat.windows'),
      ]),
    ],
    onConfirm: (_) {},
  ))));
  expect(find.text('PC 1'), findsOneWidget);
  expect(find.text('PC 2'), findsOneWidget);
  expect(find.text('Gemini'), findsOneWidget);
});
```

- [ ] **Step 2: 运行失败测试**

Run: `Set-Location fastdrop-mobile; flutter test test/features/app_delivery/delivery_target_sheet_test.dart test/widget_test.dart`

Expected: FAIL，目标 sheet 和入口不存在。

- [ ] **Step 3: 实现设置和发送页附加入口**

Settings 增加默认关闭的“应用直达” SwitchListTile，副文案明确说明电脑还需按设备授权。

File picker 提取并单测以下纯函数，只在返回 true 时显示“发送到电脑应用”：

```dart
bool canOfferAppDelivery({
  required bool deliveryEnabled,
  required List<String> selectedFileNames,
  required bool hasSelectedWindowsDevice,
}) => deliveryEnabled &&
    selectedFileNames.isNotEmpty &&
    selectedFileNames.every(isImageFileName) &&
    hasSelectedWindowsDevice;
```

普通“发送”按钮仍不获取 targets，不携带 intent。只有用户点击附加入口才并行请求已选 Windows 电脑的 capabilities/targets。

- [ ] **Step 4: 实现按电脑分组的 target sheet**

`delivery_target_sheet.dart` 定义 `DeliveryTargetGroup(deviceId, deviceName, revision, targets)` 和 `DeliveryTargetSheet(groups, onConfirm)`；sheet 通过 `onConfirm(Map<String, DeliveryIntent>)` 返回结果。每台 Windows 电脑必须选一个目标，非 Windows 设备不显示目标选择。稳定目标与“实验性”目标分组；扩展未连接时显示电脑端修复引导，不显示伪 Gemini 目标。

- [ ] **Step 5: 将 intents 随导航参数传入 TransferScreen**

```dart
arguments: {
  'filePaths': paths,
  'targetDeviceIds': targets,
  'deliveryIntentsByDevice': intents.map((key, value) => MapEntry(key, value.toJson())),
}
```

`TransferScreen.didChangeDependencies` 解析后交给 `setPendingFiles`；现有无该字段的导航保持原行为。

- [ ] **Step 6: 实现历史重投**

History 对 `transfer.status == completed` 且 delivery 为 `target_unavailable`/`manual_paste_required`/`failed` 的记录显示“重新投递”。点击后只获取该电脑 targets，调用 `redeliver`，不读取或重建手机临时文件。

- [ ] **Step 7: 运行手机 UI 和全量测试**

Run: `flutter test`

Expected: PASS。

Run: `flutter analyze`

Expected: 无 error。

- [ ] **Step 8: 提交手机应用直达 UI**

```powershell
git add fastdrop-mobile/lib/features/app_delivery fastdrop-mobile/lib/features/file_picker/file_picker_screen.dart fastdrop-mobile/lib/features/settings/settings_screen.dart fastdrop-mobile/lib/features/history/history_screen.dart fastdrop-mobile/lib/features/transfer/transfer_screen.dart fastdrop-mobile/test
git commit -m "feat: add optional app delivery flow on mobile"
```

### Task 15: 隐私、多机和真机端到端验收

**Files:**
- Create: `fastdrop-desktop/internal/api/delivery_e2e_test.go`
- Create: `fastdrop-desktop/internal/api/delivery_e2e_helpers_test.go`
- Create: `fastdrop-desktop/internal/delivery/privacy_test.go`
- Create: `docs/qa/application-delivery-compatibility.md`
- Modify: `fastdrop-desktop/e2e-test.ps1`

- [ ] **Step 1: 写服务端端到端失败测试**

```go
func TestDeliveryE2ETransferCompletesBeforeDeliveryFails(t *testing.T) {
	srv, ts, session := newDeliveryTestServerWithFakeAdapter(t, fakeAdapterClosingBeforePaste())
	transferID := createAndCompleteImageTransfer(t, srv, ts, session, validIntent(t, srv, session))
	transfer, err := srv.DB.GetTransfer(context.Background(), transferID)
	if err != nil { t.Fatal(err) }
	if transfer.Status != "completed" { t.Fatalf("transfer status=%s", transfer.Status) }
	job, err := srv.DB.LatestDeliveryJob(context.Background(), transferID)
	if err != nil { t.Fatal(err) }
	if job.Status != "target_unavailable" { t.Fatalf("delivery status=%s", job.Status) }
}
```

`delivery_e2e_helpers_test.go` 写入以下完整辅助边界，所有 HTTP 请求继续经过真实 router/session middleware：

```go
type closingAdapter struct{}
func fakeAdapterClosingBeforePaste() delivery.Adapter { return closingAdapter{} }
func (closingAdapter) Metadata() delivery.AdapterMetadata { return delivery.AdapterMetadata{ID: "wechat.windows", Enabled: true, Stability: delivery.StabilityStable} }
func (closingAdapter) Discover(context.Context) ([]delivery.Candidate, error) {
	return []delivery.Candidate{{Target: delivery.Target{Kind: delivery.TargetNativeApp, AdapterID: "wechat.windows", AppName: "微信", DisplayName: "微信当前会话", Capabilities: delivery.Capabilities{Images: true, MultipleImages: true}}}}, nil
}
func (closingAdapter) Deliver(context.Context, delivery.Candidate, []string) error { return delivery.ErrTargetUnavailable }

type e2eAutomation struct{}
func (e2eAutomation) SnapshotClipboard(context.Context) (delivery.ClipboardSnapshot, error) { return delivery.ClipboardSnapshot{}, nil }
func (e2eAutomation) SetImageFiles(context.Context, []string) error { return nil }
func (e2eAutomation) ActivateAndVerify(context.Context, delivery.Candidate) error { return nil }
func (e2eAutomation) CaptureForeground(context.Context, []string) (uintptr, error) { return 1, nil }
func (e2eAutomation) Paste(context.Context, delivery.Candidate) error { return nil }
func (e2eAutomation) RestoreClipboard(context.Context, delivery.ClipboardSnapshot) error { return nil }

func newDeliveryTestServerWithFakeAdapter(t *testing.T, adapter delivery.Adapter) (*Server, *httptest.Server, *session.Session) {
	t.Helper()
	srv, cfg := newTestServer(t)
	cfg.Delivery.Enabled = true
	device := database.Device{ID: "phone-e2e", Name: "Phone", Platform: "android", FirstSeenAt: 1, LastSeenAt: 1}
	if err := srv.DB.UpsertDevice(device); err != nil { t.Fatal(err) }
	if err := srv.DB.SetDeviceAppDeliveryPermission(context.Background(), device.ID, true); err != nil { t.Fatal(err) }
	sess, err := srv.Session.Create(context.Background(), device.ID, "")
	if err != nil { t.Fatal(err) }
	registry := delivery.NewRegistry([]delivery.Adapter{adapter})
	coordinator := delivery.NewCoordinator(e2eAutomation{}, func(context.Context, delivery.Job) error { return nil }, nil)
	srv.Delivery = delivery.NewService(cfg, srv.DB, registry)
	srv.Delivery.SetCoordinator(coordinator)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go coordinator.Run(ctx)
	ts := httptest.NewServer(New(srv))
	t.Cleanup(ts.Close)
	return srv, ts, sess
}

func validIntent(t *testing.T, srv *Server, sess *session.Session) delivery.Intent {
	t.Helper()
	snapshot, err := srv.Delivery.Targets(context.Background(), sess.ID, sess.DeviceID)
	if err != nil { t.Fatal(err) }
	if len(snapshot.Targets) != 1 { t.Fatalf("targets=%d", len(snapshot.Targets)) }
	return delivery.Intent{Mode: "app", TargetID: snapshot.Targets[0].TargetID, TargetRevision: snapshot.Revision}
}

func createAndCompleteImageTransfer(t *testing.T, srv *Server, ts *httptest.Server, sess *session.Session, intent delivery.Intent) string {
	t.Helper()
	content := []byte("img")
	sum := sha256.Sum256(content)
	hash := hex.EncodeToString(sum[:])
	body := map[string]any{
		"offerId": "e2e-offer", "direction": "client_to_server",
		"files": []map[string]any{{"clientFileId": "image-1", "name": "photo.jpg", "size": len(content), "mimeType": "image/jpeg", "sha256": hash}},
		"deliveryIntent": intent,
	}
	resp, raw := doReqAuthJSON(t, ts, http.MethodPost, "/api/v1/transfers", sess.ID, sess.Token, body)
	if resp.StatusCode != http.StatusCreated { t.Fatalf("create status=%d body=%s", resp.StatusCode, raw) }
	var created struct { TransferID string `json:"transferId"`; Files []struct { FileID string `json:"fileId"` } `json:"files"` }
	if err := json.Unmarshal([]byte(raw), &created); err != nil { t.Fatal(err) }
	chunkPath := "/api/v1/transfers/" + created.TransferID + "/files/" + created.Files[0].FileID + "/chunks/0"
	resp, raw = doReqAuth(t, ts, http.MethodPut, chunkPath, sess.ID, sess.Token, content)
	if resp.StatusCode != http.StatusOK { t.Fatalf("chunk status=%d body=%s", resp.StatusCode, raw) }
	completePath := "/api/v1/transfers/" + created.TransferID + "/files/" + created.Files[0].FileID + "/complete"
	resp, raw = doReqAuthJSON(t, ts, http.MethodPost, completePath, sess.ID, sess.Token, map[string]any{"size": len(content), "sha256": hash})
	if resp.StatusCode != http.StatusOK { t.Fatalf("complete status=%d body=%s", resp.StatusCode, raw) }
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		job, err := srv.DB.LatestDeliveryJob(context.Background(), created.TransferID)
		if err == nil && delivery.Status(job.Status).IsTerminal() { return created.TransferID }
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("delivery job did not reach a terminal state")
	return ""
}
```

- [ ] **Step 2: 写隐私回归测试**

```go
func TestDeliveryPersistenceContainsNoWindowOrURLMetadata(t *testing.T) {
	db := openDeliveryDB(t)
	insertCompletedDeliveryForTest(t, db, "gemini.web")
	for _, column := range []string{"target_id", "window_title", "tab_title", "url", "pid", "hwnd"} {
		if databaseHasColumn(t, db, "delivery_jobs", column) { t.Fatalf("forbidden column %s", column) }
	}
}
```

`privacy_test.go` 的辅助函数使用真实 SQLite schema：

```go
func openDeliveryDB(t *testing.T) *database.DB {
	t.Helper()
	db, err := database.Open(filepath.Join(t.TempDir(), "privacy.db"))
	if err != nil { t.Fatal(err) }
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func databaseHasColumn(t *testing.T, db *database.DB, table string, column string) bool {
	t.Helper()
	rows, err := db.Query("PRAGMA table_info(" + table + ")")
	if err != nil { t.Fatal(err) }
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, kind string
		var notNull, primaryKey int
		var defaultValue sql.NullString
		if err := rows.Scan(&cid, &name, &kind, &notNull, &defaultValue, &primaryKey); err != nil { t.Fatal(err) }
		if name == column { return true }
	}
	return false
}

func insertCompletedDeliveryForTest(t *testing.T, db *database.DB, adapterID string) {
	t.Helper()
	ctx := context.Background()
	if err := db.InsertTransfer(ctx, database.TransferRow{ID: "transfer-1", PeerDeviceID: "phone-1", Direction: "client_to_server", Status: "completed", TotalFiles: 1, TotalBytes: 3, TransferredBytes: 3, CreatedAt: 1}); err != nil { t.Fatal(err) }
	if err := db.InsertDeliveryJob(ctx, database.DeliveryJobRow{ID: "job-1", TransferID: "transfer-1", RequestingDeviceID: "phone-1", AdapterID: adapterID, TargetKind: "browser_tab", Status: "delivered", CreatedAt: 1}); err != nil { t.Fatal(err) }
}
```

- [ ] **Step 3: 运行所有自动化验证**

```powershell
Set-Location fastdrop-desktop
go test -race ./...
Set-Location web
npm test -- --run
npm run build
Set-Location ..\..\fastdrop-browser-extension
npm test -- --run
npm run typecheck
npm run build
Set-Location ..\fastdrop-mobile
flutter analyze
flutter test
```

Expected: 所有命令退出码 0。

- [ ] **Step 4: 构建 Windows 桌面应用和 Android APK**

```powershell
Set-Location fastdrop-desktop
.\build.cmd
Set-Location ..\fastdrop-mobile
Set-Location android
.\gradlew.bat :app:assembleDebug
```

Expected: Windows FastDrop 可执行文件和 Android debug APK 均生成。

- [ ] **Step 5: 完成单机、多机和异常真机矩阵**

`docs/qa/application-delivery-compatibility.md` 记录以下每项的 Windows 版本、应用/浏览器版本、扩展版本、手机型号、实际结果和日志任务 ID：

1. 功能未开启：普通图片/文件传输不请求 target。
2. 未授权手机：能力可见，targets 返回 403。
3. 微信单图和多图：进入当前会话，不自动发送。
4. Chrome Gemini 单图/多图：进入手机选择的标签页，不提交。
5. Edge Gemini 单图/多图：与 Chrome 相同。
6. 目标中途关闭：文件 completed，delivery target_unavailable，可免上传重投。
7. 用户主动切换前台：不粘贴错窗口，剪贴板保留图片。
8. 原剪贴板分别为文本、HTML、图片、文件列表：成功后恢复。
9. 两台手机同时向同一电脑投递：文件并行，粘贴 FIFO 串行，无交叉。
10. 扩展断开/重连：Gemini target 正确消失/恢复，微信不受影响。
11. 电脑重启：旧 targetId 失效，未完投递标记失败，文件仍可重投。
12. 管理员权限目标和锁屏：不执行粘贴。

- [ ] **Step 6: 检查日志和数据库脱敏**

Run: `rg -n "gemini\.google\.com/|windowTitle|tabTitle|targetPath|NativeWindow|BrowserTabID" fastdrop-desktop\server.log`

Expected: 无完整 URL、窗口/标签标题、完整文件路径或内部 locator；日志只有脱敏 job/adapter/status/error code。

- [ ] **Step 7: 提交全链路验收资产**

```powershell
git add fastdrop-desktop/internal/api/delivery_e2e_test.go fastdrop-desktop/internal/delivery/privacy_test.go fastdrop-desktop/e2e-test.ps1 docs/qa/application-delivery-compatibility.md
git commit -m "test: verify app delivery end to end"
```

- [ ] **Step 8: 执行完成前验证**

使用 `verification-before-completion` 重新运行 Step 3/4 的完整命令，查看实际输出；不得根据旧日志宣称完成。然后使用 `requesting-code-review` 审查安全边界、回归风险和设计覆盖。

---

## 里程碑验收门槛

- **A 通过：** 功能默认关闭；设备权限、target 会话隔离、可选 intent、独立 delivery job 和重投 API 全部有自动化测试；无 intent 传输全量回归通过。
- **B 通过：** 微信单/多图真机进入当前会话，不自动发送；焦点变化时不误粘贴；成功恢复常见剪贴板，失败保留图片。
- **C 通过：** 扩展只发现 Gemini，能激活手机指定标签页，图片不自动提交；扩展通道只能回环访问并使用独立哈希密钥。
- **D 通过：** 手机附加入口、每电脑 target、delivery 状态、免上传重投、两手机 FIFO、脱敏和全量回归全部通过。
