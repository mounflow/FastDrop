import 'dart:io';
import 'dart:async';

import 'package:fastdrop_mobile/core/discovery/discovery_providers.dart';
import 'package:fastdrop_mobile/core/app_info.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/core/platform/background_receive_service.dart';
import 'package:fastdrop_mobile/core/server/fastdrop_server.dart';
import 'package:fastdrop_mobile/core/server/pairing_providers.dart';
import 'package:fastdrop_mobile/core/server/transfer_providers.dart';
import 'package:fastdrop_mobile/core/storage/transfer_history_store.dart';
import 'package:fastdrop_mobile/shared/models/device_info.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
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
    this.requirePairConfirmation = false,
    this.requireReceiveConfirmation = false,
    this.errorMessage,
  });

  final ServerStatus status;
  final int port;
  final String deviceName;
  final bool requirePairConfirmation;
  final bool requireReceiveConfirmation;
  final String? errorMessage;

  bool get isRunning => status == ServerStatus.running;

  ServerState copyWith({
    ServerStatus? status,
    int? port,
    String? deviceName,
    bool? requirePairConfirmation,
    bool? requireReceiveConfirmation,
    String? errorMessage,
  }) {
    return ServerState(
      status: status ?? this.status,
      port: port ?? this.port,
      deviceName: deviceName ?? this.deviceName,
      requirePairConfirmation:
          requirePairConfirmation ?? this.requirePairConfirmation,
      requireReceiveConfirmation:
          requireReceiveConfirmation ?? this.requireReceiveConfirmation,
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
  static const _requirePairConfirmationKey =
      'fastdrop.require_pair_confirmation';
  static const _requireReceiveConfirmationKey =
      'fastdrop.require_receive_confirmation';
  bool _enabled = true;
  bool _requirePairConfirmation = false;
  bool _requireReceiveConfirmation = false;

  bool get isEnabled => _enabled;

  Future<void> _loadEnabled() async {
    await TransferHistoryStore().markInterruptedTransfersFailed();
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? true;
    _requirePairConfirmation =
        prefs.getBool(_requirePairConfirmationKey) ?? false;
    _requireReceiveConfirmation =
        prefs.getBool(_requireReceiveConfirmationKey) ?? false;
    state = state.copyWith(
      requirePairConfirmation: _requirePairConfirmation,
      requireReceiveConfirmation: _requireReceiveConfirmation,
    );
    if (_enabled) {
      await start();
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

  /// Toggle whether an incoming pairing request needs local approval.
  Future<void> setRequirePairConfirmation(bool value) async {
    _requirePairConfirmation = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_requirePairConfirmationKey, value);
    _server?.pairingHandler.requireConfirmation = value;
    if (!value) {
      ref.read(pendingPairRequestsProvider.notifier).clear();
    }
    state = state.copyWith(requirePairConfirmation: value);
  }

  /// Toggle whether transfers from paired peers need a local dialog.
  Future<void> setRequireReceiveConfirmation(bool value) async {
    _requireReceiveConfirmation = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_requireReceiveConfirmationKey, value);
    state = state.copyWith(requireReceiveConfirmation: value);

    if (!value) {
      final pending = List.of(ref.read(incomingTransfersProvider));
      for (final transfer in pending) {
        await acceptTransfer(transfer.transferId);
      }
    }
  }

  /// Start the embedded server.
  Future<void> start() async {
    if (state.isRunning || state.status == ServerStatus.starting) return;
    if (!_enabled) return;

    state = state.copyWith(status: ServerStatus.starting);

    try {
      final deviceId = await DeviceIdManager.getDeviceId();
      final deviceName = DeviceIdManager.anonymousDeviceName(deviceId);

      final localDevice = DeviceInfo(
        deviceId: deviceId,
        deviceName: deviceName,
        platform: _getPlatform(),
        appVersion: fastDropAppVersion,
      );
      final historyStore = TransferHistoryStore();

      final server = FastDropServer(
        localDevice: localDevice,
        requirePairConfirmation: _requirePairConfirmation,
        onPairRequest: (request) {
          debugPrint('[Server] Pair request from ${request.device.deviceName}');
          ref.read(pendingPairRequestsProvider.notifier).addRequest(request);
        },
        onTransferRequest: (transfer) {
          debugPrint('[Server] Transfer offer: ${transfer.transferId}');
          if (_requireReceiveConfirmation) {
            ref.read(incomingTransfersProvider.notifier).addTransfer(transfer);
          } else {
            Future.microtask(() => acceptTransfer(transfer.transferId));
          }
        },
        onTransferChanged: (transfer, peer) {
          final isTerminal = const {
            'completed',
            'failed',
            'cancelled',
            'rejected',
          }.contains(transfer.status);
          unawaited(historyStore.upsert(TransferRow(
            id: transfer.transferId,
            sessionId: transfer.sessionId,
            peerDeviceId: peer?.deviceId ?? '',
            // The protocol direction is from the remote client's viewpoint;
            // history is presented from this phone's viewpoint.
            direction: transfer.direction == 'client_to_server'
                ? 'server_to_client'
                : 'client_to_server',
            status: transfer.status,
            totalFiles: transfer.totalFiles,
            totalBytes: transfer.totalBytes,
            transferredBytes: transfer.transferredBytes,
            createdAt: transfer.createdAt.millisecondsSinceEpoch ~/ 1000,
            completedAt: isTerminal
                ? DateTime.now().millisecondsSinceEpoch ~/ 1000
                : null,
            errorCode: transfer.status == 'failed' ? 'INTERNAL_ERROR' : null,
          )));
        },
        onPeerConnected: (peer) {
          ref.read(incomingPeerConnectionsProvider.notifier).connected(peer);
        },
        onPeerDisconnected: (sessionId) {
          ref
              .read(incomingPeerConnectionsProvider.notifier)
              .disconnected(sessionId);
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
        requirePairConfirmation: _requirePairConfirmation,
        requireReceiveConfirmation: _requireReceiveConfirmation,
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
    try {
      await BackgroundReceiveService.stop();
    } catch (_) {}

    // Clear pending UI state.
    ref.read(pendingPairRequestsProvider.notifier).clear();
    ref.read(incomingPeerConnectionsProvider.notifier).clear();
    ref.read(incomingTransfersProvider.notifier).clear();
    ref.read(activeServerTransfersProvider.notifier).clear();

    state = ServerState(
      requirePairConfirmation: _requirePairConfirmation,
      requireReceiveConfirmation: _requireReceiveConfirmation,
    );
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

  @override
  void dispose() {
    _server?.stop();
    unawaited(BackgroundReceiveService.stop());
    super.dispose();
  }
}

/// Main provider for the embedded server lifecycle.
final fastdropServerProvider =
    StateNotifierProvider<FastDropServerNotifier, ServerState>(
  (ref) => FastDropServerNotifier(ref),
);
