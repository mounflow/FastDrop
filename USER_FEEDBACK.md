# FastDrop 用户反馈与问题记录

> 记录日期：2026-07-22
> 来源：真机 E2E 测试后用户反馈

---

## 问题 1：手机传照片后相册里出现重复文件

**现象：** 每次从手机传一张照片到电脑，手机相册里就多出一张相同的照片。其他类型文件未测试。

**分析：** file_picker 选择照片时会先复制到应用缓存目录（`cache/file_picker/`），Android 媒体扫描器（MediaScanner）会索引缓存目录中的图片，导致相册出现重复。

**建议方案：**
- 在缓存目录中添加 `.nomedia` 文件，阻止 MediaScanner 索引
- 或在文件选择/上传完成后立即删除缓存副本
- 参考：`fastdrop-mobile/lib/core/utils/file_utils.dart`

**优先级：** 高（影响基本使用体验）

---

## 问题 2：手机不支持二次扫码 / 多电脑同时传输

**现象：** 手机配对一台电脑后，无法再扫码配对另一台电脑。电脑端同理。

**分析：** 当前设计为 1:1 配对模型（一个 session 绑定一台设备）。`SessionStore` 只存储一个 session，新配对会覆盖旧 session。

**用户需求：** 同时向多台电脑传文件。

**建议方案：**
- Phase 1 可先支持"切换配对"（断开当前连接 → 重新扫码）
- Phase 2+ 可设计多 session 管理：`SessionStore` 存储 `List<SessionData>`，设备列表页显示所有已配对设备，用户选择目标设备后传输
- 电脑端 Hub 已支持多 session 并发，架构上可行

**优先级：** 中（Phase 2 规划）

---

## 问题 3：电脑浏览器刷新后状态清空

**现象：** 刷新页面后，连接状态、传输历史全部丢失，需要重新扫码配对。

**分析：** Session 仅存储在 `api.ts` 的模块级变量 `cachedSession` 中，未持久化到 localStorage/sessionStorage。这是出于安全考虑（spec 要求 session token 不明文存储），但 UX 较差。

**建议方案：**
- 将 `sessionId` 存入 `sessionStorage`（标签页关闭即清除，安全性可接受）
- `accessToken` 也存入 `sessionStorage`，刷新页面后自动恢复连接
- 或存入 `localStorage` 并在页面加载时验证 session 有效性（调用 API 检查）
- 需要修改：`web/src/api.ts`、`web/src/App.vue`（onMounted 时尝试恢复 session）

**优先级：** 高（严重影响使用体验）

---

## 问题 4：电脑端为什么是网页而不是原生窗口？

**现象：** 电脑端是一个 exe 启动 HTTP 服务，然后通过浏览器访问网页。用户希望直接在 exe 窗口中操作。

**分析：** 当前架构是 Go 单二进制 + `//go:embed` 嵌入 Vue 构建产物。用户需手动打开浏览器访问 `http://127.0.0.1:9527`。

**可选方案：**

| 方案 | 优点 | 缺点 |
|------|------|------|
| **A. 自动打开浏览器**（最小改动） | 零额外依赖，exe 启动后自动调 `open` 打开默认浏览器 | 仍是浏览器标签页 |
| **B. 系统托盘 + 浏览器** | 托盘图标显示状态、快捷菜单；UI 仍用浏览器 | 需额外托盘库（如 systray） |
| **C. WebView 嵌入**（webview / wails） | 原生窗口，内嵌 WebView 渲染 Vue UI，无需浏览器 | 增加二进制体积 ~10-20MB；需引入 CGO 或 WebView2 |
| **D. Tauri / Electron** | 完整原生桌面体验 | 引入 Node.js 或 Rust 工具链，与 Go 后端架构冲突 |

**建议：** Phase 1 先做方案 A（启动时自动打开浏览器）+ 方案 B（系统托盘），成本最低。Phase 2 评估 Wails（Go 原生 WebView 框架），可将现有 Vue UI 直接嵌入原生窗口。

**优先级：** 中（体验优化，不影响功能）

---

## 问题 5：电脑之间、手机之间互传

**现象：** 当前仅支持 Android ↔ Windows。用户希望支持 PC↔PC、手机↔手机。

**分析：** 设计文档（spec）明确 Phase 1/2 范围为 Android ↔ Windows，明确排除 iOS、macOS、Linux。

**可行性分析：**
- **PC ↔ PC：** Go 后端已包含完整的 HTTP 文件服务 + WS 控制通道。理论上可以在第二台 PC 上运行同一个 exe，一台作为"服务端"，另一台作为"客户端"（需增加客户端模式）。改动量中等。
- **手机 ↔ 手机：** Flutter 端目前只有客户端逻辑。需增加"服务端模式"（在手机上运行 HTTP + WS 服务），技术上可行（Dart 有 `dart:io` HttpServer），但 Android 后台服务限制较多。改动量大。

**建议：** 作为 Phase 3+ 规划。当前架构的两通道设计（WS 控制 + HTTP 数据）天然支持扩展，不需要推翻重来。

**优先级：** 低（远期规划）

---

## 问题 6：上传/下载路径可配置

**现象：** 用户希望自定义文件接收路径（电脑端和手机端）。

**当前状态：**
- **电脑端：** 下载目录在 `config.json` 中配置（`storage.downloadDirectory`），默认为 `%USERPROFILE%\Downloads\FastDrop`。已支持配置，但无 UI 入口。
- **手机端：** 下载目录由 `FileUtils.movePartToFinal()` 决定，目前写入应用外部存储的 `Download/FastDrop/` 目录，不可配置。

**建议方案：**
- **电脑端：** 在 Web UI 的设置页面添加"下载目录"配置项，修改后写入 `config.json` 并热更新 Storage Manager
- **手机端：** 在设置页面添加"下载目录"选择器（使用 `file_picker` 的目录选择模式或 SAF），存储到 SharedPreferences

**优先级：** 中（实用功能）

---

## 问题 7：手机端上传失败后，电脑端任务永久卡在"传输中"且无法取消

> **修复状态（2026-09-25）**：✅ **全部修复**。① 桌面 UI 取消已接通 REST + 服务端清理（H3/M3/M8）；② 手机上传失败主动经 WS 上报 `transfer.failed`，PC 端放开 c2s 方向限制（保留属主校验），权威行正常置 failed 并清理；③ 启动清扫：遗留非终态传输统一置 failed(SERVER_RESTART) 并清临时目录；④ 60s 宽限结构性失效已修（H7）。

**记录日期：** 2026-09-25

**现象：** 手机向电脑发送 64 个文件，手机端上传失败；电脑端该批次一直显示"传输中"，点击取消无效，界面刷新或重启应用后仍是"传输中"。

**分析（故障链四步，均有代码位置）：**

1. **手机上传失败不通知 PC。** `transfer_service.dart:205-218` 捕获异常后只调 `onStateChange('failed')` 更新手机本地 UI，不发任何 WS/REST 给 PC。（对比下载方向：`multi_device_connection.dart:510-518` 下载失败会发 `transfer.failed`）
2. **就算发了 PC 也不收。** PC 的 `handleTransferFailed`（`websocket/router.go:89`）显式要求 `direction == server_to_client`，client_to_server（手机→PC）的失败上报直接回 "no outbound transfer for this session"；`handleTransferCompleted` 同样（`:56`）。手机→PC 方向的完成/失败上报链路是断的。
3. **PC 无停滞看门狗。** inbound 传输状态只在 chunk 到达时推进（`MarkChunkComplete`）；手机 App 存活时 WS 心跳由多设备连接池维持，PC 看不到断线，60 秒断线兜底 `OnGraceExpired`（`cmd/fastdrop/main.go:82`）永不触发 → DB 行永久停在 `transferring`。
4. **桌面 UI 的取消是空操作。** `DesktopApp.vue:358-360` 只向手机发 WS `transfer.cancel`（手机客户端不处理该命令类型）+ 本地乐观置"已取消"，从未调用 PC 自己的 `POST /api/v1/transfers/{id}/cancel`，DB 行不被更新，UI 刷新后从 DB 读回"传输中"。

**注：** 后端能力是齐的——`Manager.Cancel()`（`transfer/manager.go:242`）与 REST cancel（`api/handlers_transfer.go:275`）都能取消任意非终态传输，手机端取消上传时调的正是这个 REST 接口（`transfer_service.dart:353`）。问题只在桌面 UI 没有接它。

**临时处置：** 直接改 SQLite（`%APPDATA%\FastDrop\fastdrop.db`）后重启 FastDrop：

```sql
UPDATE transfers SET status='cancelled', error_code='user_cancelled'
WHERE status IN ('created','waiting_accept','preparing','transferring','paused','retrying');
```

并删除残留临时目录 `downloads\.fastdrop-temp\{transferId}\`。

**修复方案（4 点）：**

1. 桌面 UI 取消 inbound 传输改走本地 cancel：复用 `withLocalDesktop` 免认证模式加本地端点（或让 UI 持 session 调 REST）
2. PC `handleTransferFailed` / `handleTransferCompleted` 放开 client_to_server 方向
3. 手机上传失败/完成时主动向 PC 发 `transfer.failed` / `transfer.completed`
4. PC 启动时把非终态传输清扫为 failed（重启不留僵尸行）

**关联发现（断点续传现状）：** 分块级基础设施齐备（chunk 位图 + `.part` + `GET /chunks` + 60s 重连宽限），进程内断网可恢复、支持暂停/恢复；但**跨重启续传未打通**——PC 重启吊销全部 session（spec §7.1 有意设计）、手机上传从不查询已完成分块（`chunk_uploader.dart` 无 `GET /chunks` 调用）、PC 启动无清扫（即修复点 4）。断电后只能重新配对重传。

**优先级：** 高（用户可感知的卡死 + 双端状态不一致）

---

## 问题 8：上传传输中切后台，若"允许接收文件"关闭则传输因无保活而中断

> **修复状态（2026-09-25）**：✅ 已修复（`03af9a6`）。保活条件改为"server 在运行 **或** `TransferService.hasActiveTransfers`"，纯发送场景切后台同样获得前台保活；含计数器回归测试。

**记录日期：** 2026-09-25

**现象：** 传输进行中切换到其他应用时：接收开关（内嵌 server）开启的情况下，切后台会启动前台保活服务（`app.dart:53-58` → `FastDropKeepAliveService`），传输正常继续；但关闭接收开关后，上传任务没有任何保活，后台数分钟内被系统冻结（Android cached-app freezing），传输失败。

**分析：**
- 保活的唯一触发条件是 `fastdropServerProvider.isRunning`（`app.dart:56`），与"是否有传输任务进行中"无关
- 上传不依赖内嵌 server（手机此时是 HTTP 客户端），因此"关闭接收 + 纯发送"的使用场景完全失去后台保护
- 各厂商 ROM 对后台冻结/杀进程的策略不同（国产 ROM 普遍更激进），无保活时传输中断是 Android 通用问题，不限于特定品牌

**建议方案：** 保活触发条件改为"server 在运行 **或** 存在进行中的传输任务（上传/下载均算）"。需要在应用层维护活跃传输计数/标志供生命周期回调查询。改动小。

**优先级：** 中（默认配置不受影响；关闭接收开关的纯发送用户受影响）

---

## 问题 9：Android 后台可靠性弱，无自愈能力与电池优化引导（各厂商通用）

> **修复状态（2026-09-25）**：🟡 小改档已修复——电池优化白名单检测 + 设置页引导横幅 + 一键跳系统设置（通用适配各厂商，不做绕过）。⬜ 中改档（后台 FlutterEngine 自愈）仍为待办：需 Service 拉起后台 engine 在后台 isolate 重建 `FastDropServer` 并配合 `START_STICKY`，属架构级改动，作为独立里程碑排期。

> **修复状态（2026-09-25）**：⬜ 未修复（待办）。小改档（电池优化白名单检测+设置引导）与中改档（后台 engine 自愈）均需原生 channel 与设置页设计，作为独立里程碑排期。

**记录日期：** 2026-09-25

**分析：**
1. `FastDropKeepAliveService` 返回 `START_NOT_STICKY`（`FastDropKeepAliveService.kt:23`）——进程被系统杀死后服务不会重启
2. 直接改为 `START_STICKY` 会造成"假活"：服务重启后只是空壳通知，Dart 侧内嵌 server 住在主 Flutter isolate，engine 不会随 service 自动运行——通知在，但设备发现不了、传不了文件
3. 内嵌 server + mDNS 广播 + 传输全部依赖主 isolate 存活；用户从最近任务划掉（多数国产 ROM 默认杀进程）或深度休眠后可能全部中断
4. 没有电池优化/自启动状态的检测与引导。各厂商（华为/小米/OPPO/vivo/荣耀等）策略不同，通用做法是检测"电池优化白名单"（`PowerManager.isIgnoringBatteryOptimizations`）并引导用户前往系统设置，而不是为单一品牌做特殊处理

**建议方案（分档）：**
- **小改**：启动时检测电池优化白名单，未加白则设置页提示 + 一键跳系统设置；配合问题 8 的修复，覆盖绝大多数后台场景
- **中改（真后台自愈）**：Service `onCreate` 用 `FlutterEngineGroup` 拉起后台 engine，跑 `@pragma('vm:entry-point')` 后台入口，在后台 isolate 重建 `FastDropServer`（该类为纯 Dart、依赖构造注入，可脱离 UI 层运行），配合 `START_STICKY` 实现进程被杀后自动恢复接收
- **预期管理**：即便全部做完，"用户主动划掉后 100% 存活"在 Android 上没有干净方案，不应过度承诺

**优先级：** 中（影响后台接收体验；真后台自愈为远期增强）

---

## 问题 10：PC 端支持主动扫描发现附近设备（手机/其他电脑）

> **状态（2026-09-25）**：✅ **已实现**（`10944c1` + `33be9c8`）。Go `discovery/browser.go`：mDNS 查询 + /24 子网 `/health` 探测双路候选、健康身份验证去重；端点 `GET /api/v1/discovery/nearby`（withLocalDesktop）；Vue 添加设备弹窗"附近设备"面板自动扫描、点击即走既有配对。实测 6 秒内发现并验证局域网手机。注意：目标设备熄屏休眠时不可达属正常（Wi-Fi 省电），扫描前请亮屏对端——问题 9 的电池优化引导可缓解。

**记录日期：** 2026-09-25（用户需求）

**现状：** PC"添加设备"只有两条路：① 显示二维码让手机扫（被动）；② 手输 `IP:端口` → `GET /server/info` 验证 → `POST /pair/discover` 半自动配对（`DesktopApp.vue:456-499`）。**PC 自身不会扫描发现局域网内的 FastDrop 设备**——mDNS 浏览 + 子网 `/health` 探测那套只在 Flutter 端（`mdns_discovery.dart`）实现。

**可行性分析：**
- Go 已依赖 `github.com/hashicorp/mdns v1.0.7`，该库同时支持发布（现用）与查询浏览（`mdns.Query`/`Lookup`），加发现能力是现成 API
- 兜底策略手机端已验证：/24 子网并发探测 `GET /api/v1/health`（`mdns_discovery.dart:188-224`），可照搬
- 发现后的连接直接走现有 `POST /pair/discover` 半自动配对（对端确认），无需新协议
- 发现只读 `/health`、`/server/info`，二者本就在局域网暴露，无新增安全面；配对确认策略不变

**建议方案：**
1. Go：`internal/discovery/` 增加 browser（mdns.Query + 子网扫描兜底），新端点 `GET /api/v1/discovery/nearby` 挂 `withLocalDesktop`（仅本机 UI 可用）
2. Vue：添加设备弹窗（`DesktopApp.vue:873`）增加"附近设备"列表区块，点击即走现有配对流程
3. 参照手机端策略：mDNS 为主、子网扫描兜底、deviceId 去重

**优先级：** 中（多设备易用性）

---

## 问题 11：全端深度审查发现清单（2026-09-25，4 路并行代码审查去重汇总）

> **修复状态（2026-09-25，两批更新）**：46 条中 **44 条已修复**（问题 7 收尾、M20 IP 自愈、L15 打开文件入口均已落地，提交 `10944c1`/`33be9c8` 及后续）。**延期 2 条**：M1+M19（接收确认服务端强制 + 开关覆盖面，协议级行为变更需先定设计）、L14 手机端 429 排队（与 Go 阻塞语义二选一）。已验证无恙清单不变。

> 审查方式：Go 后端 / Flutter 手机端 / Vue 桌面 UI / 跨端场景推演 四路独立审查，全部逐条读码核实（file:line 证据），已去除跨路重复。共 46 条独立发现：高 10 / 中 20 / 低 16。详细证据链见当次审查记录，此处保留精简索引。

### 高（数据损坏 / 安全 / 功能不可用）

| # | 端 | 问题 | 关键证据 | 修复方向 |
|---|---|---|---|---|
| H1 | Vue | PC 发送大文件必然 OOM：`sha256File` 用 `file.arrayBuffer()` 全量进内存 | `usePeerPool.ts:619-624`（Dart/Go 侧均流式，仅 PC 坑） | 增量哈希（分块 update）或 Wails Bridge 交给 Go 算 |
| H2 | Vue | PC 接收方向同病：`downloadFileBlob` 无 Range 整文件 blob() 进内存 | `api.ts:265-272` | Range 分块流式落盘 |
| H3 | Vue+Go | 手机→PC 传入文件默认配置下，PC 自动 `acceptOffer` 会把**预分配全零 .part** 整文件下载成"损坏副本"（`/content` 回退 .part、Content-Length=全尺寸），双份保存一份必坏 | `DesktopApp.vue:290-294`、`usePeerPool.ts:450-458`、`storage/manager.go:114-117`、`handlers_transfer.go:640-671` | acceptOffer 按 peer.role 分流：local-session 只发 accept 信令；remote-server 流式下载经 DesktopBridge 落盘 |
| H4 | Go | `GET /api/v1/pair/qr` 未认证：局域网任意设备零交互拿配对 token+会话（QR 安全模型被绕过） | `router.go:90`、`handlers_pair.go:251/279` | 包 `withLocalDesktop` + 纳入配对限流 |
| H5 | Go | `SetChunkBit` 位图读改写竞态：同文件 3 并发分块完成互相覆盖 → complete 永久 "not all chunks received" | `db.go:507-528`（5fe0599 同族残留） | 单条原子 SQL（bitmap OR）或按 fileID 锁 |
| H6 | Go | 重名 check-then-rename 竞态：并发完成的重名文件被 MoveFileEx 静默覆盖，违反 never-overwrite | `manager.go:176/185`、`filename.go:104-121` | finalize 全局互斥或 rename 后校验回退 |
| H7 | Go+Vue | 60s 宽限结构性失效：桌面 UI 与手机共享同一 session WS → `lastClient` 永不成立 → `OnGraceExpired` 永不触发，手机杀 App 后传输永远卡住（#7 的深层根因之一） | `hub.go:139-156/213-227`、`DesktopApp.vue:405-428` | 宽限按非本地客户端/设备粒度判定 |
| H8 | Flutter | 接收端把整个 transfer 置 verifying：校验期间同批其他文件分块全被 409（不可重试）→ 整批失败 | `transfer_receiver.dart:481-482/367-370`、`chunk_uploader.dart:69-78` | verifying 降为文件级；chunk 只拒 terminal（对齐 Go） |
| H9 | Flutter | `movePartToFinal` 跨卷 rename 失败：自定义保存目录（SD 卡/公共目录）100% 传完即失败且删 .part，进度清零 | `file_utils.dart:202`、`transfer_service.dart:313-318` | EXDEV/权限 fallback 流式 copy+delete |
| H10 | Flutter | 下载方向无重试无续传：单个 Range 失败即删 .part 从 0 重来（§15 退避只有上传侧实现） | `transfer_service.dart:263/273-276/313-318` | 复用 5 次退避 + 按偏移续写，失败不删 .part |

### 中

| # | 端 | 问题 | 关键证据 |
|---|---|---|---|
| M1 | Go | "接收需确认"服务端不生效：非终态即收块，拒绝追不上上传（开关纯装饰） | `handlers_transfer.go:356-359` |
| M2 | Go | WS file.offer 路径缺 §18 磁盘预检，几十 GB 后才 500 且残留半盘 .part | `router.go:143-147` |
| M3 | Go | REST 取消/哈希失败/宽限过期均不清 .part → `.fastdrop-temp` 无限膨胀（与 WS cancel 不一致） | `handlers_transfer.go:275-294`、`main.go:87-97` |
| M4 | Go | complete 阶段：哈希失败永久卡 verifying；并发完成可把 completed 覆盖回 transferring | `handlers_transfer.go:483-495`、`manager.go:219-238`、`db.go:286-290` |
| M5 | Go | clientIP 信任 X-Forwarded-For → 唯一限流闸门可整体绕过 | `router.go:256-268` |
| M6 | Go | 文件名无长度钳制：超长名传完却在 finalize 必败（MAX_PATH） | `filename.go:25-54` |
| M7 | Vue | staging 发送无接受等待/超时：手机离线时永远"等待接收" | `usePeerPool.ts:382-383` |
| M8 | Vue | sendFile 无失败终态（永远"传输中"）、取消停不住本地管线（接口无 cancel） | `usePeerPool.ts:356-388/116-131` |
| M9 | Vue | accept/reject 只带 offerId 非 transferId：并发多个传入任务命中错误传输 | `DesktopApp.vue:286`、`router.go:186-196/215` |
| M10 | Vue | `useWebSocket.close()` 关不掉：人为关闭仍自动重连 → 同 session 僵尸双连接 | `useWebSocket.ts:152-159/121-128` |
| M11 | Vue | 断连 60s 永久放弃重连；authFailed 死卡片不可移除且默认被选中 | `useWebSocket.ts:134-138`、`usePeerPool.ts:231-240` |
| M12 | Vue | "已向 N 台设备发起发送"虚报：离线设备被静默跳过 | `DesktopApp.vue:236` |
| M13 | Flutter | 批量上传无文件级隔离（一个失败中止后续全部）；已完成文件被整批改标 failed；哈希串行预计算不可取消无反馈 | `transfer_service.dart:120-134/405-422`、`transfer_screen.dart:283-291` |
| M14 | Flutter | 文件选择器私有拷贝同名同毫秒冲突 → 静默丢文件（用户以为发了 N 个实发 N-1） | `file_picker_screen.dart:396-398/288-292` |
| M15 | Flutter | cancelDownload 停不住本地下载循环（无 CancelToken），取消后可能仍 100% 落盘 | `transfer_service.dart:341-378` |
| M16 | Flutter | TransferHistoryStore 写入链一断全断；启动时标记失败可阻断内嵌 server 自启（开关显示开但服务没跑） | `transfer_history_store.dart:35-48`、`server_providers.dart:86` |
| M17 | Flutter | 发送端等确认 2 分钟超时 vs 接收端对话框永不过时 → 僵尸传输 + 满尺寸 .part 残留 | `multi_device_connection.dart:582`、`receive_confirm_dialog.dart:57-60` |
| M18 | 跨端 | 手机存储不足预检只覆盖直传路径；主路径（PC 暂存+Range 下载）全程无检查 | `transfer_receiver.dart:307-320` 对照 `transfer_service.dart:246-325` |
| M19 | 跨端 | 两端"接收确认"开关都管不到最常用路径（手机开关不覆盖 offer 路径；PC 开关不覆盖 c2s） | `server_providers.dart:168-175`、`DesktopApp.vue:290-295` |
| M20 | 跨端 | IP 变化后无自愈：altHosts 仅配对时探测，自动重连仍拨旧地址需手动重配对 | `pairing_screen.dart:119-143`、`multi_device_connection.dart:315-321` |

### 低

| # | 端 | 问题 |
|---|---|---|
| L1 | Go | 多处直接 UPDATE 绕过状态机（retry/accept 非法迁移）`handlers_transfer.go:310`、`router.go:199-202` |
| L2 | Go | `Range: bytes=0-0` 被误当开放区间返回整文件 `handlers_transfer.go:681-683` |
| L3 | Go | `config.Save` 非原子写：写入瞬间断电 → config.json 损坏 → 服务永远起不来 `config.go:169` |
| L4 | Go | 附注：hub 心跳 unregister 通道 cap=16 可自锁；PUT settings 数据竞争；chunk 先读后限 4MB×N；重复 PUT 双计进度 |
| L5 | Flutter | ws_server `transfer.cancel` 无属主校验且广播所有会话（可取消别人会话的传输）`ws_server.dart:155-161` |
| L6 | Flutter | `_fileSems` 清理竞态可击穿"每文件 3 并发"限制 `transfer_receiver.dart:410-448` |
| L7 | Flutter | 全局 30s HTTP 超时：慢链路（<140KB/s）4MB 分块必然超时 → 5 连超时整批失败 `http_client.dart:49` |
| L8 | Flutter | 内嵌 server 内存态永不回收，accepted pair request 长期持有明文 accessToken `transfer_receiver.dart:153`、`pairing_handler.dart:230-234` |
| L9 | Vue | 每次连接状态翻转触发 loadHistory 风暴（REST + 500 行 JSON 序列化）`usePeerPool.ts:155-159/505` |
| L10 | Vue | 接收页 "Unknown Device" 英文直出中文 UI `usePeerPool.ts:490` |
| L11 | Vue | 不可达主机的原始英文错误直出（Failed to fetch）`api.ts:282-299` |
| L12 | Vue | 服务宕机时 QR 每秒重试风暴；activeTransfers 只增不删 `DesktopApp.vue:192-195/262-273` |
| L13 | 跨端 | 会话过期/吊销的失败只报通用 TRANSFER_FAILED，失败卡片无"重新配对"入口 `transfer_service.dart:210-217` |
| L14 | 跨端 | 双向同传挤兑 6 槽调度器（Vue chunk PUT 无超时 + 60s WriteTimeout 假重试）；手机 server 第 3 文件 429 拒绝而非排队 `api.ts:193-201`、`transfer_receiver.dart:403-406` |
| L15 | 跨端 | 手机端无"打开文件"入口（无 ACTION_VIEW，历史不存落盘路径）；PC 端 RevealTransfer 有兜底，两端不对等 |
| L16 | 跨端 | 注记：同机重复配对在 PC 侧累积多个有效 session 直至 TTL/重启 `hub.go:229-260` |

### 已验证无恙（免重复排查）

0 字节文件两端全链路、同名重发 rename(1)（接收方负责）、中文/空格/CON.zip/无扩展名清洗、Dart/Go 流式 SHA-256、调度器槽位 defer 释放、token 哈希存储与 QR 60s/单次/5 次失效、日志脱敏（token/QR 原文未打印）、上传 6 次尝试+5 档退避合规、双向两列进度互不干扰、PC RevealTransfer 移动文件兜底、场景 3 重配对闭环入口。

**建议修复顺序：** P0 = H4（安全）→ H5/H6（数据损坏）→ H1/H2/H3（大文件与副本损坏）→ H7（与 #7 同补丁）→ H8/H9/H10；P1 = M 系按端分组修；P2 = L 系随手清理。

## 问题 12：传输记录页面（HistoryScreen）无任何入口，用户无法查看历史

> **发现日期**：2026-09-25（用户反馈"手机传输记录里没有刚发的照片"）
>
> **现状**：记录实际已写入本地历史库（SharedPreferences `fastdrop.transfer_history.v1`，含落盘路径），但 `HistoryScreen`（`/history`）在全 App 中没有任何导航指向；底部「传输」标签（TransferScreen）只展示内存中的进行中批次，传输完成即消失、重启即清空——用户感知为"记录丢了"。
>
> **修复**：传输页 AppBar 增加「传输记录」入口按钮（`transfer_screen.dart`）。另发现：默认落盘路径为应用私有目录（`/data/user/0/.../app_flutter/FastDrop/`），相册不可见，仅能经历史页"打开文件"查看——是否改为公共目录（相册可见）待产品决策（关联问题 1 的 .nomedia 逻辑）。
>
> **优先级**：中（入口缺失，已修）

---

## 总结优先级

| 优先级 | 问题 | 工作量 |
|--------|------|--------|
| 🔴 高 | #1 相册重复照片 | 小（加 .nomedia） |
| 🔴 高 | #3 刷新页面状态丢失 | 中（sessionStorage 持久化） |
| 🔴 高 | #7 上传失败后 PC 端卡"传输中"无法取消 | 部分修复（断线自动失败+取消已通；③④待办） |
| 🔴 高 | #11 深度审查清单（46 条：41 已修 / 5 延期，详见问题 11） | 已修 P0+P1，延期项见清单 |
| 🟡 中 | #8 传输中切后台无保活（接收开关关闭时） | ✅ 已修复（03af9a6） |
| 🟡 中 | #9 Android 后台可靠性与电池优化引导 | 小 → 大（分档） |
| 🟡 中 | #10 PC 端扫描发现附近设备 | 中 |
| 🟡 中 | #6 下载路径可配置 | 中 |
| 🟡 中 | #4 原生窗口 / 自动打开浏览器 | 小（方案A）→ 中（方案C） |
| 🟡 中 | #2 多设备配对 | 大（多 session 架构） |
| 🟢 低 | #5 PC↔PC / 手机↔手机 | 大（Phase 3+） |
