import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/discovery/device_discovery.dart';
import 'package:fastdrop_mobile/core/discovery/discovery_providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/features/devices/nearby_devices_sheet.dart';
import 'package:fastdrop_mobile/features/pairing/pairing_screen.dart';
import 'package:fastdrop_mobile/features/transfer/transfer_service.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:fastdrop_mobile/shared/widgets/status_badge.dart';

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// An incoming file offer from the PC (server_to_client).
class IncomingOffer {
  const IncomingOffer({
    required this.transferId,
    required this.offerId,
    required this.deviceName,
    required this.files,
  });

  final String transferId;
  final String offerId;
  final String deviceName;
  final List<OfferFile> files;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
}

class OfferFile {
  const OfferFile({
    required this.fileId,
    required this.name,
    required this.size,
    this.mimeType,
    this.sha256,
  });

  final String fileId;
  final String name;
  final int size;
  final String? mimeType;
  final String? sha256;
}

/// Tracks a single file download in progress.
class ActiveDownload {
  ActiveDownload({
    required this.transferId,
    required this.fileId,
    required this.fileName,
    required this.totalBytes,
    this.transferredBytes = 0,
    this.status = 'downloading',
    this.error,
  });

  final String transferId;
  final String fileId;
  final String fileName;
  final int totalBytes;
  int transferredBytes;
  String status; // downloading | completed | failed
  String? error;

  double get progress =>
      totalBytes > 0 ? transferredBytes / totalBytes : 0.0;
}

// ---------------------------------------------------------------------------
// Connection state
// ---------------------------------------------------------------------------

/// Describes the current WebSocket connection status.
enum ConnectionStatus {
  idle, // no device selected
  connecting,
  connected,
  disconnected,
  error,
}

class DeviceConnectionState {
  const DeviceConnectionState({
    this.activeDeviceId,
    this.activeDevice,
    this.connectionStatus = ConnectionStatus.idle,
    this.errorMessage,
    this.incomingOffers = const [],
    this.activeDownloads = const [],
    this.sessionExpired = false,
  });

  final String? activeDeviceId;
  final Device? activeDevice;
  final ConnectionStatus connectionStatus;
  final String? errorMessage;
  final List<IncomingOffer> incomingOffers;
  final List<ActiveDownload> activeDownloads;

  /// True when the server rejected our session (e.g. PC restarted).
  /// UI uses this to prompt the user to re-pair.
  final bool sessionExpired;

  bool get isConnected => connectionStatus == ConnectionStatus.connected;

  DeviceConnectionState copyWith({
    String? activeDeviceId,
    Device? activeDevice,
    ConnectionStatus? connectionStatus,
    String? errorMessage,
    List<IncomingOffer>? incomingOffers,
    List<ActiveDownload>? activeDownloads,
    bool? sessionExpired,
  }) {
    return DeviceConnectionState(
      activeDeviceId: activeDeviceId ?? this.activeDeviceId,
      activeDevice: activeDevice ?? this.activeDevice,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      errorMessage: errorMessage,
      incomingOffers: incomingOffers ?? this.incomingOffers,
      activeDownloads: activeDownloads ?? this.activeDownloads,
      sessionExpired: sessionExpired ?? this.sessionExpired,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Manages the currently-active device: connects its WebSocket, tracks
/// connection status, handles incoming file offers, and drives downloads.
///
/// Only one device is connected at a time. Switching tabs in
/// [DevicesScreen] calls [switchToDevice], which disconnects the previous
/// WS and connects the new one.
class DeviceConnectionNotifier extends StateNotifier<DeviceConnectionState> {
  DeviceConnectionNotifier(this._ref) : super(const DeviceConnectionState());

  final Ref _ref;

  TransferService? _transferService;

  /// Transfer IDs that the user has explicitly cancelled.
  final Set<String> _cancelledTransfers = {};

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Connect to [device]. Disconnects any previously-active device first.
  Future<void> switchToDevice(Device device) async {
    if (state.activeDeviceId == device.id &&
        state.connectionStatus != ConnectionStatus.error) {
      // Already active — nothing to do unless we're in error state, in which
      // case we fall through and retry the connection.
      if (state.connectionStatus == ConnectionStatus.connected ||
          state.connectionStatus == ConnectionStatus.connecting) {
        return;
      }
    }

    // Bump lastSeen so getActiveDevice() returns this one next launch.
    final touched = device.copyWith(lastSeen: DateTime.now());
    await _ref.read(deviceStoreProvider).saveDevice(touched);

    // Tear down the previous connection.
    _disconnectInternal();

    state = DeviceConnectionState(
      activeDeviceId: device.id,
      activeDevice: touched,
      connectionStatus: ConnectionStatus.connecting,
    );

    // Configure HTTP client.
    final httpClient = _ref.read(httpClientProvider);
    httpClient.baseUrl = touched.serverBaseUrl;
    httpClient.setSession(touched.sessionId, touched.accessToken);

    // Create TransferService for downloads.
    final wsClient = _ref.read(wsClientProvider);
    _transferService = TransferService(
      httpClient: httpClient,
      wsClient: wsClient,
      onProgress: _onDownloadProgress,
      onStateChange: _onDownloadStateChange,
    );

    // Configure and connect WS client.
    wsClient.baseUrl = touched.serverBaseUrl;
    wsClient.setSession(touched.sessionId, touched.accessToken);

    wsClient
      ..onConnected = _onWsConnected
      ..onDisconnected = _onWsDisconnected
      ..onMessage = _onWsMessage
      ..onAuthFailed = _onWsAuthFailed;

    try {
      await wsClient.connect();
    } catch (e) {
      state = state.copyWith(
        connectionStatus: ConnectionStatus.error,
        errorMessage: 'Failed to connect: $e',
      );
    }
  }

  /// Re-connect the currently-active device. Used by the "重连" button.
  Future<void> reconnect() async {
    final device = state.activeDevice;
    if (device == null) return;
    // Force switchToDevice to retry even though the id matches.
    state = state.copyWith(connectionStatus: ConnectionStatus.idle);
    await switchToDevice(device);
  }

  /// Disconnect the active device and reset state.
  void disconnect() {
    _disconnectInternal();
    state = const DeviceConnectionState();
  }

  void _disconnectInternal() {
    _cancelledTransfers.clear();
    _transferService?.dispose();
    _transferService = null;
    try {
      _ref.read(wsClientProvider).disconnect();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // WS callbacks
  // ---------------------------------------------------------------------------

  void _onWsConnected() {
    if (!mounted) return;
    state = state.copyWith(
      connectionStatus: ConnectionStatus.connected,
      errorMessage: null,
      sessionExpired: false,
    );
  }

  void _onWsDisconnected() {
    if (!mounted) return;
    // Only flip to "disconnected" if we were connected/connecting. The WS
    // client calls this on graceful disconnect too; if we just called
    // disconnect() we want to stay idle.
    if (state.connectionStatus == ConnectionStatus.connected ||
        state.connectionStatus == ConnectionStatus.connecting) {
      state = state.copyWith(connectionStatus: ConnectionStatus.disconnected);
    }
  }

  void _onWsAuthFailed() {
    if (!mounted) return;
    // Server rejected our session. Stay on this tab so the user can
    // choose to delete or re-pair.
    state = state.copyWith(
      sessionExpired: true,
      connectionStatus: ConnectionStatus.error,
      errorMessage: 'Session 已过期，请删除设备后重新扫码',
      incomingOffers: [],
    );
  }

  void _onWsMessage(Map<String, dynamic> message) {
    if (!mounted) return;

    final type = message['type'] as String?;
    final payload = message['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'file.offer':
        _handleIncomingOffer(payload);
        break;
      case 'transfer.started':
        break;
      case 'transfer.progress':
        _handleTransferProgress(payload);
        break;
      case 'transfer.completed':
        _handleTransferCompleted(payload);
        break;
      case 'transfer.failed':
        _handleTransferFailed(payload);
        break;
      case 'transfer.cancelled':
        _handleTransferCancelled(payload);
        break;
      case 'transfer.paused':
        _handleTransferPaused(payload);
        break;
      case 'transfer.resume':
        _handleTransferResume(payload);
        break;
      case 'session.revoked':
        _handleSessionRevoked();
        break;
      case 'error':
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming offer handling
  // ---------------------------------------------------------------------------

  void _handleIncomingOffer(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final offerId = payload['offerId'] as String? ?? '';
    final deviceName = payload['deviceName'] as String? ?? 'PC';
    final filesRaw = payload['files'] as List<dynamic>? ?? [];

    final files = filesRaw.map((f) {
      final m = f as Map<String, dynamic>;
      return OfferFile(
        fileId: m['fileId'] as String? ?? '',
        name: m['name'] as String? ?? 'unknown',
        size: m['size'] as int? ?? 0,
        mimeType: m['mimeType'] as String?,
        sha256: m['sha256'] as String?,
      );
    }).toList();

    final offer = IncomingOffer(
      transferId: transferId,
      offerId: offerId,
      deviceName: deviceName,
      files: files,
    );

    state = state.copyWith(
      incomingOffers: [...state.incomingOffers, offer],
    );
  }

  /// Accept an incoming offer: notify the server, then download each file
  /// with retry (max 3 attempts, exponential backoff).
  Future<void> acceptOffer(IncomingOffer offer) async {
    _cancelledTransfers.remove(offer.transferId);
    state = state.copyWith(
      incomingOffers: state.incomingOffers
          .where((o) => o.transferId != offer.transferId)
          .toList(),
    );

    final wsClient = _ref.read(wsClientProvider);
    wsClient.send({
      'version': 1,
      'type': 'file.offer.accept',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'offerId': offer.transferId},
    });

    final downloads = [...state.activeDownloads];
    for (final f in offer.files) {
      downloads.add(ActiveDownload(
        transferId: offer.transferId,
        fileId: f.fileId,
        fileName: f.name,
        totalBytes: f.size,
      ));
    }
    state = state.copyWith(activeDownloads: downloads);

    const maxRetries = 3;
    const backoffMs = [1000, 2000, 4000];
    for (final f in offer.files) {
      if (_cancelledTransfers.contains(offer.transferId)) return;

      Exception? lastError;
      for (int attempt = 0; attempt < maxRetries; attempt++) {
        if (_cancelledTransfers.contains(offer.transferId)) return;
        try {
          await _transferService?.downloadFile(
            transferId: offer.transferId,
            fileId: f.fileId,
            fileName: f.name,
            totalBytes: f.size,
            expectedSha256: f.sha256 ?? '',
          );
          _updateDownload(offer.transferId, f.fileId, status: 'completed');
          lastError = null;
          break;
        } catch (e) {
          lastError = e is Exception ? e : Exception(e.toString());
          if (attempt < maxRetries - 1) {
            await Future.delayed(Duration(milliseconds: backoffMs[attempt]));
          }
        }
      }
      if (lastError != null) {
        _updateDownload(offer.transferId, f.fileId,
            status: 'failed', error: lastError.toString());
      }
    }
  }

  /// Cancel an in-progress download.
  void cancelDownload(String transferId) {
    _cancelledTransfers.add(transferId);
    _transferService?.cancelTransfer(transferId);
    state = state.copyWith(
      activeDownloads: state.activeDownloads
          .where((d) => d.transferId != transferId)
          .toList(),
    );
  }

  /// Reject an incoming offer.
  void rejectOffer(IncomingOffer offer) {
    state = state.copyWith(
      incomingOffers: state.incomingOffers
          .where((o) => o.transferId != offer.transferId)
          .toList(),
    );

    final wsClient = _ref.read(wsClientProvider);
    wsClient.send({
      'version': 1,
      'type': 'file.offer.reject',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'offerId': offer.transferId,
        'reason': 'user_rejected',
      },
    });
  }

  // ---------------------------------------------------------------------------
  // Download progress / state
  // ---------------------------------------------------------------------------

  void _onDownloadProgress(
      String transferId, String fileId, TransferProgress progress) {
    if (!mounted) return;
    _updateDownload(transferId, fileId,
        transferredBytes: progress.bytesTransferred);
  }

  void _onDownloadStateChange(String transferId, String status,
      {String? errorCode, String? errorMessage}) {
    if (!mounted) return;
    if (status == 'completed' || status == 'failed') {
      final downloads = state.activeDownloads.map((d) {
        if (d.transferId == transferId && d.status == 'downloading') {
          d.status = status;
          d.error = errorMessage;
        }
        return d;
      }).toList();
      state = state.copyWith(activeDownloads: downloads);
    }
  }

  void _updateDownload(String transferId, String fileId,
      {int? transferredBytes, String? status, String? error}) {
    if (!mounted) return;
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId && d.fileId == fileId) {
        if (transferredBytes != null) d.transferredBytes = transferredBytes;
        if (status != null) d.status = status;
        if (error != null) d.error = error;
      }
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  // ---------------------------------------------------------------------------
  // Transfer WS event handlers
  // ---------------------------------------------------------------------------

  void _handleTransferProgress(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final fileId = payload['fileId'] as String? ?? '';
    final transferred = payload['transferredBytes'] as int? ??
        payload['bytesTransferred'] as int? ?? 0;
    _updateDownload(transferId, fileId, transferredBytes: transferred);
  }

  void _handleTransferCompleted(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId) d.status = 'completed';
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleTransferFailed(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final error = payload['error']?.toString() ?? 'Transfer failed';
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId) {
        d.status = 'failed';
        d.error = error;
      }
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleTransferPaused(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId && d.status == 'downloading') {
        d.status = 'paused';
      }
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleTransferResume(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = state.activeDownloads.map((d) {
      if (d.transferId == transferId && d.status == 'paused') {
        d.status = 'downloading';
      }
      return d;
    }).toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleTransferCancelled(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = state.activeDownloads
        .where((d) => d.transferId != transferId)
        .toList();
    state = state.copyWith(activeDownloads: downloads);
  }

  void _handleSessionRevoked() {
    state = state.copyWith(
      sessionExpired: true,
      connectionStatus: ConnectionStatus.error,
      errorMessage: 'PC 已撤销此设备的会话，请删除设备后重新扫码',
      incomingOffers: [],
    );
  }

  /// Clear completed/failed downloads from the list.
  void clearFinishedDownloads() {
    state = state.copyWith(
      activeDownloads: state.activeDownloads
          .where((d) => d.status == 'downloading')
          .toList(),
    );
  }

  @override
  void dispose() {
    _disconnectInternal();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final deviceConnectionProvider =
    StateNotifierProvider<DeviceConnectionNotifier, DeviceConnectionState>(
        (ref) {
  return DeviceConnectionNotifier(ref);
});

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Devices home screen.
///
/// Each paired PC is a tab. Tapping a tab switches the active WS
/// connection. The "+" action in the AppBar opens the pairing screen to
/// add a new PC. An empty state is shown when no devices are paired.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen>
    with TickerProviderStateMixin {
  List<Device> _devices = [];
  bool _loading = true;
  TabController? _tabController;

  /// 上次自动重连的时间戳（防抖，10 秒内不重复尝试）。
  DateTime? _lastAutoReconnect;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _loadDevices({int preferredIndex = -1}) async {
    final store = ref.read(deviceStoreProvider);
    final devices = await store.loadDevices();
    if (!mounted) return;

    setState(() {
      _devices = devices;
      _loading = false;
      _rebuildTabController(devices);
    });

    if (devices.isEmpty) {
      // Make sure the notifier is idle.
      ref.read(deviceConnectionProvider.notifier).disconnect();
      return;
    }

    // Pick the initial tab: honour the caller's preference, otherwise fall
    // back to the most-recently-used device.
    int idx = preferredIndex;
    if (idx < 0 || idx >= devices.length) {
      final active = await store.getActiveDevice();
      idx = devices.indexWhere((d) => d.id == active?.id);
      if (idx < 0) idx = 0;
    }

    final initIdx = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tabController == null) return;
      _tabController!.index = initIdx.clamp(0, devices.length - 1);
      ref
          .read(deviceConnectionProvider.notifier)
          .switchToDevice(devices[_tabController!.index]);
    });
  }

  void _rebuildTabController(List<Device> devices) {
    _tabController?.dispose();
    if (devices.isEmpty) {
      _tabController = null;
      return;
    }
    _tabController = TabController(length: devices.length, vsync: this);
    _tabController!.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    final controller = _tabController;
    if (controller == null) return;
    // indexIsChanging fires on tap-down; we want the settled index.
    if (controller.indexIsChanging) return;
    if (!mounted) return;
    final idx = controller.index;
    if (idx < 0 || idx >= _devices.length) return;
    ref.read(deviceConnectionProvider.notifier).switchToDevice(_devices[idx]);
  }

  /// "+" 按钮入口：根据 mDNS 开关状态走不同流程。
  ///
  /// mDNS 关闭 → 弹窗确认"开启局域网发现？" → 开启 + 附近设备 / 仅扫码
  /// mDNS 开启 → 弹出附近设备列表 + 扫码入口
  Future<void> _onAddDevice() async {
    final mdnsEnabled = ref.read(mdnsEnabledProvider);

    if (!mdnsEnabled) {
      // mDNS 未开启：弹窗确认
      final enable = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('开启局域网发现？'),
          content: const Text(
            '开启后可自动发现同一 WiFi 下运行 FastDrop 的 PC，'
            '无需每次手动扫码。\n\n'
            '也可以仍然使用扫码配对。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('仅扫码'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('开启并发现'),
            ),
          ],
        ),
      );

      if (enable == true && mounted) {
        // 用户选择开启 mDNS → 开启后弹出附近设备列表
        await ref.read(mdnsEnabledProvider.notifier).setEnabled(true);
        if (!mounted) return;
        ref.invalidate(pairedDevicesProvider);
        final discovered = await NearbyDevicesSheet.show(context);
        if (discovered == null || !mounted) return;
        await _onNearbyDeviceSelected(discovered);
      } else if (mounted) {
        // 仅扫码
        _goToPairing();
      }
    } else {
      // mDNS 已开启：先尝试一键连接已配对设备
      await _quickConnectOrShowSheet();
    }
  }

  /// 一键连接：检查后台 mDNS 已发现的设备，如果找到已配对设备则
  /// 直接连接（无 UI），否则弹出附近设备列表让用户选择。
  Future<void> _quickConnectOrShowSheet() async {
    final nearby = ref.read(nearbyDevicesProvider);
    if (nearby.isNotEmpty) {
      final store = ref.read(deviceStoreProvider);
      for (final d in nearby) {
        final matched =
            await store.findMatch(d.baseUrl, d.deviceName);
        if (matched != null && mounted) {
          // 找到已配对设备 → 直接连接，不弹任何列表
          ref
              .read(deviceConnectionProvider.notifier)
              .switchToDevice(matched);
          // 切到对应 tab
          final idx = _devices.indexWhere((dev) => dev.id == matched.id);
          if (idx >= 0 && _tabController != null) {
            _tabController!.animateTo(idx);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('已连接到 ${matched.name}'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }
    }

    // 没有已配对设备（或 mDNS 还没扫到）→ 弹出附近设备列表
    ref.invalidate(pairedDevicesProvider);
    final discovered = await NearbyDevicesSheet.show(context);
    if (discovered == null || !mounted) return;
    await _onNearbyDeviceSelected(discovered);
  }

  /// 用户在附近设备列表中选择了某台设备。
  /// 已配对 → 直接 switchToDevice（跳过扫码）；未配对 → 进扫码页。
  Future<void> _onNearbyDeviceSelected(DiscoveredDevice discovered) async {
    final store = ref.read(deviceStoreProvider);
    final matched = await store.findMatch(
        discovered.baseUrl, discovered.deviceName);

    if (matched == null) {
      // 未配对 → 半自动 D-2 配对（免扫码）
      ref.read(pairingProvider.notifier).pairViaMdns(discovered);
      await _goToMdnsPairing();
      return;
    }

    // 已配对 → 直接连接
    Device device = matched;

    // IP 可能变了（mDNS 发现新 IP）→ 更新存储
    if (matched.serverBaseUrl != discovered.baseUrl) {
      device = Device(
        id: discovered.baseUrl,
        name: matched.name,
        serverBaseUrl: discovered.baseUrl,
        sessionId: matched.sessionId,
        accessToken: matched.accessToken,
        lastSeen: DateTime.now(),
        expiresAt: matched.expiresAt,
      );
      await store.removeDevice(matched.id);
      await store.saveDevice(device);
      ref.invalidate(pairedDevicesProvider);
    }

    if (!mounted) return;

    // 切到对应 tab（如果存在）
    final idx = _devices.indexWhere((d) => d.id == device.id);
    if (idx >= 0 && _tabController != null) {
      _tabController!.animateTo(idx);
    }
    ref.read(deviceConnectionProvider.notifier).switchToDevice(device);
  }

  /// 导航到扫码配对页。
  Future<void> _goToPairing() async {
    ref.read(pairingProvider.notifier).resetToScanning();
    await Navigator.of(context).pushNamed('/pairing');
    if (mounted) {
      _loadDevices(preferredIndex: _devices.length);
    }
  }

  /// mDNS 设备列表变化回调：如果当前活跃设备处于 error/disconnected
  /// 状态且被 mDNS 重新发现，自动尝试重连（阶段 4 核心逻辑）。
  void _onNearbyDevicesChanged(
      List<DiscoveredDevice> devices, DeviceConnectionState connState) {
    if (devices.isEmpty) return;
    final status = connState.connectionStatus;
    if (status != ConnectionStatus.error &&
        status != ConnectionStatus.disconnected) {
      return;
    }
    // Session 过期不自动重连——需要用户重新配对
    if (connState.sessionExpired) return;
    final activeDevice = connState.activeDevice;
    if (activeDevice == null) return;

    // 在发现的设备中查找匹配项
    final found = devices.any((d) =>
        d.baseUrl == activeDevice.serverBaseUrl ||
        d.deviceName == activeDevice.name);
    if (!found) return;

    // 冷却：10 秒内不重复尝试
    if (_lastAutoReconnect != null &&
        DateTime.now().difference(_lastAutoReconnect!) <
            const Duration(seconds: 10)) {
      return;
    }
    _lastAutoReconnect = DateTime.now();
    ref.read(deviceConnectionProvider.notifier).reconnect();
  }

  /// 半自动配对：pairViaMdns 已设置 polling 状态，直接导航到 PairingScreen。
  /// 不调用 resetToScanning（会覆盖 polling 状态）。
  Future<void> _goToMdnsPairing() async {
    await Navigator.of(context).pushNamed('/pairing');
    if (mounted) {
      _loadDevices(preferredIndex: _devices.length);
    }
  }

  /// Session 过期后重新扫码配对：删除旧设备 → 进扫码页。
  Future<void> _reScanPair(Device device) async {
    ref.read(deviceConnectionProvider.notifier).disconnect();
    await ref.read(deviceStoreProvider).removeDevice(device.id);
    ref.invalidate(pairedDevicesProvider);
    _goToPairing();
  }

  Future<void> _onDeleteDevice(Device device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除设备？'),
        content: Text(
          '将删除 "${device.name}" 及其会话。'
          '\n需要再次发送文件请重新扫码配对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final notifier = ref.read(deviceConnectionProvider.notifier);
    if (ref.read(deviceConnectionProvider).activeDeviceId == device.id) {
      notifier.disconnect();
    }
    await ref.read(deviceStoreProvider).removeDevice(device.id);
    ref.invalidate(pairedDevicesProvider);

    final remaining = await ref.read(deviceStoreProvider).loadDevices();
    if (!mounted) return;
    setState(() {
      _devices = remaining;
      _rebuildTabController(remaining);
    });

    if (remaining.isEmpty) {
      // Notifier already disconnected above.
      return;
    }
    // Connect to the first remaining device.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tabController == null) return;
      _tabController!.index = 0;
      ref
          .read(deviceConnectionProvider.notifier)
          .switchToDevice(remaining.first);
    });
  }

  @override
  Widget build(BuildContext context) {
    final connState = ref.watch(deviceConnectionProvider);

    // 阶段4: mDNS 发现已配对设备 → 自动重连
    ref.listen<List<DiscoveredDevice>>(nearbyDevicesProvider, (_, devices) {
      _onNearbyDevicesChanged(devices, connState);
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('FastDrop'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => Navigator.of(context).pushNamed('/history'),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加设备',
            onPressed: _onAddDevice,
          ),
        ],
        bottom: (_devices.isEmpty || _tabController == null)
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabs: _devices
                      .map((d) => Tab(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.computer, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  d.name,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),
      ),
      body: _buildBody(connState),
    );
  }

  Widget _buildBody(DeviceConnectionState connState) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_devices.isEmpty) {
      return _buildEmptyState();
    }
    return TabBarView(
      controller: _tabController,
      children: _devices
          .asMap()
          .entries
          .map((entry) =>
              _buildDeviceTab(entry.key, entry.value, connState))
          .toList(),
    );
  }

  // -- Empty state ------------------------------------------------------------

  Widget _buildEmptyState() {
    final mdnsEnabled = ref.watch(mdnsEnabledProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.devices_other, size: 72, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              '还没有配对的设备',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            const Text(
              '点击右上角的 + 添加一台 PC',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _onAddDevice,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫码添加设备'),
            ),
            if (mdnsEnabled) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  ref.invalidate(pairedDevicesProvider);
                  final discovered = await NearbyDevicesSheet.show(context);
                  if (discovered != null && mounted) {
                    await _onNearbyDeviceSelected(discovered);
                  }
                },
                icon: const Icon(Icons.radar),
                label: const Text('查看附近设备'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // -- Per-device tab content -------------------------------------------------

  Widget _buildDeviceTab(
      int index, Device device, DeviceConnectionState connState) {
    final isActive = connState.activeDeviceId == device.id;
    final status =
        isActive ? connState.connectionStatus : ConnectionStatus.idle;
    final errorMessage = isActive ? connState.errorMessage : null;
    final sessionExpired = isActive && connState.sessionExpired;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DeviceCard(
            device: device,
            status: status,
            errorMessage: errorMessage,
            sessionExpired: sessionExpired,
          ),
          const SizedBox(height: 16),
          // Primary actions depend on connection state.
          if (status == ConnectionStatus.connected) ...[
            ElevatedButton.icon(
              onPressed: _onSendFiles,
              icon: const Icon(Icons.file_upload),
              label: const Text('发送文件'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ] else if (status == ConnectionStatus.connecting) ...[
            const _InfoRow(
              icon: Icons.hourglass_top,
              text: '正在连接…',
            ),
          ] else ...[
            // Session 过期时提供重新扫码入口（阶段 4: D-3 降级）
            if (sessionExpired) ...[
              ElevatedButton.icon(
                onPressed: () => _reScanPair(device),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('重新扫码配对'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isActive
                        ? () => ref
                            .read(deviceConnectionProvider.notifier)
                            .reconnect()
                        : () => ref
                            .read(deviceConnectionProvider.notifier)
                            .switchToDevice(device),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新连接'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _onDeleteDevice(device),
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.red),
                    label: const Text('删除设备',
                        style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
          ],

          // Active-device-only sections.
          if (isActive) ...[
            if (connState.incomingOffers.isNotEmpty) ...[
              const SizedBox(height: 24),
              _buildIncomingOffers(connState),
            ],
            if (connState.activeDownloads.isNotEmpty) ...[
              const SizedBox(height: 24),
              _buildActiveDownloads(connState),
            ],
          ],

          const SizedBox(height: 24),
          Center(
            child: Text(
              isActive
                  ? '在局域网内向 ${device.name} 发送文件。\n无云、无账号、无限制。'
                  : '此设备非当前活跃连接。\n切换到此 Tab 即可连接。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withOpacity(0.5),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -- Incoming offers UI -----------------------------------------------------

  Widget _buildIncomingOffers(DeviceConnectionState state) {
    final notifier = ref.read(deviceConnectionProvider.notifier);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Incoming Files', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ...state.incomingOffers.map((offer) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'From: ${offer.deviceName}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${offer.files.length} file(s)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ...offer.files.map((f) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '${f.name}  (${_formatBytes(f.size)})',
                            style: theme.textTheme.bodySmall,
                          ),
                        )),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => notifier.rejectOffer(offer),
                          child: const Text('Reject',
                              style: TextStyle(color: Colors.red)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => notifier.acceptOffer(offer),
                          child: const Text('Accept'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )),
      ],
    );
  }

  // -- Active downloads UI ----------------------------------------------------

  Widget _buildActiveDownloads(DeviceConnectionState state) {
    final notifier = ref.read(deviceConnectionProvider.notifier);
    final theme = Theme.of(context);
    final hasFinished =
        state.activeDownloads.any((d) => d.status != 'downloading');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Downloads', style: theme.textTheme.titleSmall),
            if (hasFinished)
              TextButton(
                onPressed: notifier.clearFinishedDownloads,
                child: const Text('Clear finished'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ...state.activeDownloads.map((d) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            d.fileName,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _downloadStatusChip(d),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: d.progress,
                        minHeight: 6,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          d.status == 'failed'
                              ? Colors.red
                              : d.status == 'completed'
                                  ? Colors.green
                                  : theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_formatBytes(d.transferredBytes)} / ${_formatBytes(d.totalBytes)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                    if (d.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          d.error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.red,
                            fontSize: 11,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (d.status == 'downloading')
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              onPressed: () =>
                                  notifier.cancelDownload(d.transferId),
                              icon: const Icon(Icons.cancel, size: 16),
                              label: const Text('Cancel'),
                              style: TextButton.styleFrom(
                                  foregroundColor: Colors.red),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            )),
      ],
    );
  }

  Widget _downloadStatusChip(ActiveDownload d) {
    Color color;
    String label;
    switch (d.status) {
      case 'completed':
        color = Colors.green;
        label = 'Done';
        break;
      case 'failed':
        color = Colors.red;
        label = 'Failed';
        break;
      default:
        color = Colors.blue;
        label = '${(d.progress * 100).toInt()}%';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  void _onSendFiles() {
    Navigator.of(context).pushNamed('/file-picker');
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

// ---------------------------------------------------------------------------
// Small private widgets
// ---------------------------------------------------------------------------

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.status,
    required this.errorMessage,
    required this.sessionExpired,
  });

  final Device device;
  final ConnectionStatus status;
  final String? errorMessage;
  final bool sessionExpired;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.computer, size: 48),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    device.serverBaseUrl,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ] else if (sessionExpired) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Session 已过期，请删除设备后重新扫码。',
                      style: TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            _connectionBadge(status),
          ],
        ),
      ),
    );
  }

  Widget _connectionBadge(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return const StatusBadge(label: 'Connected', color: Colors.green);
      case ConnectionStatus.connecting:
        return const StatusBadge(label: 'Connecting...', color: Colors.orange);
      case ConnectionStatus.disconnected:
        return const StatusBadge(label: 'Disconnected', color: Colors.red);
      case ConnectionStatus.error:
        return const StatusBadge(label: 'Error', color: Colors.red);
      case ConnectionStatus.idle:
        return const StatusBadge(label: 'Offline', color: Colors.grey);
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
