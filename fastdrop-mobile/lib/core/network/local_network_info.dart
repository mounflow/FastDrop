import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class LocalNetworkInfo {
  const LocalNetworkInfo({
    required this.type,
    required this.localAddresses,
    this.name,
    this.permissionRequired = false,
  });

  final String type;
  final String? name;
  final List<String> localAddresses;
  final bool permissionRequired;

  String get typeLabel => switch (type) {
        'wifi' => 'Wi-Fi',
        'ethernet' => '有线网络',
        'cellular' => '蜂窝网络',
        'vpn' => 'VPN',
        'offline' => '网络未连接',
        _ => '局域网',
      };

  String get displayLabel {
    final network = name?.isNotEmpty == true ? name! : typeLabel;
    final address =
        localAddresses.isEmpty ? '' : ' · ${localAddresses.join(' / ')}';
    final permission = permissionRequired ? ' · 点击显示名称' : '';
    return '$network$address$permission';
  }

  factory LocalNetworkInfo.fromMap(Map<Object?, Object?> map) {
    return LocalNetworkInfo(
      type: map['type'] as String? ?? 'offline',
      name: map['name'] as String?,
      localAddresses: (map['localAddresses'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      permissionRequired: map['permissionRequired'] as bool? ?? false,
    );
  }
}

class LocalNetworkInfoService {
  static const _channel = MethodChannel('fastdrop/network_info');

  Future<LocalNetworkInfo> getCurrent() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'getCurrentNetwork',
    );
    return LocalNetworkInfo.fromMap(result ?? const {});
  }

  Future<LocalNetworkInfo> requestWifiNamePermission() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'requestWifiNamePermission',
    );
    return LocalNetworkInfo.fromMap(result ?? const {});
  }
}

final localNetworkInfoServiceProvider = Provider<LocalNetworkInfoService>(
  (_) => LocalNetworkInfoService(),
);

final localNetworkInfoProvider = FutureProvider<LocalNetworkInfo>((ref) {
  return ref.read(localNetworkInfoServiceProvider).getCurrent();
});
