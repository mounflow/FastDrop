import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'package:fastdrop_mobile/core/app_info.dart';

import 'device_discovery.dart';

/// Discovers FastDrop peers over mDNS and verifies every result against the
/// peer's public health endpoint before exposing it to the UI.
///
/// Android NSD implementations may report a service name without resolving
/// its host, and DNS proxy "fake-ip" modes can synthesize 198.18.0.0/15
/// addresses for those names. Service names and TXT data are therefore hints
/// only; the health response is the source of truth for peer identity.
class MdnsDiscovery implements DeviceDiscovery {
  MdnsDiscovery();

  static const String _serviceType = '_fastdrop._tcp';
  static const int _defaultPort = 9527;
  static const Duration _probeTimeout = Duration(milliseconds: 800);
  static const Duration _subnetScanCooldown = Duration(seconds: 5);
  static const Duration _staleAfter = Duration(seconds: 60);

  BonsoirDiscovery? _bonsoir;
  BonsoirBroadcast? _broadcast;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  StreamController<List<DiscoveredDevice>>? _controller;
  Timer? _staleTimer;
  Timer? _revalidateTimer;
  HttpClient? _httpClient;

  final Map<String, DiscoveredDevice> _byDeviceId = {};
  final Map<String, DateTime> _lastSeen = {};
  final Map<String, String> _serviceToDeviceId = {};

  bool _broadcasting = false;
  bool _subnetScanInProgress = false;
  bool _revalidationInProgress = false;
  DateTime? _lastSubnetScan;
  String? _localDeviceId;

  @override
  bool get isRunning => _bonsoir != null;

  HttpClient get _client {
    return _httpClient ??= HttpClient()
      ..connectionTimeout = _probeTimeout
      ..idleTimeout = const Duration(seconds: 2);
  }

  @override
  Stream<List<DiscoveredDevice>> start() {
    if (_controller != null) return _controller!.stream;

    _controller = StreamController<List<DiscoveredDevice>>.broadcast(
      onListen: _startScan,
      onCancel: _stopScan,
    );
    return _controller!.stream;
  }

  void _startScan() {
    if (_bonsoir != null) return;

    debugPrint('[mDNS] 开始扫描 $_serviceType ...');
    _emit();
    _staleTimer ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => _removeStaleDevices(),
    );
    _revalidateTimer ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(_revalidateKnownDevices()),
    );

    // Run the verified LAN fallback independently of Android NSD readiness.
    // Some devices never complete Bonsoir's ready/start sequence even though
    // direct LAN HTTP is available.
    _scheduleSubnetScan(force: true);

    _bonsoir = BonsoirDiscovery(type: _serviceType);
    _bonsoir!.ready.then((_) async {
      if (_bonsoir == null) return;
      debugPrint('[mDNS] ready，启动发现...');
      await _bonsoir!.start();
      _sub = _bonsoir!.eventStream?.listen(_handleEvent);
      // Some Android/Windows combinations drop the mDNS announcement
      // entirely, so no "found" or "resolve failed" event is emitted.
      // Always run one verified LAN scan at startup as a deterministic
      // fallback. Only peers whose FastDrop health identity validates are
      // exposed to the UI.
      _scheduleSubnetScan();
    }).catchError((Object error) {
      debugPrint('[mDNS] 启动失败: $error');
    });
  }

  Future<void> _stopScan() async {
    _staleTimer?.cancel();
    _staleTimer = null;
    _revalidateTimer?.cancel();
    _revalidateTimer = null;
    await _sub?.cancel();
    _sub = null;
    await _bonsoir?.stop();
    _bonsoir = null;
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  /// Force a fresh verified LAN probe when the user opens the device picker.
  Future<void> refresh() async {
    if (_controller == null) start();
    await _subnetScan(force: true);
  }

  void _handleEvent(BonsoirDiscoveryEvent event) {
    final service = event.service;
    debugPrint('[mDNS] 事件: ${event.type} | 服务: ${service?.name} | '
        'host: ${service is ResolvedBonsoirService ? service.host : "N/A"}');

    switch (event.type) {
      case BonsoirDiscoveryEventType.discoveryServiceResolved:
        if (service != null) unawaited(_verifyResolvedService(service));
        break;
      case BonsoirDiscoveryEventType.discoveryServiceFound:
        if (service == null) return;
        final serviceName = service.name;
        Future.delayed(const Duration(seconds: 2), () {
          if (_bonsoir == null) return;
          if (!_serviceToDeviceId.containsKey(serviceName)) {
            debugPrint('[mDNS] 2s 未验证，启动身份校验扫描: $serviceName');
            _scheduleSubnetScan();
          }
        });
        break;
      case BonsoirDiscoveryEventType.discoveryServiceResolveFailed:
        debugPrint('[mDNS] 解析失败: ${service?.name}，启动身份校验扫描');
        _scheduleSubnetScan();
        break;
      case BonsoirDiscoveryEventType.discoveryServiceLost:
        if (service != null) _removeService(service.name);
        break;
      case BonsoirDiscoveryEventType.discoveryStarted:
      case BonsoirDiscoveryEventType.discoveryStopped:
      case BonsoirDiscoveryEventType.unknown:
        break;
    }
  }

  Future<void> _verifyResolvedService(BonsoirService service) async {
    if (service is! ResolvedBonsoirService) {
      _scheduleSubnetScan();
      return;
    }
    final host = (service.host ?? '').trim();
    final port = service.port > 0 ? service.port : _defaultPort;
    if (!isUsableLANIPv4(host)) {
      debugPrint('[mDNS] 丢弃非局域网或 Fake-IP 地址: $host');
      _scheduleSubnetScan();
      return;
    }

    final device = await _probeHealth(host, port);
    if (device == null) {
      debugPrint('[mDNS] 身份验证失败: $host:$port');
      _scheduleSubnetScan();
      return;
    }
    _addVerifiedDevice(device, serviceName: service.name);
  }

  void _scheduleSubnetScan({bool force = false}) {
    if (_subnetScanInProgress) return;
    final now = DateTime.now();
    if (!force &&
        _lastSubnetScan != null &&
        now.difference(_lastSubnetScan!) < _subnetScanCooldown) {
      return;
    }
    unawaited(_subnetScan(force: force));
  }

  Future<void> _subnetScan({bool force = false}) async {
    if (_subnetScanInProgress) return;
    final now = DateTime.now();
    if (!force &&
        _lastSubnetScan != null &&
        now.difference(_lastSubnetScan!) < _subnetScanCooldown) {
      return;
    }
    _subnetScanInProgress = true;
    _lastSubnetScan = now;
    try {
      final localIP = await _findLocalLANIPv4();
      if (localIP == null) {
        debugPrint('[mDNS] 身份校验扫描: 无可用局域网 IPv4');
        return;
      }
      final parts = localIP.split('.');
      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
      debugPrint('[mDNS] 身份校验扫描: $subnet.0/24 端口 $_defaultPort');

      const batchSize = 32;
      for (var first = 1; first <= 254; first += batchSize) {
        final probes = <Future<void>>[];
        final last = (first + batchSize - 1).clamp(1, 254);
        for (var suffix = first; suffix <= last; suffix++) {
          final ip = '$subnet.$suffix';
          if (ip == localIP) continue;
          probes.add(_probeAndAdd(ip, _defaultPort));
        }
        await Future.wait(probes);
      }
    } catch (error) {
      debugPrint('[mDNS] 身份校验扫描异常: $error');
    } finally {
      _subnetScanInProgress = false;
    }
  }

  Future<String?> _findLocalLANIPv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      if (!name.contains('wlan') && !name.contains('wifi') && name != 'en0') {
        continue;
      }
      for (final address in interface.addresses) {
        if (isUsableLANIPv4(address.address)) return address.address;
      }
    }
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (isUsableLANIPv4(address.address)) return address.address;
      }
    }
    return null;
  }

  Future<void> _probeAndAdd(String ip, int port) async {
    final device = await _probeHealth(ip, port);
    if (device != null) _addVerifiedDevice(device);
  }

  Future<DiscoveredDevice?> _probeHealth(String ip, int port) async {
    if (!isUsableLANIPv4(ip)) return null;
    try {
      final health = await _getJson(ip, port, '/api/v1/health');
      if (health == null || health['status'] != 'ok') return null;

      var identity = Map<String, dynamic>.from(health);
      if ((identity['deviceId']?.toString().trim().isEmpty ?? true) ||
          ((identity['deviceName'] ?? identity['name'])
                  ?.toString()
                  .trim()
                  .isEmpty ??
              true)) {
        final info = await _getJson(ip, port, '/api/v1/server/info');
        if (info != null) identity.addAll(info);
      }
      return deviceFromVerifiedIdentity(
        identity,
        ip: ip,
        port: port,
        localDeviceId: _localDeviceId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getJson(
    String ip,
    int port,
    String path,
  ) async {
    final request = await _client
        .getUrl(Uri(scheme: 'http', host: ip, port: port, path: path))
        .timeout(_probeTimeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(_probeTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final body =
        await response.transform(utf8.decoder).join().timeout(_probeTimeout);
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  void _addVerifiedDevice(
    DiscoveredDevice device, {
    String? serviceName,
  }) {
    if (device.deviceId == _localDeviceId) return;

    final duplicateIDs = _byDeviceId.entries
        .where((entry) =>
            entry.key != device.deviceId &&
            entry.value.baseUrl == device.baseUrl)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final duplicateID in duplicateIDs) {
      _byDeviceId.remove(duplicateID);
      _lastSeen.remove(duplicateID);
      _serviceToDeviceId.removeWhere((_, id) => id == duplicateID);
    }

    _byDeviceId[device.deviceId] = device;
    _lastSeen[device.deviceId] = DateTime.now();
    if (serviceName != null) {
      _serviceToDeviceId[serviceName] = device.deviceId;
    }
    _emit();
  }

  void _removeService(String serviceName) {
    final deviceID = _serviceToDeviceId.remove(serviceName);
    if (deviceID == null || _serviceToDeviceId.containsValue(deviceID)) return;
    _byDeviceId.remove(deviceID);
    _lastSeen.remove(deviceID);
    _emit();
  }

  Future<void> _revalidateKnownDevices() async {
    if (_revalidationInProgress || _byDeviceId.isEmpty) return;
    _revalidationInProgress = true;
    try {
      final current = _byDeviceId.values.toList(growable: false);
      await Future.wait(current.map((device) async {
        final uri = Uri.tryParse(device.baseUrl);
        if (uri == null || uri.host.isEmpty) return;
        final refreshed =
            await _probeHealth(uri.host, uri.hasPort ? uri.port : _defaultPort);
        if (refreshed != null) _addVerifiedDevice(refreshed);
      }));
    } finally {
      _revalidationInProgress = false;
    }
  }

  void _removeStaleDevices() {
    final cutoff = DateTime.now().subtract(_staleAfter);
    final staleIDs = _lastSeen.entries
        .where((entry) => entry.value.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList(growable: false);
    if (staleIDs.isEmpty) return;
    for (final id in staleIDs) {
      _lastSeen.remove(id);
      _byDeviceId.remove(id);
      _serviceToDeviceId.removeWhere((_, deviceID) => deviceID == id);
    }
    _emit();
  }

  void _emit() {
    if (_controller == null || _controller!.isClosed) return;
    final devices = _byDeviceId.values.toList(growable: false)
      ..sort((a, b) {
        final byName = a.deviceName.compareTo(b.deviceName);
        return byName != 0 ? byName : a.baseUrl.compareTo(b.baseUrl);
      });
    _controller!.add(devices);
  }

  @override
  Future<void> stop() async {
    await stopBroadcast();
    await _stopScan();
    await _controller?.close();
    _controller = null;
    _byDeviceId.clear();
    _lastSeen.clear();
    _serviceToDeviceId.clear();
  }

  Future<void> startBroadcast({
    required String deviceId,
    required String deviceName,
    required String platform,
    int port = _defaultPort,
  }) async {
    if (_broadcasting) return;
    _localDeviceId = deviceId;
    _byDeviceId.remove(deviceId);
    _lastSeen.remove(deviceId);

    final instanceName = broadcastInstanceName(deviceName, deviceId);
    debugPrint('[mDNS] Starting broadcast: $instanceName on port $port');
    _broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: instanceName,
        type: _serviceType,
        port: port,
        attributes: {
          'id': deviceId,
          'name': deviceName,
          'version': fastDropAppVersion,
          'protocol': '1',
          'platform': platform,
          'pairing': 'required',
          'tls': '0',
        },
      ),
    );
    await _broadcast!.ready;
    await _broadcast!.start();
    _broadcasting = true;
    debugPrint('[mDNS] Broadcast started');
  }

  Future<void> stopBroadcast() async {
    if (!_broadcasting) return;
    await _broadcast?.stop();
    _broadcast = null;
    _broadcasting = false;
    debugPrint('[mDNS] Broadcast stopped');
  }

  bool get isBroadcasting => _broadcasting;

  @visibleForTesting
  static bool isUsableLANIPv4(String address) {
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null || parsed.type != InternetAddressType.IPv4) return false;
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    if (a == 198 && (b == 18 || b == 19)) return false;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  @visibleForTesting
  static String broadcastInstanceName(String deviceName, String deviceId) {
    final cleanName =
        deviceName.trim().isEmpty ? 'FastDrop' : deviceName.trim();
    final cleanID = deviceId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final suffix = cleanID.length <= 6 ? cleanID : cleanID.substring(0, 6);
    if (suffix.isNotEmpty &&
        cleanName.toLowerCase().endsWith('-${suffix.toLowerCase()}')) {
      return cleanName;
    }
    final maxNameLength = 50 - suffix.length;
    final base = cleanName.length <= maxNameLength
        ? cleanName
        : cleanName.substring(0, maxNameLength);
    return suffix.isEmpty ? base : '$base-$suffix';
  }

  @visibleForTesting
  static DiscoveredDevice? deviceFromVerifiedIdentity(
    Map<String, dynamic> payload, {
    required String ip,
    required int port,
    String? localDeviceId,
  }) {
    if (!isUsableLANIPv4(ip)) return null;
    final deviceID = payload['deviceId']?.toString().trim() ?? '';
    final deviceName =
        (payload['deviceName'] ?? payload['name'])?.toString().trim() ?? '';
    final platform = payload['platform']?.toString().trim() ?? '';
    final protocolValue = payload['protocol'];
    final protocol = protocolValue is int
        ? protocolValue
        : int.tryParse(protocolValue?.toString() ?? '');
    if (deviceID.isEmpty ||
        deviceName.isEmpty ||
        platform.isEmpty ||
        protocol != 1 ||
        deviceID == localDeviceId) {
      return null;
    }
    return DiscoveredDevice(
      deviceId: deviceID,
      deviceName: deviceName,
      baseUrl: 'http://$ip:$port',
      protocolVersion: protocol!,
      platform: platform,
      pairingRequired: true,
    );
  }
}
