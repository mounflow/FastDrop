import 'dart:async';

import 'device_discovery.dart';

/// QR-scanning-based device discovery. Wraps the existing QR scan +
/// pair-poll flow (which currently lives in PairingScreen) so that
/// all three Phase-2 discovery sources share the same [DeviceDiscovery]
/// interface.
///
/// NOTE: This implementation emits a SINGLE device and then completes
/// the stream — QR scanning is inherently one-shot per scan, unlike
/// mDNS which continuously streams updates. Callers should resubscribe
/// (or call [start] again) when the user wants to scan another QR.
class QrDiscovery implements DeviceDiscovery {
  QrDiscovery();

  Completer<DiscoveredDevice>? _scanCompleter;
  bool _running = false;

  @override
  bool get isRunning => _running;

  /// Starts a one-shot scan. The returned stream emits a single
  /// element (the scanned device) and then closes.
  ///
  /// The actual QR-decoding + pair-poll logic stays in
  /// `PairingScreen` for now — Phase 2 stage 4 will refactor it to
  /// drive this class. For now this is a scaffold.
  @override
  Stream<List<DiscoveredDevice>> start() {
    _running = true;
    _scanCompleter = Completer<DiscoveredDevice>();
    final controller = StreamController<List<DiscoveredDevice>>();
    controller.onListen = () async {
      controller.add(const []);
      // Real implementation will await QR scan + polling here.
      // For now: never emit, callers must integrate manually.
    };
    controller.onCancel = () {
      _running = false;
    };
    return controller.stream;
  }

  /// Phase 2 stage 4 will call this from PairingScreen once the QR
  /// is decoded and the pair request is accepted.
  void deliverScannedDevice(DiscoveredDevice device) {
    if (_scanCompleter?.isCompleted == false) {
      _scanCompleter!.complete(device);
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _scanCompleter = null;
  }
}
