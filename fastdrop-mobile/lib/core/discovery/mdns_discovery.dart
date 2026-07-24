import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'device_discovery.dart';

/// mDNS-based device discovery. Listens for `_fastdrop._tcp` services
/// broadcast by FastDrop PC instances on the LAN and converts them to
/// [DiscoveredDevice] objects.
///
/// Spec §30.2 mandates that TXT records carry id/name/version/protocol
/// /platform/pairing/tls. Token / sessionId / paths MUST NEVER appear
/// in TXT records.
class MdnsDiscovery implements DeviceDiscovery {
  MdnsDiscovery();

  static const String _serviceType = '_fastdrop._tcp';

  BonsoirDiscovery? _bonsoir;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  StreamController<List<DiscoveredDevice>>? _controller;

  final Map<String, DiscoveredDevice> _byDeviceId = {};

  @override
  bool get isRunning => _bonsoir != null;

  @override
  Stream<List<DiscoveredDevice>> start() {
    if (_controller != null) {
      // Already started — give the caller the existing stream.
      return _controller!.stream;
    }
    _controller = StreamController<List<DiscoveredDevice>>.broadcast(
      onListen: _startScan,
      onCancel: _stopScan,
    );
    // Emit an initial empty list so subscribers can render the
    // "scanning…" state without waiting for the first discovery.
    _controller!.add(const []);
    return _controller!.stream;
  }

  void _startScan() {
    debugPrint('[mDNS] 开始扫描 $_serviceType ...');
    _bonsoir = BonsoirDiscovery(type: _serviceType);
    _bonsoir!.ready.then((_) async {
      debugPrint('[mDNS] ready，启动发现...');
      await _bonsoir!.start();
      debugPrint('[mDNS] 发现已启动，eventStream=${_bonsoir!.eventStream != null}');
      _sub = _bonsoir!.eventStream?.listen(_handleEvent);
    });
  }

  Future<void> _stopScan() async {
    await _sub?.cancel();
    _sub = null;
    await _bonsoir?.stop();
    _bonsoir = null;
  }

  void _handleEvent(BonsoirDiscoveryEvent event) {
    final service = event.service;
    debugPrint('[mDNS] 事件: ${event.type} | 服务: ${service?.name} | '
        'host: ${service is ResolvedBonsoirService ? service.host : "N/A"}');

    switch (event.type) {
      case BonsoirDiscoveryEventType.discoveryServiceResolved:
        // Only the *resolved* event carries the host IP we need to
        // build a base URL. discoveryServiceFound fires first but
        // the service at that point is the unresolved form.
        if (service == null) return;
        final device = _parseService(service);
        if (device != null) {
          _byDeviceId[device.deviceId] = device;
          _emit();
        }
        break;
      case BonsoirDiscoveryEventType.discoveryServiceLost:
        if (service == null) return;
        // TXT records may not be present on the "lost" event, so use
        // service.name as the lookup key.
        final staleKeys = _byDeviceId.entries
            .where((e) =>
                e.value.deviceName == service.name ||
                e.value.deviceId == service.name)
            .map((e) => e.key)
            .toList();
        for (final key in staleKeys) {
          _byDeviceId.remove(key);
        }
        _emit();
        break;
      case BonsoirDiscoveryEventType.discoveryServiceResolveFailed:
        // NSD 解析失败（MIUI 常见）——降级用 DNS 查询。
        debugPrint('[mDNS] 解析失败: ${service?.name}，尝试 DNS 降级');
        if (service != null) _fallbackResolve(service);
        break;
      case BonsoirDiscoveryEventType.discoveryServiceFound:
        // MIUI 的 NSD 经常卡在 Found 不往 Resolved 走。
        // 等 2 秒，如果还没 Resolved 就用 DNS 降级。
        if (service != null) {
          final name = service.name;
          Future.delayed(const Duration(seconds: 2), () {
            final alreadyResolved = _byDeviceId.values.any(
              (d) => d.deviceName == name,
            );
            if (!alreadyResolved) {
              debugPrint('[mDNS] 2s 未 Resolved，DNS 降级: $name');
              _fallbackResolve(service);
            }
          });
        }
        break;
      case BonsoirDiscoveryEventType.discoveryStarted:
      case BonsoirDiscoveryEventType.discoveryStopped:
      case BonsoirDiscoveryEventType.unknown:
        break;
    }
  }

  /// MIUI NSD 解析降级：
  /// 1. 先尝试 DNS 查询（不带 .local，路由器可能解析 NetBIOS 名）
  /// 2. 再尝试 .local 后缀
  /// 3. 都失败则扫描子网 9527 端口
  void _fallbackResolve(BonsoirService service) {
    final name = service.name.replaceAll(' ', '-');
    // Found 事件的 port 是 0（未解析），用默认端口 9527。
    final port = (service.port != null && service.port! > 0)
        ? service.port!
        : 9527;
    debugPrint('[mDNS] 降级解析: $name (port=$port)');

    // 依次尝试的 hostname 列表
    final candidates = [name, '$name.local'];

    Future<void> tryNext(int i) async {
      if (i >= candidates.length) {
        debugPrint('[mDNS] DNS 全部失败，尝试子网扫描');
        _subnetScan(service.name, port);
        return;
      }
      debugPrint('[mDNS] 尝试 DNS: ${candidates[i]}');
      try {
        final addresses = await InternetAddress.lookup(candidates[i]);
        final ipv4 =
            addresses.where((a) => a.type == InternetAddressType.IPv4);
        if (ipv4.isNotEmpty) {
          final ip = ipv4.first.address;
          debugPrint('[mDNS] DNS 成功: $ip:$port');
          _addFallbackDevice(service.name, ip, port);
          return;
        }
      } catch (e) {
        debugPrint('[mDNS] DNS 失败: ${candidates[i]} → $e');
      }
      tryNext(i + 1);
    }

    tryNext(0);
  }

  /// 扫描本机所在子网的 9527 端口，找到 FastDrop 服务器。
  void _subnetScan(String deviceName, int port) async {
    try {
      // 获取本机 IP
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isEmpty) {
        debugPrint('[mDNS] 子网扫描: 无网络接口');
        return;
      }
      final myIp = interfaces.first.addresses.first.address;
      final parts = myIp.split('.');
      if (parts.length != 4) return;
      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
      debugPrint('[mDNS] 子网扫描: $subnet.0/24 端口 $port');

      // 并发扫描所有 IP（超时 500ms）
      final futures = <Future<void>>[];
      for (int i = 1; i <= 254; i++) {
        final ip = '$subnet.$i';
        if (ip == myIp) continue;
        futures.add(_probePort(ip, port, deviceName));
      }
      await Future.wait(futures);
    } catch (e) {
      debugPrint('[mDNS] 子网扫描异常: $e');
    }
  }

  /// 尝试 TCP 连接 ip:port，成功则认为是 FastDrop 服务器。
  Future<void> _probePort(String ip, int port, String deviceName) async {
    try {
      final socket = await Socket.connect(ip, port,
          timeout: const Duration(milliseconds: 500));
      socket.destroy();
      debugPrint('[mDNS] 子网扫描命中: $ip:$port');
      _addFallbackDevice(deviceName, ip, port);
    } catch (_) {
      // 连接失败——不是 FastDrop 服务器
    }
  }

  void _addFallbackDevice(String name, String ip, int port) {
    final device = DiscoveredDevice(
      deviceId: name,
      deviceName: name,
      baseUrl: 'http://$ip:$port',
      protocolVersion: 1,
      platform: 'unknown',
      pairingRequired: true,
    );
    _byDeviceId[device.deviceId] = device;
    _emit();
  }

  DiscoveredDevice? _parseService(BonsoirService service) {
    final txt = <String, String>{};
    // bonsoir 5.x exposes TXT records as Map<String, String> on
    // BonsoirService.attributes — keys are lowercased by the plugin.
    service.attributes?.forEach((k, v) {
      txt[k.toLowerCase()] = v;
    });

    final deviceId = txt['id'] ?? service.name;
    final port = service.port ?? 9527;

    // Only ResolvedBonsoirService exposes `host`. The service at
    // this point has already gone through the resolved event.
    String host = '';
    if (service is ResolvedBonsoirService) {
      host = (service.host ?? '').trim();
    }
    if (host.isEmpty) return null;

    return DiscoveredDevice(
      deviceId: deviceId,
      deviceName: txt['name'] ?? service.name,
      baseUrl: 'http://$host:$port',
      protocolVersion: int.tryParse(txt['protocol'] ?? '1') ?? 1,
      platform: txt['platform'] ?? 'unknown',
      pairingRequired: (txt['pairing'] ?? 'required') != 'none',
      tls: (txt['tls'] ?? '0') == '1',
    );
  }

  void _emit() {
    if (_controller != null && !_controller!.isClosed) {
      _controller!.add(_byDeviceId.values.toList(growable: false));
    }
  }

  @override
  Future<void> stop() async {
    await _stopScan();
    await _controller?.close();
    _controller = null;
    _byDeviceId.clear();
  }
}
