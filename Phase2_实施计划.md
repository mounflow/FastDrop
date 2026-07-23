# FastDrop Phase 2 实施计划

> 局域网设备发现（mDNS）+ 手动 IP fallback + 配对流程改造

## 决策汇总

| # | 决策 | 备注 |
|---|------|------|
| 1 | PC + 手机都加 mDNS 开关按钮 | settings 面板里 |
| 2 | 用 `bonsoir` 插件 | 比 `multicast_dns` 可靠（原生 NSD 绕开 WiFi 锁定） |
| 3 | 先做 D-3（已配对自动重连），再做 D-2（未配对半自动） | D-3 最实用 |
| 4 | 手机入口：单按钮，第一次"开启 mDNS + 扫码"，第二次"直接扫码" | 见阶段 3 wireframe |

## 关键概念

**mDNS 插件 ≠ 配对**。`multicast_dns` 和 `bonsoir` 都只做"**发现 PC 在哪**"，不做配对。
配对永远是 HTTP/WS 层（现有代码）。插件选择只影响"发现"环节的可靠性。

---

## 阶段 1：服务端开关 + 广播验证（~半天）

| # | 文件 | 改动 |
|---|------|------|
| 1.1 | `fastdrop-desktop/internal/config/config.go` | 保留 `MdnsEnabled` 字段；默认 `false`（安全默认） |
| 1.2 | `fastdrop-desktop/internal/api/handlers_settings.go`（新建或扩展） | `GET/PUT /api/v1/settings` 支持读写 `discovery.mdnsEnabled` |
| 1.3 | `fastdrop-desktop/web/src/App.vue` | Settings 面板加 toggle：「局域网设备发现 (mDNS)」 |
| 1.4 | `fastdrop-desktop/cmd/fastdrop/main.go` | 启动时按 settings 决定用 `NoopPublisher` / `MdnsPublisher`；运行时切换需要重启 publisher（先做重启生效，热切换放后面） |
| 1.5 | 启动日志增强 | 广播时打印 `[discovery] visible as DESKTOP-XXX._fastdrop._tcp.local. on 192.168.1.19:9527` |

**验证**：开启开关 → 用 Android 的 "Service Browser" app 或 PC 的 "Bonjour Browser" 能看到 `_fastdrop._tcp.local.` 列表里出现 PC。

---

## 阶段 2：手机端 mDNS 框架（~1 天）

| # | 文件 | 改动 |
|---|------|------|
| 2.1 | `fastdrop-mobile/pubspec.yaml` | 加 `bonsoir: ^5.x` |
| 2.2 | `fastdrop-mobile/android/app/src/main/AndroidManifest.xml` | 加 `<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />` + `<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />` + `<uses-permission android:name="android.permission.INTERNET" />` |
| 2.3 | `fastdrop-mobile/lib/core/discovery/device_discovery.dart`（新建） | 定义 `abstract class DeviceDiscovery { Stream<DiscoveredDevice> start(); Future<void> stop(); }` 接口（spec §30 Dart 镜像） |
| 2.4 | `lib/core/discovery/mdns_discovery.dart`（新建） | `class MdnsDiscovery implements DeviceDiscovery`，封装 bonsoir |
| 2.5 | `lib/core/discovery/qr_discovery.dart`（新建） | `class QrDiscovery` —— 把现在的扫码逻辑包一层，统一接口 |
| 2.6 | `lib/core/discovery/manual_discovery.dart`（新建） | `class ManualDiscovery` —— 手输 IP 占位实现 |
| 2.7 | 单元测试 | 用 mock 验证接口契约 |

**验证**：写个临时 debug 页面，启动 `MdnsDiscovery` → 列出发现到的 PC。

---

## 阶段 3：手机端 UI（~1 天）

| # | 文件 | 改动 |
|---|------|------|
| 3.1 | `lib/features/devices/devices_screen.dart` | AppBar 加一个图标按钮（单按钮入口） |
| 3.2 | 同上 | 当 mDNS 关闭：点击按钮 → 弹确认"开启局域网发现？" → 同意 → 启动 `MdnsDiscovery` + 进 QR 扫码页 |
| 3.3 | 同上 | 当 mDNS 开启：点击按钮 → 直接进 QR 扫码页 |
| 3.4 | `lib/features/devices/nearby_devices_sheet.dart`（新建） | BottomSheet 列附近设备：每行 🖥 设备名 / IP / `protocol v1` / 状态（已配对✓ / 待配对） |
| 3.5 | `lib/features/settings/settings_screen.dart` | 加 mDNS 开关 toggle |

### 按钮行为 Wireframe

```
[+ 添加设备] ← AppBar 右上角按钮
   ├─ mDNS 关闭：
   │    弹窗"开启局域网发现？"
   │    [取消]  [开启并扫码]
   │         ↓
   │    启动 MdnsDiscovery + 进 QR 扫码页
   │
   └─ mDNS 开启：
        直接进 QR 扫码页（同时后台 mDNS 在跑）
        扫码页底部多一个区块"附近设备"（可选源）
```

---

## 阶段 4：D-3 已配对自动重连（~半天）

| # | 文件 | 改动 |
|---|------|------|
| 4.1 | `lib/core/storage/session_store.dart` | `DeviceStore` 加 `findDeviceByDeviceId(String deviceId)` 方法（mDNS TXT 里的 `id` 字段比对） |
| 4.2 | `lib/features/devices/devices_screen.dart` | mDNS 发现设备时 → 查 `DeviceStore` → 已配对 → 直接 `switchToDevice` 跳过 QR |
| 4.3 | 同上 | 旧 session 失效（401）→ 自动降级走 D-2（半自动配对） |

**验证**：
1. 配对 PC A → App 重启 → mDNS 发现 A → 自动用旧 session 连上 → ✓ 不用扫码
2. 服务端重启清 session → mDNS 发现 A → 自动重连失败 → 弹"是否重新配对？" → 走 D-2

---

## 阶段 5：D-2 未配对半自动（~1.5 天，需要新 API）

| # | 文件 | 改动 |
|---|------|------|
| 5.1 | `fastdrop-desktop/internal/pairing/manager.go` | 加 `RequestDirect(deviceID, deviceName, platform)` 方法 —— 不需要 QR token，直接创建 pair request |
| 5.2 | `fastdrop-desktop/internal/api/handlers_pair.go` | 新端点 `POST /api/v1/pair/discover` body: `{baseUrl, deviceId, deviceName}` |
| 5.3 | `fastdrop-desktop/web/src/App.vue` | 接受 pair 请求的弹窗现在已有，复用即可（mDNS 触发的 pair 和 QR 触发的 pair 在 PC 看起来一样） |
| 5.4 | `fastdrop-mobile/lib/features/pairing/pairing_screen.dart` | 加 `PairingMode.mdns` 路径：点附近设备 → POST `/pair/discover` → 轮询 `/pair/requests/{id}` → 拿 session |
| 5.5 | 安全审查 | `pair/discover` 要 rate-limit（pairing manager 现在已有 pairLimiter），TXT 记录里**不广播 token**（spec §30.2） |

**验证**：
1. 没配过的 PC → 手机 mDNS 看到 → 点击 → PC 弹"是否允许 iPhone-X 配对？" → 接受 → 手机自动拿到 session
2. 异常：PC 拒绝、超时、并发请求

---

## 阶段 6：Settings 手动 IP fallback（~半天）

| # | 文件 | 改动 |
|---|------|------|
| 6.1 | `lib/features/settings/settings_screen.dart` | 手动 IP 输入框 wire 起来（现在是 placeholder） |
| 6.2 | `lib/core/discovery/manual_discovery.dart` | 实现：输入 IP:port → 返回单元素 `DiscoveredDevice` 流 |
| 6.3 | 走 D-2 的 `pair/discover` 流程 | |

---

## 阶段 7：测试 + 收尾（~半天）

| # | 任务 |
|---|------|
| 7.1 | 端到端场景：新设备首次发现 → 半自动配对 → 重启 App → 自动重连 |
| 7.2 | 多 PC 场景：办公室有 3 台 PC 都跑 FastDrop，手机都能看到 |
| 7.3 | 网络异常：手机切 WiFi、PC 网卡变更、防火墙拦截 5353 |
| 7.4 | spec 一致性检查：TXT 字段、无 token、protocol 版本协商 |
| 7.5 | 更新 CLAUDE.md 把 Phase 2 项标完成 |

---

## 总工作量估计

| 阶段 | 工时 |
|------|------|
| 1 服务端开关 | 半天 |
| 2 手机端框架 | 1 天 |
| 3 手机端 UI | 1 天 |
| 4 D-3 自动重连 | 半天 |
| 5 D-2 半自动配对 | 1.5 天 |
| 6 手动 IP | 半天 |
| 7 测试 | 半天 |
| **合计** | **~5 天** |

---

## 推进原则

- 每阶段做完**停下来让用户验证**，不连续做完
- 每阶段独立提交 git commit
- 阶段间可以暂停，下次接着做
- 阶段 5（D-2）涉及新 API，需要额外的安全审查
