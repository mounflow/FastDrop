import 'dart:async';

import 'package:flutter/foundation.dart';

/// Discovered FastDrop peer (PC) on the LAN.
///
/// Mirrors the Go side `discovery.DiscoveredDevice`. Populated from
/// mDNS TXT records (Phase 2) or from a manually entered IP:port.
@immutable
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.deviceId,
    required this.deviceName,
    required this.baseUrl,
    required this.protocolVersion,
    required this.platform,
    required this.pairingRequired,
    this.tls = false,
  });

  /// Stable device identifier (from mDNS TXT `id=`). Matches the
  /// DeviceStore entry's `id` field, so a re-discovered previously
  /// paired PC can be auto-reconnected without re-scanning.
  final String deviceId;

  /// Human-readable name shown in the device list (e.g. "DESKTOP-PC").
  final String deviceName;

  /// Base URL for HTTP/WS traffic, e.g. `http://192.168.1.19:9527`.
  final String baseUrl;

  final int protocolVersion;
  final String platform;

  /// From mDNS TXT `pairing=required|optional|none`. When `required`
  /// the phone must go through pair flow (QR or D-2 discover) before
  /// it can use this device.
  final bool pairingRequired;

  /// From mDNS TXT `tls=0|1`. Phase 1/2 always 0 (LAN only, cleartext).
  final bool tls;

  @override
  String toString() =>
      'DiscoveredDevice($deviceName @ $baseUrl, id=$deviceId, proto=$protocolVersion)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DiscoveredDevice && other.deviceId == deviceId);

  @override
  int get hashCode => deviceId.hashCode;
}

/// Abstract device-discovery API. Spec §30 mandates this be an
/// interface so Phase 1's QR-only flow, Phase 2's mDNS, and the
/// manual-IP fallback can all plug in uniformly.
abstract class DeviceDiscovery {
  /// Start discovering. Emits the current set of discovered devices
  /// whenever it changes. The stream stays open until [stop] is
  /// called; callers are responsible for cancelling their
  /// subscription.
  ///
  /// Implementations should emit an initial empty list immediately
  /// so subscribers can render the "scanning…" state.
  Stream<List<DiscoveredDevice>> start();

  /// Tear down any native resources (NSD browser, multicast socket).
  /// After this returns, [start] may be called again.
  Future<void> stop();

  /// Whether this source is currently active.
  bool get isRunning;
}
