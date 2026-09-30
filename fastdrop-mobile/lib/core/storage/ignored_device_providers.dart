import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/storage/ignored_device_store.dart';

/// 忽略名单（用户明确删除过的设备）的内存缓存。
///
/// 供配对处理器**同步**判定：被删除过的设备不静默接受配对。名单变动
/// （删除设备 / 用户主动重新配对）后立即刷新缓存与持久层。
final ignoredDevicesProvider =
    StateNotifierProvider<IgnoredDevicesNotifier, List<IgnoredDeviceEntry>>(
  (ref) => IgnoredDevicesNotifier(),
);

class IgnoredDevicesNotifier extends StateNotifier<List<IgnoredDeviceEntry>> {
  IgnoredDevicesNotifier() : super(const []) {
    unawaited(refresh());
  }

  final IgnoredDeviceStore _store = IgnoredDeviceStore();

  Future<void> refresh() async {
    state = await _store.load();
  }

  /// 用户删除设备 → 加入忽略名单。
  Future<void> add({required String deviceId, required String name}) async {
    await _store.add(deviceId: deviceId, name: name);
    await refresh();
  }

  /// 用户主动重新配对 → 移除忽略标记。
  Future<void> remove({required String deviceId, String? name}) async {
    await _store.remove(deviceId: deviceId, name: name);
    await refresh();
  }

  bool isIgnored(String deviceId, String deviceName) => state.any(
        (entry) =>
            entry.deviceId == deviceId || entry.name == deviceName,
      );
}
