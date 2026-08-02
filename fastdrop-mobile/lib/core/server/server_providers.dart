import 'dart:io';

import 'package:fastdrop_mobile/core/discovery/discovery_providers.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/core/server/fastdrop_server.dart';
import 'package:fastdrop_mobile/core/server/pairing_providers.dart';
import 'package:fastdrop_mobile/core/server/transfer_providers.dart';
import 'package:fastdrop_mobile/shared/models/device_info.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Server lifecycle state.
enum ServerStatus { idle, starting, running, stopping, error }

class ServerState {
  const ServerState({
    this.status = ServerStatus.idle,
    this.port = 9527,
    this.deviceName = '',
    this.errorMessage,
  });

  final ServerStatus status;
  final int port;
  final String deviceName;
  final String? errorMessage;

  bool get isRunning => status == ServerStatus.running;

  ServerState copyWith({
    ServerStatus? status,
    int? port,
    String? deviceName,
    String? errorMessage,
  }) {
    return ServerState(
      status: status ?? this.status,
      port: port ?? this.port,
      deviceName: deviceName ?? this.deviceName,
      errorMessage: errorMessage,
    );
  }
}

/// Manages the embedded FastDrop server lifecycle.
///
/// Coordinates server start/stop, wires callbacks to Riverpod providers
/// for pairing and transfer confirmations, and handles the "allow receive"
/// setting.
class FastDropServerNotifier extends StateNotifier<ServerState> {
  FastDropServerNotifier(this.ref) : super(const ServerState()) {
    _loadEnabled();
  }

  final Ref ref;
  FastDropServer? _server;

  static const _enabledKey = 'fastdrop.server_enabled';
  bool _enabled = true;

  bool get isEnabled => _enabled;

  Future<void> _loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? true;
    if (_enabled) {
      start();
    }
  }

  /// Toggle the "allow receive" setting.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);

    if (value) {
      start();
    } else {
      stop();
    }
  }

  /// Start the embedded server.
  Future<void> start() async {
    if (state.isRunning || state.status == ServerStatus.starting) return;
    if (!_enabled) return;

    state = state.copyWith(status: ServerStatus.starting);

    try {
      final deviceId = await DeviceIdManager.getDeviceId();
      final deviceName = await _getDeviceName();

      final localDevice = DeviceInfo(
        deviceId: deviceId,
        deviceName: deviceName,
        platform: _getPlatform(),
        appVersion: '1.0.0',
      );

      final server = FastDropServer(
        localDevice: localDevice,
        onPairRequest: (request) {
          debugPrint('[Server] Pair request from ${request.device.deviceName}');
          ref.read(pendingPairRequestsProvider.notifier).addRequest(request);
        },
        onTransferRequest: (transfer) {
          debugPrint('[Server] Transfer offer: ${transfer.transferId}');
          ref.read(incomingTransfersProvider.notifier).addTransfer(transfer);
        },
      );

      await server.start();
      _server = server;

      // Start mDNS broadcast so other devices can discover us.
      try {
        final discovery = ref.read(mdnsDiscoveryProvider);
        await discovery.startBroadcast(
          deviceId: deviceId,
          deviceName: deviceName,
          platform: _getPlatform(),
        );
      } catch (e) {
        debugPrint('[Server] mDNS broadcast failed (non-fatal): $e');
      }

      state = state.copyWith(
        status: ServerStatus.running,
        deviceName: deviceName,
        port: server.port,
      );

      debugPrint('[Server] Running on port ${server.port}');
    } catch (e) {
      debugPrint('[Server] Failed to start: $e');
      state = state.copyWith(
        status: ServerStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Stop the embedded server.
  Future<void> stop() async {
    if (_server == null) return;

    state = state.copyWith(status: ServerStatus.stopping);

    // Stop mDNS broadcast.
    try {
      await ref.read(mdnsDiscoveryProvider).stopBroadcast();
    } catch (_) {}

    await _server!.stop();
    _server = null;

    // Clear pending UI state.
    ref.read(pendingPairRequestsProvider.notifier).clear();
    ref.read(incomingTransfersProvider.notifier).clear();
    ref.read(activeServerTransfersProvider.notifier).clear();

    state = const ServerState();
  }

  /// Accept a pending pair request.
  void acceptPairRequest(String requestId) {
    _server?.pairingHandler.acceptRequest(requestId);
    ref.read(pendingPairRequestsProvider.notifier).removeRequest(requestId);
  }

  /// Reject a pending pair request.
  void rejectPairRequest(String requestId) {
    _server?.pairingHandler.rejectRequest(requestId);
    ref.read(pendingPairRequestsProvider.notifier).removeRequest(requestId);
  }

  /// Accept an incoming transfer.
  Future<void> acceptTransfer(String transferId) async {
    final transfer = _server?.transferReceiver.getTransfer(transferId);
    if (transfer == null) return;

    await _server!.transferReceiver.acceptTransfer(transferId);
    ref.read(incomingTransfersProvider.notifier).removeTransfer(transferId);
    ref.read(activeServerTransfersProvider.notifier).addTransfer(transfer);

    _server?.wsServer.notifyTransferResolution(transferId, 'accepted');
  }

  /// Reject an incoming transfer.
  void rejectTransfer(String transferId) {
    _server?.transferReceiver.rejectTransfer(transferId);
    ref.read(incomingTransfersProvider.notifier).removeTransfer(transferId);
    _server?.wsServer.notifyTransferResolution(transferId, 'rejected');
  }

  /// Ensure the server is running (called on app resume).
  Future<void> ensureRunning() async {
    if (_enabled && !state.isRunning && state.status != ServerStatus.starting) {
      await start();
    }
  }

  /// Access the underlying server (for QR generation, etc.).
  FastDropServer? get server => _server;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _getPlatform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  static Future<String> _getDeviceName() async {
    // On Android, Platform.localHostname returns "localhost" which is useless.
    // Read the device model from /system/build.prop (readable by apps).
    if (Platform.isAndroid) {
      try {
        final buildProp = File('/system/build.prop');
        if (buildProp.existsSync()) {
          final lines = await buildProp.readAsLines();
          for (final line in lines) {
            if (line.startsWith('ro.product.model=')) {
              final model = line.substring('ro.product.model='.length).trim();
              if (model.isNotEmpty) return model;
            }
          }
        }
      } catch (_) {}
    }
    try {
      final hostname = Platform.localHostname;
      if (hostname.isNotEmpty && hostname != 'localhost') return hostname;
    } catch (_) {}
    return 'FastDrop Device';
  }

  @override
  void dispose() {
    _server?.stop();
    super.dispose();
  }
}

/// Main provider for the embedded server lifecycle.
final fastdropServerProvider =
    StateNotifierProvider<FastDropServerNotifier, ServerState>(
  (ref) => FastDropServerNotifier(ref),
);
