# FastDrop 手机首页持续加载修复设计

**日期：** 2026-09-23

**状态：** 已确认

## 1. 问题与根因

Android 首页在 `DevicesScreen.initState()` 中同步调用 `_loadDevices()`。该方法立即执行 `ref.invalidate(localNetworkInfoProvider)`，在 `ConsumerState` 尚未完成初始化时访问 Riverpod 的 `ProviderScope`，触发未处理异常。后续设备读取和 `_loading = false` 均未执行，因此页面永久显示加载动画。

## 2. 方案选择

考虑三种方案：

1. **首帧后加载（采用）**：在 `initState()` 中注册 post-frame callback，再调用 `_loadDevices()`。保留原有网络信息刷新行为，改动最小。
2. **`didChangeDependencies` 一次性加载**：生命周期合法，但需要额外布尔标记防止重复执行，复杂度略高。
3. **删除 `ref.invalidate`**：可以避开当前异常，但会改变首页刷新本机网络信息的既有行为。

## 3. 行为设计

- 首页首帧正常渲染后再读取 Riverpod provider 和本地设备列表。
- 加载成功时保持现有设备列表、连接和扫描逻辑不变。
- 加载异常时必须结束加载状态，显示明确的失败提示和重试入口；不得永久显示加载动画。
- 页面卸载后不再更新状态或继续执行连接动作。

## 4. 测试与验收

- Widget 回归测试先复现旧实现的 Riverpod 生命周期异常和持续加载。
- 修复后验证首页首次加载能够退出加载状态。
- 验证设备存储读取失败时显示失败状态，并可点击重试。
- 运行 Flutter 相关测试与静态分析。
- 构建 Android debug APK，覆盖安装到当前连接手机。
- 清空并重新抓取手机日志，确认不再出现 `dependOnInheritedWidgetOfExactType<UncontrolledProviderScope>()` 异常，且首页不再持续加载。

## 5. 非目标

- 不调整 mDNS、扫码、配对或多设备连接协议。
- 不修改桌面端服务。
- 不重构 `DevicesScreen` 的其他 UI 或业务逻辑。
