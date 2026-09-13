import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/network/ws_client.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/storage/transfer_history_store.dart';
import 'package:fastdrop_mobile/features/transfer/transfer_service.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';

enum MultiConnectionStatus {
  idle,
  connecting,
  connected,
  disconnected,
  error,
}

class MultiIncomingOffer {
  const MultiIncomingOffer({
    required this.deviceId,
    required this.transferId,
    required this.offerId,
    required this.deviceName,
    required this.files,
  });

  final String deviceId;
  final String transferId;
  final String offerId;
  final String deviceName;
  final List<MultiOfferFile> files;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);
}

class MultiOfferFile {
  const MultiOfferFile({
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

class MultiActiveDownload {
  MultiActiveDownload({
    required this.deviceId,
    required this.transferId,
    required this.fileId,
    required this.fileName,
    required this.totalBytes,
    this.transferredBytes = 0,
    this.status = 'downloading',
    this.error,
  });

  final String deviceId;
  final String transferId;
  final String fileId;
  final String fileName;
  final int totalBytes;
  int transferredBytes;
  String status;
  String? error;

  double get progress => totalBytes > 0 ? transferredBytes / totalBytes : 0;
}

class PeerConnectionView {
  const PeerConnectionView({
    required this.device,
    this.status = MultiConnectionStatus.idle,
    this.errorMessage,
    this.incomingOffers = const [],
    this.activeDownloads = const [],
    this.sessionExpired = false,
  });

  final Device device;
  final MultiConnectionStatus status;
  final String? errorMessage;
  final List<MultiIncomingOffer> incomingOffers;
  final List<MultiActiveDownload> activeDownloads;
  final bool sessionExpired;

  bool get isConnected => status == MultiConnectionStatus.connected;

  PeerConnectionView copyWith({
    Device? device,
    MultiConnectionStatus? status,
    String? errorMessage,
    bool clearError = false,
    List<MultiIncomingOffer>? incomingOffers,
    List<MultiActiveDownload>? activeDownloads,
    bool? sessionExpired,
  }) {
    return PeerConnectionView(
      device: device ?? this.device,
      status: status ?? this.status,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      incomingOffers: incomingOffers ?? this.incomingOffers,
      activeDownloads: activeDownloads ?? this.activeDownloads,
      sessionExpired: sessionExpired ?? this.sessionExpired,
    );
  }
}

class MultiDeviceConnectionState {
  const MultiDeviceConnectionState({
    this.selectedDeviceId,
    this.peers = const {},
  });

  final String? selectedDeviceId;
  final Map<String, PeerConnectionView> peers;

  PeerConnectionView? peer(String deviceId) => peers[deviceId];
  PeerConnectionView? get selectedPeer => peers[selectedDeviceId];
  Device? get activeDevice => selectedPeer?.device;
  String? get activeDeviceId => selectedDeviceId;
  MultiConnectionStatus get connectionStatus =>
      selectedPeer?.status ?? MultiConnectionStatus.idle;
  String? get errorMessage => selectedPeer?.errorMessage;
  bool get sessionExpired => selectedPeer?.sessionExpired ?? false;
  List<MultiIncomingOffer> get incomingOffers =>
      selectedPeer?.incomingOffers ?? const [];
  List<MultiActiveDownload> get activeDownloads =>
      selectedPeer?.activeDownloads ?? const [];
  bool get isConnected => selectedPeer?.isConnected ?? false;
  List<Device> get connectedDevices => peers.values
      .where((peer) => peer.isConnected)
      .map((peer) => peer.device)
      .toList(growable: false);

  MultiDeviceConnectionState copyWith({
    String? selectedDeviceId,
    Map<String, PeerConnectionView>? peers,
  }) {
    return MultiDeviceConnectionState(
      selectedDeviceId: selectedDeviceId ?? this.selectedDeviceId,
      peers: peers ?? this.peers,
    );
  }
}

typedef MultiTransferProgressCallback = void Function(
  String deviceId,
  String transferId,
  String fileId,
  TransferProgress progress,
);

typedef MultiTransferStateCallback = void Function(
  String deviceId,
  String transferId,
  String status, {
  String? errorCode,
  String? errorMessage,
});

class _PeerRuntime {
  _PeerRuntime({
    required this.device,
    required this.httpClient,
    required this.wsClient,
  });

  final Device device;
  final FastDropHttpClient httpClient;
  final FastDropWsClient wsClient;
  late final TransferService downloadService;
  final Set<TransferService> uploadServices = {};
  final Set<String> cancelledTransfers = {};
  final Map<String, Completer<void>> readiness = {};
  final Map<String, bool> resolvedReadiness = {};

  void dispose() {
    downloadService.dispose();
    for (final service in uploadServices) {
      service.dispose();
    }
    uploadServices.clear();
    for (final completer in readiness.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Peer disconnected'));
      }
    }
    readiness.clear();
    resolvedReadiness.clear();
    wsClient.disconnect();
    httpClient.dispose();
  }
}

/// Owns one independent authenticated HTTP/WS pair per device. Selecting a
/// tab only changes [selectedDeviceId]; it never tears down another peer.
class MultiDeviceConnectionNotifier
    extends StateNotifier<MultiDeviceConnectionState> {
  MultiDeviceConnectionNotifier(this._ref)
      : super(const MultiDeviceConnectionState());

  final Ref _ref;
  final HttpRequestLimiter _globalHttpLimiter = HttpRequestLimiter(6);
  final HttpRequestLimiter _globalFileLimiter = HttpRequestLimiter(2);
  final TransferHistoryStore _historyStore = TransferHistoryStore();
  final Map<String, int> _historyCreatedAt = {};
  final Map<String, _PeerRuntime> _runtimes = {};

  Future<void> connectAll(List<Device> devices) async {
    final currentIds = devices.map((device) => device.id).toSet();
    for (final id in _runtimes.keys.toList()) {
      if (!currentIds.contains(id)) disconnectDevice(id);
    }
    await Future.wait(
      devices.map((device) => connectDevice(device, select: false)),
    );
  }

  Future<void> switchToDevice(Device device) async {
    state = state.copyWith(selectedDeviceId: device.id);
    final peer = state.peer(device.id);
    if (peer?.status == MultiConnectionStatus.connected ||
        peer?.status == MultiConnectionStatus.connecting) {
      return;
    }
    await connectDevice(device);
  }

  Future<void> connectDevice(Device device, {bool select = true}) async {
    if (select) {
      state = state.copyWith(selectedDeviceId: device.id);
    }
    final current = state.peer(device.id);
    if (current?.status == MultiConnectionStatus.connected ||
        current?.status == MultiConnectionStatus.connecting) {
      return;
    }

    final touched = device.copyWith(lastSeen: DateTime.now());
    if (select) await _ref.read(deviceStoreProvider).saveDevice(touched);

    _disposeRuntime(device.id);
    _setPeer(
      device.id,
      PeerConnectionView(
        device: touched,
        status: MultiConnectionStatus.connecting,
      ),
    );

    final httpClient = FastDropHttpClient(
      baseUrl: touched.serverBaseUrl,
      requestLimiter: _globalHttpLimiter,
    )..setSession(touched.sessionId, touched.accessToken);
    final wsClient = FastDropWsClient()
      ..baseUrl = touched.serverBaseUrl
      ..setSession(touched.sessionId, touched.accessToken);
    final runtime = _PeerRuntime(
      device: touched,
      httpClient: httpClient,
      wsClient: wsClient,
    );
    runtime.downloadService = TransferService(
      httpClient: httpClient,
      wsClient: wsClient,
      onProgress: (transferId, fileId, progress) =>
          _onDownloadProgress(device.id, transferId, fileId, progress),
      onStateChange: (transferId, status, {errorCode, errorMessage}) =>
          _onDownloadStateChange(device.id, transferId, status,
              errorMessage: errorMessage),
    );
    _runtimes[device.id] = runtime;

    wsClient.onConnected = () => _setPeerFields(
          device.id,
          status: MultiConnectionStatus.connected,
          clearError: true,
          sessionExpired: false,
        );
    wsClient.onDisconnected = () => _setPeerFields(
          device.id,
          status: MultiConnectionStatus.disconnected,
        );
    wsClient.onAuthFailed = () => _setPeerFields(
          device.id,
          status: MultiConnectionStatus.error,
          errorMessage: 'Session 已失效，请重新配对',
          sessionExpired: true,
          clearOffers: true,
        );
    wsClient.onMessage = (message) => _onWsMessage(device.id, message);

    try {
      await wsClient.connect();
    } catch (error) {
      _setPeerFields(
        device.id,
        status: MultiConnectionStatus.error,
        errorMessage: '连接失败: $error',
      );
    }
  }

  Future<void> reconnect([String? deviceId]) async {
    final id = deviceId ?? state.selectedDeviceId;
    final device = id == null ? null : state.peer(id)?.device;
    if (device == null) return;
    disconnectDevice(id!);
    await connectDevice(device, select: state.selectedDeviceId == id);
  }

  void disconnectDevice(String deviceId) {
    _disposeRuntime(deviceId);
    final peers = Map<String, PeerConnectionView>.from(state.peers)
      ..remove(deviceId);
    state = MultiDeviceConnectionState(
      selectedDeviceId:
          state.selectedDeviceId == deviceId ? null : state.selectedDeviceId,
      peers: peers,
    );
  }

  void disconnect() {
    for (final id in _runtimes.keys.toList()) {
      _disposeRuntime(id);
    }
    state = const MultiDeviceConnectionState();
  }

  Future<void> uploadFilesToDevices({
    required List<String> deviceIds,
    required List<String> filePaths,
    MultiTransferProgressCallback? onProgress,
    MultiTransferStateCallback? onStateChange,
  }) async {
    if (deviceIds.isEmpty || filePaths.isEmpty) return;

    var totalBytes = 0;
    for (final path in filePaths) {
      try {
        totalBytes += await File(path).length();
      } catch (_) {
        // TransferService reports the actual file error to the caller.
      }
    }
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final futures = <Future<void>>[];
    for (final deviceId in deviceIds.toSet()) {
      final runtime = _runtimes[deviceId];
      if (runtime == null || !runtime.wsClient.isConnected) {
        onStateChange?.call(
          deviceId,
          'not-started',
          'failed',
          errorCode: 'SESSION_DISCONNECTED',
          errorMessage: '设备未连接',
        );
        continue;
      }

      final waitsForAcceptance = const {'android', 'ios', 'macos'}
          .contains(runtime.device.platform.toLowerCase());
      final transferredByFile = <String, int>{};
      late final TransferService service;
      service = TransferService(
        httpClient: runtime.httpClient,
        wsClient: runtime.wsClient,
        cleanupSourceFiles: false,
        fileLimiter: _globalFileLimiter,
        waitForReady: waitsForAcceptance
            ? (transferId) => _waitForTransferReady(deviceId, transferId)
            : null,
        onProgress: (transferId, fileId, progress) {
          transferredByFile[fileId] = progress.bytesTransferred;
          onProgress?.call(deviceId, transferId, fileId, progress);
        },
        onStateChange: (transferId, status, {errorCode, errorMessage}) {
          final isTerminal = const {
            'completed',
            'failed',
            'cancelled',
            'rejected',
          }.contains(status);
          unawaited(_historyStore.upsert(TransferRow(
            id: transferId,
            sessionId: runtime.device.sessionId,
            peerDeviceId: runtime.device.id,
            direction: 'client_to_server',
            status: status,
            totalFiles: filePaths.length,
            totalBytes: totalBytes,
            transferredBytes: status == 'completed'
                ? totalBytes
                : transferredByFile.values.fold(0, (sum, value) => sum + value),
            createdAt: createdAt,
            completedAt: isTerminal
                ? DateTime.now().millisecondsSinceEpoch ~/ 1000
                : null,
            errorCode: errorCode,
            errorMessage: errorMessage,
          )));
          onStateChange?.call(
            deviceId,
            transferId,
            status,
            errorCode: errorCode,
            errorMessage: errorMessage,
          );
        },
      );
      runtime.uploadServices.add(service);
      futures.add(service.uploadFiles(filePaths).whenComplete(() {
        runtime.uploadServices.remove(service);
        service.dispose();
      }));
    }

    try {
      await Future.wait(futures, eagerError: false);
    } finally {
      await _cleanupPickerCopies(filePaths);
    }
  }

  Future<void> cancelTransfer(String deviceId, String transferId) async {
    final runtime = _runtimes[deviceId];
    if (runtime == null) return;
    await Future.wait(
      runtime.uploadServices
          .map((service) => service.cancelTransfer(transferId)),
    );
  }

  void pauseTransfer(String deviceId, String transferId) {
    final runtime = _runtimes[deviceId];
    runtime?.downloadService.pauseTransfer(transferId);
    for (final service
        in runtime?.uploadServices ?? const <TransferService>{}) {
      service.pauseTransfer(transferId);
    }
    _sendTransferCommand(deviceId, 'transfer.pause', transferId);
  }

  void resumeTransfer(String deviceId, String transferId) {
    final runtime = _runtimes[deviceId];
    runtime?.downloadService.resumeTransfer(transferId);
    for (final service
        in runtime?.uploadServices ?? const <TransferService>{}) {
      service.resumeTransfer(transferId);
    }
    _sendTransferCommand(deviceId, 'transfer.resume', transferId);
  }

  Future<void> acceptOffer(MultiIncomingOffer offer) async {
    final runtime = _runtimes[offer.deviceId];
    if (runtime == null) return;
    _removeOffer(offer);
    runtime.wsClient.send({
      'version': 1,
      'type': 'file.offer.accept',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'offerId': offer.offerId},
    });

    final peer = state.peer(offer.deviceId);
    if (peer == null) return;
    _recordIncomingOffer(runtime, offer, 'transferring');
    final downloads = [...peer.activeDownloads];
    for (final file in offer.files) {
      downloads.add(MultiActiveDownload(
        deviceId: offer.deviceId,
        transferId: offer.transferId,
        fileId: file.fileId,
        fileName: file.name,
        totalBytes: file.size,
      ));
    }
    _setPeer(offer.deviceId, peer.copyWith(activeDownloads: downloads));

    var allSucceeded = true;
    for (final file in offer.files) {
      if (runtime.cancelledTransfers.contains(offer.transferId)) return;
      try {
        await runtime.downloadService.downloadFile(
          transferId: offer.transferId,
          fileId: file.fileId,
          fileName: file.name,
          totalBytes: file.size,
          expectedSha256: file.sha256 ?? '',
        );
        _updateDownload(offer.deviceId, offer.transferId, file.fileId,
            status: 'completed');
      } catch (error) {
        allSucceeded = false;
        _updateDownload(offer.deviceId, offer.transferId, file.fileId,
            status: 'failed', error: error.toString());
      }
    }
    runtime.wsClient.send({
      'version': 1,
      'type': allSucceeded ? 'transfer.completed' : 'transfer.failed',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'transferId': offer.transferId,
        if (!allSucceeded) 'reason': 'download_failed',
      },
    });
    _recordIncomingOffer(
      runtime,
      offer,
      allSucceeded ? 'completed' : 'failed',
      errorCode: allSucceeded ? null : 'INTERNAL_ERROR',
    );
  }

  void rejectOffer(MultiIncomingOffer offer) {
    final runtime = _runtimes[offer.deviceId];
    _removeOffer(offer);
    runtime?.wsClient.send({
      'version': 1,
      'type': 'file.offer.reject',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'offerId': offer.offerId, 'reason': 'user_rejected'},
    });
    if (runtime != null) {
      _recordIncomingOffer(runtime, offer, 'rejected');
    }
  }

  void cancelDownload(String deviceId, String transferId) {
    final runtime = _runtimes[deviceId];
    runtime?.cancelledTransfers.add(transferId);
    runtime?.downloadService.cancelTransfer(transferId);
    final peer = state.peer(deviceId);
    if (peer == null) return;
    _setPeer(
      deviceId,
      peer.copyWith(
        activeDownloads: peer.activeDownloads
            .where((download) => download.transferId != transferId)
            .toList(),
      ),
    );
  }

  void clearFinishedDownloads([String? deviceId]) {
    final id = deviceId ?? state.selectedDeviceId;
    final peer = id == null ? null : state.peer(id);
    if (peer == null) return;
    _setPeer(
      id!,
      peer.copyWith(
        activeDownloads: peer.activeDownloads
            .where((download) => download.status == 'downloading')
            .toList(),
      ),
    );
  }

  Future<void> _waitForTransferReady(String deviceId, String transferId) async {
    final runtime = _runtimes[deviceId];
    if (runtime == null) throw StateError('Peer disconnected');
    final resolved = runtime.resolvedReadiness.remove(transferId);
    if (resolved != null) {
      if (resolved) return;
      throw StateError('对方拒绝接收文件');
    }
    final completer = Completer<void>();
    runtime.readiness[transferId] = completer;
    try {
      await completer.future.timeout(const Duration(minutes: 2));
    } finally {
      runtime.readiness.remove(transferId);
    }
  }

  void _onWsMessage(String deviceId, Map<String, dynamic> message) {
    final type = message['type'] as String?;
    final payload = message['payload'] as Map<String, dynamic>? ?? const {};
    switch (type) {
      case 'file.offer':
        _handleIncomingOffer(deviceId, payload);
        break;
      case 'transfer.accepted':
      case 'file.offer.accept':
        _resolveReadiness(deviceId, payload, accepted: true);
        break;
      case 'transfer.rejected':
      case 'file.offer.reject':
        _resolveReadiness(deviceId, payload, accepted: false);
        break;
      case 'transfer.progress':
        _handleTransferProgress(deviceId, payload);
        break;
      case 'transfer.completed':
        _setDownloadStatus(deviceId, payload, 'completed');
        break;
      case 'transfer.failed':
        _setDownloadStatus(deviceId, payload, 'failed',
            error:
                payload['error']?.toString() ?? payload['reason']?.toString());
        break;
      case 'transfer.cancelled':
        _removeDownloads(deviceId, payload['transferId'] as String? ?? '');
        break;
      case 'session.revoked':
        _setPeerFields(
          deviceId,
          status: MultiConnectionStatus.error,
          errorMessage: '对方已撤销会话，请重新配对',
          sessionExpired: true,
          clearOffers: true,
        );
        break;
    }
  }

  void _handleIncomingOffer(String deviceId, Map<String, dynamic> payload) {
    final peer = state.peer(deviceId);
    if (peer == null) return;
    final transferId = payload['transferId'] as String? ?? '';
    final offerId = payload['offerId'] as String? ?? transferId;
    final rawFiles = payload['files'] as List<dynamic>? ?? const [];
    final offer = MultiIncomingOffer(
      deviceId: deviceId,
      transferId: transferId,
      offerId: offerId,
      deviceName: payload['deviceName'] as String? ?? peer.device.name,
      files: rawFiles.map((value) {
        final file = value as Map<String, dynamic>;
        return MultiOfferFile(
          fileId: file['fileId'] as String? ?? '',
          name: file['name'] as String? ?? 'unknown',
          size: file['size'] as int? ?? 0,
          mimeType: file['mimeType'] as String?,
          sha256: file['sha256'] as String?,
        );
      }).toList(),
    );
    _setPeer(
      deviceId,
      peer.copyWith(incomingOffers: [...peer.incomingOffers, offer]),
    );
  }

  void _resolveReadiness(String deviceId, Map<String, dynamic> payload,
      {required bool accepted}) {
    final transferId =
        payload['transferId'] as String? ?? payload['offerId'] as String? ?? '';
    final runtime = _runtimes[deviceId];
    if (runtime == null) return;
    final completer = runtime.readiness[transferId];
    if (completer == null) {
      runtime.resolvedReadiness[transferId] = accepted;
      return;
    }
    if (completer.isCompleted) return;
    if (accepted) {
      completer.complete();
    } else {
      completer.completeError(StateError('对方拒绝接收文件'));
    }
  }

  void _onDownloadProgress(String deviceId, String transferId, String fileId,
      TransferProgress progress) {
    _updateDownload(deviceId, transferId, fileId,
        transferredBytes: progress.bytesTransferred);
  }

  void _onDownloadStateChange(String deviceId, String transferId, String status,
      {String? errorMessage}) {
    if (status == 'completed' || status == 'failed') {
      _setDownloadStatus(
        deviceId,
        {'transferId': transferId},
        status,
        error: errorMessage,
      );
    }
  }

  void _handleTransferProgress(String deviceId, Map<String, dynamic> payload) {
    _updateDownload(
      deviceId,
      payload['transferId'] as String? ?? '',
      payload['fileId'] as String? ?? '',
      transferredBytes: payload['transferredBytes'] as int? ??
          payload['bytesTransferred'] as int? ??
          0,
    );
  }

  void _updateDownload(String deviceId, String transferId, String fileId,
      {int? transferredBytes, String? status, String? error}) {
    final peer = state.peer(deviceId);
    if (peer == null) return;
    final downloads = peer.activeDownloads.map((download) {
      if (download.transferId == transferId && download.fileId == fileId) {
        if (transferredBytes != null) {
          download.transferredBytes = transferredBytes;
        }
        if (status != null) download.status = status;
        if (error != null) download.error = error;
      }
      return download;
    }).toList();
    _setPeer(deviceId, peer.copyWith(activeDownloads: downloads));
  }

  void _setDownloadStatus(
      String deviceId, Map<String, dynamic> payload, String status,
      {String? error}) {
    final peer = state.peer(deviceId);
    if (peer == null) return;
    final transferId = payload['transferId'] as String? ?? '';
    final downloads = peer.activeDownloads.map((download) {
      if (download.transferId == transferId) {
        download.status = status;
        download.error = error;
        if (status == 'completed') {
          download.transferredBytes = download.totalBytes;
        }
      }
      return download;
    }).toList();
    _setPeer(deviceId, peer.copyWith(activeDownloads: downloads));
  }

  void _removeDownloads(String deviceId, String transferId) {
    final peer = state.peer(deviceId);
    if (peer == null) return;
    _setPeer(
      deviceId,
      peer.copyWith(
        activeDownloads: peer.activeDownloads
            .where((download) => download.transferId != transferId)
            .toList(),
      ),
    );
  }

  void _removeOffer(MultiIncomingOffer offer) {
    final peer = state.peer(offer.deviceId);
    if (peer == null) return;
    _setPeer(
      offer.deviceId,
      peer.copyWith(
        incomingOffers: peer.incomingOffers
            .where((item) => item.transferId != offer.transferId)
            .toList(),
      ),
    );
  }

  void _sendTransferCommand(String deviceId, String type, String transferId) {
    _runtimes[deviceId]?.wsClient.send({
      'version': 1,
      'type': type,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'transferId': transferId},
    });
  }

  void _recordIncomingOffer(
    _PeerRuntime runtime,
    MultiIncomingOffer offer,
    String status, {
    String? errorCode,
  }) {
    final terminal = const {
      'completed',
      'failed',
      'cancelled',
      'rejected',
    }.contains(status);
    final createdAt = _historyCreatedAt.putIfAbsent(
      offer.transferId,
      () => DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    if (terminal) _historyCreatedAt.remove(offer.transferId);
    unawaited(_historyStore.upsert(TransferRow(
      id: offer.transferId,
      sessionId: runtime.device.sessionId,
      peerDeviceId: runtime.device.id,
      direction: 'server_to_client',
      status: status,
      totalFiles: offer.files.length,
      totalBytes: offer.totalBytes,
      transferredBytes: status == 'completed' ? offer.totalBytes : 0,
      createdAt: createdAt,
      completedAt:
          terminal ? DateTime.now().millisecondsSinceEpoch ~/ 1000 : null,
      errorCode: errorCode,
    )));
  }

  void _setPeer(String deviceId, PeerConnectionView peer) {
    if (!mounted) return;
    final peers = Map<String, PeerConnectionView>.from(state.peers)
      ..[deviceId] = peer;
    state = state.copyWith(peers: peers);
  }

  void _setPeerFields(
    String deviceId, {
    MultiConnectionStatus? status,
    String? errorMessage,
    bool clearError = false,
    bool? sessionExpired,
    bool clearOffers = false,
  }) {
    final peer = state.peer(deviceId);
    if (peer == null) return;
    _setPeer(
      deviceId,
      peer.copyWith(
        status: status,
        errorMessage: errorMessage,
        clearError: clearError,
        sessionExpired: sessionExpired,
        incomingOffers: clearOffers ? const [] : null,
      ),
    );
  }

  void _disposeRuntime(String deviceId) {
    _runtimes.remove(deviceId)?.dispose();
  }

  static Future<void> _cleanupPickerCopies(List<String> filePaths) async {
    for (final path in filePaths) {
      if (!path.contains('fastdrop_upload')) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best effort. The OS may reclaim the app-private copy later.
      }
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

final multiDeviceConnectionProvider = StateNotifierProvider<
    MultiDeviceConnectionNotifier, MultiDeviceConnectionState>((ref) {
  return MultiDeviceConnectionNotifier(ref);
});
