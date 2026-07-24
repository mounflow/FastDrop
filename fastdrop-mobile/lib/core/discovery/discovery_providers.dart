import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_discovery.dart';
import 'mdns_discovery.dart';

// ---------------------------------------------------------------------------
// mDNS 开关（持久化）
// ---------------------------------------------------------------------------

/// 控制 mDNS 局域网发现功能的开关状态。
/// 持久化到 SharedPreferences，App 重启后保持。
class MdnsEnabledNotifier extends StateNotifier<bool> {
  MdnsEnabledNotifier() : super(false) {
    _load();
  }

  static const _key = 'fastdrop.mdns_enabled';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? false;
  }

  /// 切换开关并持久化。
  Future<void> setEnabled(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final mdnsEnabledProvider =
    StateNotifierProvider<MdnsEnabledNotifier, bool>((ref) {
  return MdnsEnabledNotifier();
});

// ---------------------------------------------------------------------------
// MdnsDiscovery 单例
// ---------------------------------------------------------------------------

/// 全局唯一的 [MdnsDiscovery] 实例。
/// 由 [nearbyDevicesProvider] 驱动 start/stop。
final mdnsDiscoveryProvider = Provider<MdnsDiscovery>((ref) {
  return MdnsDiscovery();
});

// ---------------------------------------------------------------------------
// 附近设备流
// ---------------------------------------------------------------------------

/// 当 mDNS 开启时，返回持续更新的附近 FastDrop PC 列表。
/// 关闭时返回空列表。
final nearbyDevicesProvider =
    StateNotifierProvider<NearbyDevicesNotifier, List<DiscoveredDevice>>((ref) {
  return NearbyDevicesNotifier(ref);
});

/// 管理 mDNS 发现的生命周期：
/// - 监听 [mdnsEnabledProvider]，开启时 start，关闭时 stop
/// - 把 [MdnsDiscovery] 的流转换为同步可读的 state
class NearbyDevicesNotifier extends StateNotifier<List<DiscoveredDevice>> {
  NearbyDevicesNotifier(this._ref) : super([]) {
    // 监听开关变化
    _ref.listen<bool>(mdnsEnabledProvider, (_, enabled) {
      if (enabled) {
        _startDiscovery();
      } else {
        _stopDiscovery();
      }
    });
    // 初始状态：如果已经开启就立即启动
    if (_ref.read(mdnsEnabledProvider)) {
      _startDiscovery();
    }
  }

  final Ref _ref;
  StreamSubscription<List<DiscoveredDevice>>? _sub;

  void _startDiscovery() {
    _sub?.cancel();
    final discovery = _ref.read(mdnsDiscoveryProvider);
    final stream = discovery.start();
    _sub = stream.listen(
      (devices) {
        if (mounted) state = devices;
      },
      onError: (_) {
        // bonsoir 内部错误——清空列表，用户可以重试
        if (mounted) state = [];
      },
    );
  }

  Future<void> _stopDiscovery() async {
    await _sub?.cancel();
    _sub = null;
    await _ref.read(mdnsDiscoveryProvider).stop();
    if (mounted) state = [];
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
