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

## 总结优先级

| 优先级 | 问题 | 工作量 |
|--------|------|--------|
| 🔴 高 | #1 相册重复照片 | 小（加 .nomedia） |
| 🔴 高 | #3 刷新页面状态丢失 | 中（sessionStorage 持久化） |
| 🟡 中 | #6 下载路径可配置 | 中 |
| 🟡 中 | #4 原生窗口 / 自动打开浏览器 | 小（方案A）→ 中（方案C） |
| 🟡 中 | #2 多设备配对 | 大（多 session 架构） |
| 🟢 低 | #5 PC↔PC / 手机↔手机 | 大（Phase 3+） |
