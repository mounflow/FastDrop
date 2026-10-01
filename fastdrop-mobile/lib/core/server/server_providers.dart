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
import 'package:fastdrop_mobile/core/storage/ignored_device_providers.dart';
import 'package:fastdrop_mobile/features/devices/multi_device_connection.dart';
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
    // 历史记录修复失败不应阻塞 server 启动（M16）。
    try {
      await TransferHistoryStore().markInterruptedTransfersFailed();
    } catch (e) {
      debugPrint('[Server] markInterruptedTransfersFailed failed: $e');
    }
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
        // 忽略名单：用户明确删除过的设备不静默接受配对（删除这一主动
        // 操作的结果必须符合用户意愿）。名单常驻内存缓存，删除时刷新。
        isIgnoredDevice: (deviceId, deviceName) =>
            ref.read(ignoredDevicesProvider).any((entry) =>
                entry.deviceId == deviceId || entry.name == deviceName),
        onPairRequest: (request) {
          debugPrint('[Server] Pair request from ${request.device.deviceName}');
          ref.read(pendingPairRequestsProvider.notifier).addRequest(request);
        },
        onPeerAccepted: (device, peerBaseUrl) {
          // 反向配对：对端连进来只让它拿到本机会话；本机要能向对端发送，
          // 需另外拿到对端会话并把它保存为已配对设备。地址优先用入站连接
          // 观测到的地址（不依赖 mDNS）。
          debugPrint('[Server] Peer paired: ${device.deviceName} → reverse pair '
              '(${peerBaseUrl ?? 'no address'})');
          unawaited(ref
              .read(multiDeviceConnectionProvider.notifier)
              .ensureMutualSession(
                deviceId: device.deviceId,
                deviceName: device.deviceName,
                platform: device.platform,
                observedBaseUrl: peerBaseUrl,
              ));
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
            // L15: 接收完成的批次记录首个落盘路径，供历史页"打开"入口。
            savedPath: (transfer.direction == 'client_to_server' &&
                    transfer.status == 'completed')
                ? transfer.files
                    .map((file) => file.finalPath)
                    .firstWhere((path) => path != null, orElse: () => null)
                : null,
          )));
        },
        onPeerConnected: (peer) {
          ref.read(incomingPeerConnectionsProvider.notifier).connected(peer);
          // 见到"未配对"的对端连接就反向配对：会话是单向的，对端连进来
          // 只让它能发给本机；本机要能发给它必须持有对端会话。地址优先用
          // 入站连接观测到的地址。
          unawaited(ref
              .read(multiDeviceConnectionProvider.notifier)
              .ensureMutualSession(
                deviceId: peer.deviceId,
                deviceName: peer.deviceName,
                platform: peer.platform,
                observedBaseUrl: peer.remoteBaseUrl,
              ));
        },
        onPeerDisconnected: (sessionId) {
          ref
              .read(incomingPeerConnectionsProvider.notifier)
              .disconnected(sessionId);
        },
      );

      await server.start();
      _server = server;

      // 常驻保活：接收服务一启动就进前台服务（含唤醒锁 + WifiLock），
      // 而不是等"切后台那一刻"才起——否则熄屏瞬间存在窗口期，CPU 先休眠
      // 导致入站连接无人处理（实测过：熄屏后端口不可达）。
      // 关闭"允许接收文件"会停掉服务端，同时释放保活，不额外耗电。
      unawaited(BackgroundReceiveService.start());

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

  /// 删除设备时调用：**吊销该设备在本机的全部会话**，并向它推送
  /// `session.revoked` + 关闭其 WS 连接。
  ///
  /// 这是"删除 = 双向真正断开"的服务端侧动作——只清本地设备记录是不够
  /// 的，对端会继续持有本机会话并可继续发送。
  void revokeDeviceAccess(String deviceId) {
    final server = _server;
    if (server == null) return;
    server.wsServer.disconnectDeviceSessions(deviceId);
    final revoked = server.sessionManager.revokeByDeviceId(deviceId);
    debugPrint('[Server] revoked ${revoked.length} session(s) '
        'for device $deviceId');
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
