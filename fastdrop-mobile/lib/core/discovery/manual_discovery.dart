import 'dart:async';

import 'device_discovery.dart';

/// Manual IP-based device discovery. The user types a host:port
/// (or just an IP) into Settings → "Manual Connection"; this
/// implementation wraps that input as a single-element discovery
/// stream so the rest of the pairing pipeline (Stage 5: D-2
/// `POST /api/v1/pair/discover`) can treat it uniformly with the
/// mDNS path.
///
/// Phase 2 stage 6 will wire this up to the Settings UI input box
/// that currently sits as a placeholder.
class ManualDiscovery implements DeviceDiscovery {
  ManualDiscovery({required this.hostPortInput});

  /// User-typed "host:port" or just "host" (port defaults to 9527).
  /// Setting this triggers a re-emit on the active stream.
  String hostPortInput;

  StreamController<List<DiscoveredDevice>>? _controller;
  bool _running = false;

  @override
  bool get isRunning => _running;

  @override
  Stream<List<DiscoveredDevice>> start() {
    _running = true;
    _controller = StreamController<List<DiscoveredDevice>>.broadcast(
      onListen: _emit,
    );
    return _controller!.stream;
  }

  /// Update the user input and re-emit. No-op if not running.
  void update(String input) {
    hostPortInput = input;
    if (_running) _emit();
  }

  void _emit() {
    final parsed = _parse(hostPortInput);
    if (parsed == null) {
      _controller?.add(const []);
      return;
    }
    _controller!.add([
      DiscoveredDevice(
        // No device ID available until we connect — use the baseUrl
        // as a placeholder so the rest of the pipeline has a stable key.
        deviceId: parsed,
        deviceName: parsed,
        baseUrl: parsed,
        protocolVersion: 1,
        platform: 'unknown',
        pairingRequired: true,
      ),
    ]);
  }

  /// Parse user input into a base URL. Accepts:
  ///   "192.168.1.19"           → "http://192.168.1.19:9527"
  ///   "192.168.1.19:9527"       → "http://192.168.1.19:9527"
  ///   "http://192.168.1.19:9527" → unchanged
  static String? _parse(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.contains(':')) return 'http://$s';
    return 'http://$s:9527';
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _controller?.close();
    _controller = null;
  }
}
