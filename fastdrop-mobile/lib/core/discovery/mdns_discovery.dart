import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

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
    _bonsoir = BonsoirDiscovery(type: _serviceType);
    _bonsoir!.ready.then((_) {
      _bonsoir!.start();
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
        // Log and ignore — the user can retry by re-opening the
        // discovery sheet.
        break;
      case BonsoirDiscoveryEventType.discoveryStarted:
      case BonsoirDiscoveryEventType.discoveryServiceFound:
      case BonsoirDiscoveryEventType.discoveryStopped:
      case BonsoirDiscoveryEventType.unknown:
        // Informational only — no action needed.
        break;
    }
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
