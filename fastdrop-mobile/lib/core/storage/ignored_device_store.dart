import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用户明确删除过的设备条目。
class IgnoredDeviceEntry {
  const IgnoredDeviceEntry({
    required this.deviceId,
    required this.name,
    required this.ignoredAt,
  });

  final String deviceId;
  final String name;
  final DateTime ignoredAt;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'ignoredAt': ignoredAt.toIso8601String(),
      };

  static IgnoredDeviceEntry fromJson(Map<String, dynamic> json) =>
      IgnoredDeviceEntry(
        deviceId: json['deviceId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        ignoredAt: DateTime.tryParse(json['ignoredAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// 用户明确删除过的设备名单（"忽略名单"）。
///
/// 语义——**用户主动执行的结果必须符合其意愿**：删除设备 = 双向断开 +
/// 清除配对记录（设备条目与会话凭证）+ **不自动恢复**。因此：
/// - 自动反向配对（建立双向通道）会跳过本名单中的设备，不会"删了又回来"；
/// - 对端再次主动连接时也不静默接受，需用户显式确认；
/// - 用户**主动**重新配对（扫码／附近设备点击／确认弹窗允许）会将该设备
///   从名单移除，因此这不是永久黑名单。
///
/// 注意：本名单只影响"配对凭证"，与传输记录（[TransferHistoryStore]）
/// 完全无关——删除设备永不触碰传输记录。
class IgnoredDeviceStore {
  static const _key = 'fastdrop.ignored_devices.v1';

  Future<List<IgnoredDeviceEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => IgnoredDeviceEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // 忽略名单损坏时不能静默清空——否则被删除的设备会「悄悄复活」。
      debugPrint('[IgnoredDeviceStore] 忽略名单解析失败，按空列表继续: $e');
      return [];
    }
  }

  /// 将设备加入忽略名单（用户删除设备时调用）。
  Future<void> add({required String deviceId, required String name}) async {
    final entries = await load();
    entries.removeWhere(
      (e) => e.deviceId == deviceId || (name.isNotEmpty && e.name == name),
    );
    entries.add(IgnoredDeviceEntry(
      deviceId: deviceId,
      name: name,
      ignoredAt: DateTime.now(),
    ));
    await _write(entries);
  }

  /// 用户主动重新配对时移除忽略标记。
  Future<void> remove({required String deviceId, String? name}) async {
    final entries = await load();
    final before = entries.length;
    entries.removeWhere(
      (e) =>
          (deviceId.isNotEmpty && e.deviceId == deviceId) ||
          (name != null && name.isNotEmpty && e.name == name),
    );
    if (entries.length != before) await _write(entries);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<void> _write(List<IgnoredDeviceEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}
