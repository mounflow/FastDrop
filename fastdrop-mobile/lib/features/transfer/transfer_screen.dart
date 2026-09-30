import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/app/routes.dart';
import 'package:fastdrop_mobile/core/errors/app_error.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/features/devices/multi_device_connection.dart';
import 'package:fastdrop_mobile/features/transfer/transfer_service.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:fastdrop_mobile/shared/widgets/app_navigation_bar.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Immutable state for one transfer item in the list.
class TransferItemState {
  const TransferItemState({
    required this.deviceId,
    required this.transferId,
    required this.peerName,
    required this.fileName,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.speed,
    required this.status,
    this.errorMessage,
    this.errorCode,
  });

  final String deviceId;
  final String transferId;
  final String peerName;
  final String fileName;
  final int bytesTransferred;
  final int totalBytes;
  final int speed;
  final String status;
  final String? errorMessage;
  final String? errorCode;

  TransferItemState copyWith({
    String? deviceId,
    String? transferId,
    String? peerName,
    String? fileName,
    int? bytesTransferred,
    int? totalBytes,
    int? speed,
    String? status,
    String? errorMessage,
    String? errorCode,
  }) {
    return TransferItemState(
      deviceId: deviceId ?? this.deviceId,
      transferId: transferId ?? this.transferId,
      peerName: peerName ?? this.peerName,
      fileName: fileName ?? this.fileName,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      totalBytes: totalBytes ?? this.totalBytes,
      speed: speed ?? this.speed,
      status: status ?? this.status,
      errorMessage: errorMessage,
      errorCode: errorCode,
    );
  }
}

/// 一次发送批次的任务级状态（此前 69 个文件在传输页是 69 张独立卡片，
/// 没有"任务"视图——用户反馈：应该是一个任务，能看到准备/传输/结束与
/// 21/69 式的文件数进度）。
///
/// 生命周期：preparing（搬迁/哈希）→ transferring（显示当前文件名）→
/// completed / failed / cancelled。
class ActiveUploadBatch {
  const ActiveUploadBatch({
    required this.totalFiles,
    required this.status,
    this.completedFiles = 0,
    this.failedFiles = 0,
    this.currentFileName,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.errorMessage,
  });

  final int totalFiles;
  final int completedFiles;
  final int failedFiles;
  final String? currentFileName;
  final int transferredBytes;
  final int totalBytes;
  final String status;
  final String? errorMessage;

  ActiveUploadBatch copyWith({
    int? completedFiles,
    int? failedFiles,
    String? currentFileName,
    int? transferredBytes,
    int? totalBytes,
    String? status,
    String? errorMessage,
  }) {
    return ActiveUploadBatch(
      totalFiles: totalFiles,
      completedFiles: completedFiles ?? this.completedFiles,
      failedFiles: failedFiles ?? this.failedFiles,
      currentFileName: currentFileName ?? this.currentFileName,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// A batch of transfer items archived from the "current" view.
///
/// Each batch corresponds to one visit to TransferScreen with files to
/// send (or one archive-on-leave). Direction is `'→'` for outgoing
/// (phone → PC) in Phase 1; the field exists so future incoming-side
/// integration can reuse the same UI without reworking the data model.
class TransferHistoryBatch {
  const TransferHistoryBatch({
    required this.peerName,
    required this.direction,
    required this.archivedAt,
    required this.itemKeys,
  });

  final String peerName;
  final String direction; // '→' outgoing, '←' incoming
  final DateTime archivedAt;
  final Set<String> itemKeys;
}

class TransferScreenState {
  const TransferScreenState({
    this.transfers = const {},
    this.currentBatchKeys = const <String>{},
    this.history = const [],
    this.currentPeerName,
    this.serviceReady = false,
    this.activeBatch,
  });

  /// All transfer items, keyed by `"transferId::fileId"`. Items stay
  /// here for the app's lifetime so progress updates that fire after
  /// the user has left the screen keep landing on the right entry.
  /// Whether an item shows in "Current" or "History" is decided by
  /// whether its key is in [currentBatchKeys] or in some
  /// [TransferHistoryBatch.itemKeys].
  final Map<String, TransferItemState> transfers;
  final Set<String> currentBatchKeys;
  final List<TransferHistoryBatch> history;
  final String? currentPeerName;
  final bool serviceReady;

  /// 当前发送批次的任务级状态（一次选择 = 一个任务卡片）。
  final ActiveUploadBatch? activeBatch;

  TransferScreenState copyWith({
    Map<String, TransferItemState>? transfers,
    Set<String>? currentBatchKeys,
    List<TransferHistoryBatch>? history,
    String? currentPeerName,
    bool? serviceReady,
    ActiveUploadBatch? activeBatch,
  }) {
    return TransferScreenState(
      transfers: transfers ?? this.transfers,
      currentBatchKeys: currentBatchKeys ?? this.currentBatchKeys,
      history: history ?? this.history,
      currentPeerName: currentPeerName ?? this.currentPeerName,
      serviceReady: serviceReady ?? this.serviceReady,
      activeBatch: activeBatch ?? this.activeBatch,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class TransferScreenNotifier extends StateNotifier<TransferScreenState> {
  TransferScreenNotifier(this._ref) : super(const TransferScreenState());

  final Ref _ref;

  TransferService? _service;
  List<String>? _pendingFilePaths;

  /// Initialise the transfer service using the **shared** HTTP / WS
  /// clients that [DevicesScreen] already configured and connected.
  ///
  /// Falls back to loading the session from disk only when the shared
  /// clients have no session (e.g. the user deep-linked into this
  /// screen before visiting DevicesScreen).
  Future<void> init() async {
    if (state.serviceReady) return;

    final httpClient = _ref.read(httpClientProvider);
    final wsClient = _ref.read(wsClientProvider);

    if (!httpClient.hasSession) {
      // Shared clients not configured yet — fall back to disk.
      final store = SessionStore();
      final data = await store.loadSession();
      if (data == null) return;
      httpClient.baseUrl = data.serverBaseUrl;
      httpClient.setSession(data.sessionId, data.accessToken);
      wsClient.baseUrl = data.serverBaseUrl;
      wsClient.setSession(data.sessionId, data.accessToken);
      try {
        await wsClient.connect();
      } catch (_) {
        // Non-fatal: transfers still work via HTTP.
      }
    }

    _service = TransferService(
      httpClient: httpClient,
      wsClient: wsClient,
      onProgress: _onProgress,
      onStateChange: _onStateChange,
    );

    // Resolve the peer name for display.
    String peerName = 'PC';
    try {
      final device = await _ref.read(deviceStoreProvider).getActiveDevice();
      if (device != null) peerName = device.name;
    } catch (_) {}

    if (mounted) {
      state = state.copyWith(
        serviceReady: true,
        currentPeerName: peerName,
      );
    }

    _tryStartUpload();
  }

  /// Queue file paths for upload (called from the screen when route args arrive).
  void setPendingFiles(List<String> paths) {
    if (paths.isEmpty) return;
    // Snapshot any existing "current" batch into history so the new
    // batch starts with a clean slate. Belt-and-suspenders for the
    // archive-on-leave path.
    archiveCurrentToHistory();
    _pendingFilePaths = paths;
    // 立即创建批次任务卡片（preparing）——用户点完发送马上有反馈，
    // 不再等到哈希/上传开始才出现（用户反馈：传输页迟迟没反应）。
    if (mounted) {
      state = state.copyWith(
        activeBatch: ActiveUploadBatch(
          totalFiles: paths.length,
          status: 'preparing',
        ),
      );
    }
    _tryStartUpload();
  }

  /// Move every key in `currentBatchKeys` into a new HistoryBatch and
  /// clear the current set. The items themselves stay in
  /// `state.transfers` so any in-flight progress updates still land.
  /// 归档规则（问题 2/3 修复）：只归档**已终态**的条目；进行中的条目
  /// 留在"当前"继续展示——反复进出页面不再产生重复的历史批次，
  /// 未完成的传输也不会出现在历史里。批次任务卡片：非终态保留
  /// （继续展示进度），终态清除——下一批发送会创建新卡片。
  void archiveCurrentToHistory() {
    final batch = state.activeBatch;
    final terminalKeys = state.currentBatchKeys
        .where((key) => _isTerminalItemStatus(state.transfers[key]?.status))
        .toSet();
    final keepBatch = batch != null && !_isTerminalBatchStatus(batch);
    if (terminalKeys.isEmpty && !keepBatch) {
      // 没有可归档的内容：重置为干净状态（清掉空批次视图）。
      state = TransferScreenState(
        transfers: state.transfers,
        currentPeerName: state.currentPeerName,
        serviceReady: state.serviceReady,
      );
      return;
    }
    if (terminalKeys.isNotEmpty) {
      state = state.copyWith(
        currentBatchKeys: state.currentBatchKeys.difference(terminalKeys),
        history: [
          ...state.history,
          TransferHistoryBatch(
            peerName: state.currentPeerName ?? 'PC',
            direction: '→',
            archivedAt: DateTime.now(),
            itemKeys: terminalKeys,
          ),
        ],
      );
    }
    // 终态批次任务卡片保留展示（"已完成 N/N"汇总），下一批发送时被
    // setPendingFiles 创建的新批次替换——用户要求的"一个任务"视图
    // 在完成后依然成立。
  }

  static bool _isTerminalItemStatus(String? status) =>
      status == 'completed' || status == 'failed' || status == 'cancelled';

  static bool _isTerminalBatchStatus(ActiveUploadBatch? batch) =>
      batch == null ||
      batch.status == 'completed' ||
      batch.status == 'failed' ||
      batch.status == 'cancelled';

  void _tryStartUpload() {
    if (!state.serviceReady || _pendingFilePaths == null || _service == null) {
      return;
    }
    final paths = _pendingFilePaths!;
    _pendingFilePaths = null;

    _service!.uploadFiles(paths).catchError((Object e) {
      debugPrint('[TransferScreen] upload error: $e');
      // Surface the failure in the UI so the user knows the send failed.
      if (!mounted) return;
      final key = 'failed::${DateTime.now().millisecondsSinceEpoch}';
      final names = paths.map((p) => p.split('/').last.split('\\').last);
      final updated = Map<String, TransferItemState>.from(state.transfers);
      updated[key] = TransferItemState(
        deviceId: '',
        transferId: key,
        peerName: state.currentPeerName ?? 'PC',
        fileName: names.length == 1 ? names.first : '${names.length} files',
        bytesTransferred: 0,
        totalBytes: 0,
        speed: 0,
        status: 'failed',
        errorMessage: e.toString(),
      );
      state = state.copyWith(
        transfers: updated,
        currentBatchKeys: {...state.currentBatchKeys, key},
      );
    });
  }

  void _onProgress(
      String transferId, String fileId, TransferProgress progress) {
    if (!mounted) return;
    final key = '$transferId::$fileId';
    final existing = state.transfers[key];
    final updated = Map<String, TransferItemState>.from(state.transfers);
    updated[key] = TransferItemState(
      deviceId: '',
      transferId: transferId,
      peerName: state.currentPeerName ?? 'PC',
      fileName: progress.fileName ?? existing?.fileName ?? fileId,
      bytesTransferred: progress.bytesTransferred,
      totalBytes: progress.totalBytes,
      speed: progress.speed ?? 0,
      status: progress.status ?? 'transferring',
    );
    // Promote the key into the current batch if it's not already there
    // (new items added directly to history would otherwise vanish from
    // the UI — keep new items current by default).
    Set<String>? newKeys;
    if (!state.currentBatchKeys.contains(key)) {
      newKeys = Set<String>.from(state.currentBatchKeys)..add(key);
    }
    state = state.copyWith(transfers: updated, currentBatchKeys: newKeys);
    _refreshBatchFromItems(updated, currentFileName: progress.fileName ?? '');
  }

  /// 从逐文件条目聚合批次任务状态（字节数/完成数/当前文件）。
  void _refreshBatchFromItems(Map<String, TransferItemState> transfers,
      {String? currentFileName}) {
    final batch = state.activeBatch;
    if (batch == null) return;
    var transferred = 0;
    var total = 0;
    var completed = 0;
    var failed = 0;
    String? currentFile;
    for (final key in state.currentBatchKeys) {
      final item = transfers[key];
      if (item == null) continue;
      transferred += item.bytesTransferred;
      total += item.totalBytes;
      if (item.status == 'completed') completed++;
      if (item.status == 'failed') failed++;
      if (item.status == 'transferring') currentFile ??= item.fileName;
    }
    state = state.copyWith(
      activeBatch: batch.copyWith(
        transferredBytes: transferred,
        totalBytes: total,
        completedFiles: completed,
        failedFiles: failed,
        currentFileName: currentFileName ?? currentFile,
      ),
    );
  }

  void _onStateChange(
    String transferId,
    String status, {
    String? errorCode,
    String? errorMessage,
  }) {
    if (!mounted) return;
    final updated = Map<String, TransferItemState>.from(state.transfers);
    for (final key in updated.keys) {
      if (key.startsWith('$transferId::')) {
        // 整批改写 failed 时跳过已完成的行（M13）：部分失败场景下
        // 已成功文件的结果不能被批次级失败状态覆盖。
        if (status == 'failed' && updated[key]!.status == 'completed') {
          continue;
        }
        updated[key] = updated[key]!.copyWith(
          status: status,
          errorMessage: errorMessage,
          errorCode: errorCode,
        );
      }
    }
    // 批次任务卡片状态同步（21/69 式进度承载在这里）。
    final batch = state.activeBatch;
    ActiveUploadBatch? newBatch;
    if (batch != null) {
      if (status == 'completed') {
        newBatch = batch.copyWith(
          status: 'completed',
          completedFiles: batch.totalFiles,
          transferredBytes: batch.totalBytes,
        );
      } else if (status == 'failed') {
        newBatch = batch.copyWith(status: 'failed', errorMessage: errorMessage);
      } else if (status == 'cancelled') {
        newBatch = batch.copyWith(status: 'cancelled');
      } else {
        newBatch = batch.copyWith(status: status);
      }
    }
    state = state.copyWith(transfers: updated, activeBatch: newBatch);
    _refreshBatchFromItems(updated);
  }

  Future<void> cancelTransfer(String itemKey) async {
    final transferId = itemKey.split('::').first;
    await _service?.cancelTransfer(transferId);
  }

  void pauseTransfer(String itemKey) {
    final transferId = itemKey.split('::').first;
    _service?.wsClient?.send({
      'version': 1,
      'type': 'transfer.pause',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'transferId': transferId},
    });
    final updated = Map<String, TransferItemState>.from(state.transfers);
    for (final key in updated.keys) {
      if (key.startsWith('$transferId::')) {
        updated[key] = updated[key]!.copyWith(status: 'paused');
      }
    }
    state = state.copyWith(transfers: updated);
  }

  void resumeTransfer(String itemKey) {
    final transferId = itemKey.split('::').first;
    _service?.wsClient?.send({
      'version': 1,
      'type': 'transfer.resume',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'transferId': transferId},
    });
    final updated = Map<String, TransferItemState>.from(state.transfers);
    for (final key in updated.keys) {
      if (key.startsWith('$transferId::')) {
        updated[key] = updated[key]!.copyWith(status: 'transferring');
      }
    }
    state = state.copyWith(transfers: updated);
  }

  Future<void> cancelAllActive() async {
    final transferIds = <String>{};
    for (final key in state.currentBatchKeys) {
      transferIds.add(key.split('::').first);
    }
    for (final id in transferIds) {
      await _service?.cancelTransfer(id);
    }
  }

  /// Drop the failed transfer from the current view. User then
  /// re-selects files to retry.
  void retryTransfer(String transferId) {
    final updated = Map<String, TransferItemState>.from(state.transfers);
    updated.removeWhere((key, _) => key.startsWith('$transferId::'));
    final newKeys = state.currentBatchKeys
        .where((k) => !k.startsWith('$transferId::'))
        .toSet();
    state = state.copyWith(transfers: updated, currentBatchKeys: newKeys);
  }

  @override
  void dispose() {
    // Only dispose the TransferService (cancels in-flight uploads).
    // The HTTP and WS clients are shared providers — do NOT dispose them
    // here; DeviceConnectionNotifier owns their lifecycle.
    _service?.dispose();
    super.dispose();
  }
}

/// M:N transfer presenter. Connection and transfer lifecycles belong to the
/// multi-device pool, while this notifier only projects tagged progress into
/// the screen.
class MultiTransferScreenNotifier extends StateNotifier<TransferScreenState> {
  MultiTransferScreenNotifier(this._ref) : super(const TransferScreenState());

  final Ref _ref;
  List<String>? _pendingFilePaths;
  List<String>? _pendingDeviceIds;

  Future<void> init() async {
    if (state.serviceReady) return;
    state = state.copyWith(serviceReady: true);
    _tryStartUpload();
  }

  void setPendingFiles(List<String> paths, List<String> deviceIds) {
    if (paths.isEmpty || deviceIds.isEmpty) return;
    archiveCurrentToHistory();
    _pendingFilePaths = List<String>.from(paths);
    _pendingDeviceIds = List<String>.from(deviceIds);
    final pool = _ref.read(multiDeviceConnectionProvider);
    final names = deviceIds
        .map((id) => pool.peer(id)?.device.name)
        .whereType<String>()
        .toList();
    // 立即创建批次任务卡片（preparing）——用户点完发送马上有反馈。
    state = state.copyWith(
      currentPeerName: names.isEmpty ? '多个设备' : names.join('、'),
      activeBatch: ActiveUploadBatch(
        totalFiles: paths.length,
        status: 'preparing',
      ),
    );
    _tryStartUpload();
  }

  void archiveCurrentToHistory() {
    if (state.currentBatchKeys.isEmpty) return;
    state = state.copyWith(
      currentBatchKeys: <String>{},
      history: [
        ...state.history,
        TransferHistoryBatch(
          peerName: state.currentPeerName ?? '多个设备',
          direction: '→',
          archivedAt: DateTime.now(),
          itemKeys: Set<String>.from(state.currentBatchKeys),
        ),
      ],
    );
  }

  void _tryStartUpload() {
    if (!state.serviceReady ||
        _pendingFilePaths == null ||
        _pendingDeviceIds == null) {
      return;
    }
    final paths = _pendingFilePaths!;
    final deviceIds = _pendingDeviceIds!;
    _pendingFilePaths = null;
    _pendingDeviceIds = null;

    _ref
        .read(multiDeviceConnectionProvider.notifier)
        .uploadFilesToDevices(
          deviceIds: deviceIds,
          filePaths: paths,
          onProgress: _onProgress,
          onStateChange: _onStateChange,
        )
        .catchError((Object error) {
      debugPrint('[MultiTransferScreen] fan-out error: $error');
      if (!mounted) return;
      // Per-peer state callbacks normally surface the exact failure. This
      // fallback covers errors that happen before a transfer ID is allocated.
      final hasFailure = state.currentBatchKeys.any(
        (key) => state.transfers[key]?.status == 'failed',
      );
      if (hasFailure) return;
      final key = 'fanout-failed::${DateTime.now().microsecondsSinceEpoch}';
      final updated = Map<String, TransferItemState>.from(state.transfers)
        ..[key] = TransferItemState(
          deviceId: '',
          transferId: key,
          peerName: state.currentPeerName ?? '多个设备',
          fileName: paths.length == 1
              ? paths.first.split('/').last.split('\\').last
              : '${paths.length} files',
          bytesTransferred: 0,
          totalBytes: 0,
          speed: 0,
          status: 'failed',
          errorMessage: error.toString(),
        );
      state = state.copyWith(
        transfers: updated,
        currentBatchKeys: {...state.currentBatchKeys, key},
      );
    });
  }

  void _onProgress(String deviceId, String transferId, String fileId,
      TransferProgress progress) {
    if (!mounted) return;
    final key = '$deviceId::$transferId::$fileId';
    final existing = state.transfers[key];
    final peerName =
        _ref.read(multiDeviceConnectionProvider).peer(deviceId)?.device.name ??
            deviceId;
    final updated = Map<String, TransferItemState>.from(state.transfers)
      ..[key] = TransferItemState(
        deviceId: deviceId,
        transferId: transferId,
        peerName: peerName,
        fileName: progress.fileName ?? existing?.fileName ?? fileId,
        bytesTransferred: progress.bytesTransferred,
        totalBytes: progress.totalBytes,
        speed: progress.speed ?? 0,
        status: progress.status ?? 'transferring',
      );
    // 批次聚合：字节数/当前文件名实时更新到任务卡片。
    final batch = state.activeBatch;
    ActiveUploadBatch? newBatch;
    if (batch != null) {
      var transferred = 0;
      for (final item in updated.values) {
        transferred += item.bytesTransferred;
      }
      newBatch = batch.copyWith(
        transferredBytes: transferred,
        currentFileName: progress.fileName ?? batch.currentFileName,
      );
    }    state = state.copyWith(
      transfers: updated,
      currentBatchKeys: {...state.currentBatchKeys, key},
      activeBatch: newBatch ?? state.activeBatch,
    );
  }

  void _onStateChange(
    String deviceId,
    String transferId,
    String status, {
    String? errorCode,
    String? errorMessage,
  }) {
    if (!mounted) return;
    final updated = Map<String, TransferItemState>.from(state.transfers);
    var matched = false;
    for (final entry in updated.entries.toList()) {
      if (entry.value.deviceId == deviceId &&
          entry.value.transferId == transferId) {
        // 整批改写 failed 时跳过已完成的行（M13）；只要该批次存在行就算
        // matched，避免落入下方合成失败行的分支。
        if (status == 'failed' && entry.value.status == 'completed') {
          matched = true;
          continue;
        }
        matched = true;
        updated[entry.key] = entry.value.copyWith(
          status: status,
          errorMessage: errorMessage,
          errorCode: errorCode,
        );
      }
    }
    if (!matched && status == 'failed') {
      final peerName = _ref
              .read(multiDeviceConnectionProvider)
              .peer(deviceId)
              ?.device
              .name ??
          deviceId;
      final key = '$deviceId::$transferId::failed';
      updated[key] = TransferItemState(
        deviceId: deviceId,
        transferId: transferId,
        peerName: peerName,
        fileName: '发送失败',
        bytesTransferred: 0,
        totalBytes: 0,
        speed: 0,
        status: 'failed',
        errorMessage: errorMessage ?? errorCode,
        errorCode: errorCode,
      );
      state = state.copyWith(
        transfers: updated,
        currentBatchKeys: {...state.currentBatchKeys, key},
      );
      return;
    }
    state = state.copyWith(transfers: updated);
    _refreshBatchFromItems(updated);
  }

  /// 从逐文件条目聚合批次任务状态（字节数/完成数/失败数/当前文件）。
  void _refreshBatchFromItems(Map<String, TransferItemState> transfers,
      {String? status, String? currentFileName}) {
    final batch = state.activeBatch;
    if (batch == null) return;
    var transferred = 0;
    var total = 0;
    var completed = 0;
    var failed = 0;
    String? currentFile;
    for (final key in state.currentBatchKeys) {
      final item = transfers[key];
      if (item == null) continue;
      transferred += item.bytesTransferred;
      total += item.totalBytes;
      if (item.status == 'completed') completed++;
      if (item.status == 'failed') failed++;
      if (item.status == 'transferring') currentFile ??= item.fileName;
    }
    state = state.copyWith(
      activeBatch: batch.copyWith(
        transferredBytes: transferred,
        totalBytes: total,
        completedFiles: completed,
        failedFiles: failed,
        currentFileName: currentFileName ?? currentFile,
        status: status ?? batch.status,
      ),
    );
  }

  Future<void> cancelTransfer(String itemKey) async {
    final item = state.transfers[itemKey];
    if (item == null || item.deviceId.isEmpty) return;
    await _ref
        .read(multiDeviceConnectionProvider.notifier)
        .cancelTransfer(item.deviceId, item.transferId);
  }

  void pauseTransfer(String itemKey) {
    final item = state.transfers[itemKey];
    if (item == null || item.deviceId.isEmpty) return;
    _ref
        .read(multiDeviceConnectionProvider.notifier)
        .pauseTransfer(item.deviceId, item.transferId);
    _setBatchStatus(item.deviceId, item.transferId, 'paused');
  }

  void resumeTransfer(String itemKey) {
    final item = state.transfers[itemKey];
    if (item == null || item.deviceId.isEmpty) return;
    _ref
        .read(multiDeviceConnectionProvider.notifier)
        .resumeTransfer(item.deviceId, item.transferId);
    _setBatchStatus(item.deviceId, item.transferId, 'transferring');
  }

  Future<void> cancelAllActive() async {
    final batches = <String, TransferItemState>{};
    for (final key in state.currentBatchKeys) {
      final item = state.transfers[key];
      if (item != null && item.deviceId.isNotEmpty) {
        batches['${item.deviceId}::${item.transferId}'] = item;
      }
    }
    for (final item in batches.values) {
      await _ref
          .read(multiDeviceConnectionProvider.notifier)
          .cancelTransfer(item.deviceId, item.transferId);
    }
  }

  void retryTransfer(String itemKey) {
    final item = state.transfers[itemKey];
    if (item == null) return;
    final updated = Map<String, TransferItemState>.from(state.transfers)
      ..removeWhere((_, value) =>
          value.deviceId == item.deviceId &&
          value.transferId == item.transferId);
    final keys =
        state.currentBatchKeys.where((key) => updated.containsKey(key)).toSet();
    state = state.copyWith(transfers: updated, currentBatchKeys: keys);
  }

  void _setBatchStatus(String deviceId, String transferId, String status) {
    final updated = Map<String, TransferItemState>.from(state.transfers);
    for (final entry in updated.entries.toList()) {
      if (entry.value.deviceId == deviceId &&
          entry.value.transferId == transferId) {
        updated[entry.key] = entry.value.copyWith(status: status);
      }
    }
    state = state.copyWith(transfers: updated);
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final transferScreenProvider =
    StateNotifierProvider<MultiTransferScreenNotifier, TransferScreenState>(
        (ref) {
  return MultiTransferScreenNotifier(ref);
});

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Live transfer progress with a collapsible history section.
///
/// On entry with file paths, only the current batch is shown. Leaving
/// the screen archives that batch into history; the next visit shows
/// an empty current section with previous batches behind a ▶ toggle.
class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  bool _argsChecked = false;
  bool _archivedOnLeave = false;
  late final MultiTransferScreenNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(transferScreenProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifier.init();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_argsChecked) {
      _argsChecked = true;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map<String, dynamic> && args.containsKey('filePaths')) {
        final paths =
            (args['filePaths'] as List<dynamic>).cast<String>().toList();
        final deviceIds =
            (args['targetDeviceIds'] as List<dynamic>? ?? const [])
                .map((value) => value.toString())
                .toList();
        if (paths.isNotEmpty && deviceIds.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _notifier.setPendingFiles(paths, deviceIds);
          });
        }
      }
    }
  }

  @override
  void dispose() {
    // Move current items to history so the next visit shows them there
    // rather than re-appearing as "current" on a fresh navigation.
    if (!_archivedOnLeave) {
      _archivedOnLeave = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifier.archiveCurrentToHistory();
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(transferScreenProvider);
    final notifier = ref.read(transferScreenProvider.notifier);

    final currentEntries = state.transfers.entries
        .where((e) => state.currentBatchKeys.contains(e.key))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('传输'),
        actions: [
          // L15 配套：历史记录入口。完成的传输从"当前"归档到本地历史库后，
          // 这里是查看持久化记录（含"打开文件"）的唯一入口。
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '传输记录',
            onPressed: () => Navigator.of(context).pushNamed('/history'),
          ),
          if (currentEntries.any((e) => e.value.status == 'transferring'))
            IconButton(
              icon: const Icon(Icons.cancel_outlined),
              tooltip: 'Cancel all',
              onPressed: notifier.cancelAllActive,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          // 批次任务卡片：一次选择 = 一个任务（用户要求的 21/69 式视图）。
          if (state.activeBatch != null)
            _buildBatchCard(theme, state.activeBatch!, state.currentPeerName ?? 'PC')
          else if (currentEntries.isEmpty)
            _buildEmptyState(theme)
          else
            ...currentEntries.map(
              (e) => _buildTransferCard(theme, notifier, e.key, e.value),
            ),
          // 持久化传输记录统一在 HistoryScreen 查看（含手机→PC 的发送记录）。
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppRoutes.history),
              icon: const Icon(Icons.history),
              label: const Text('查看传输记录'),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const FastDropNavigationBar(currentIndex: 1),
    );
  }

  // -- Sections ---------------------------------------------------------------

  /// 批次任务卡片：一个任务展示整批状态（准备中/传输中/完成/失败）、
  /// 文件数进度（21/69）、当前文件名与字节进度。
  Widget _buildBatchCard(
      ThemeData theme, ActiveUploadBatch batch, String peerName) {
    const statusLabels = {
      'preparing': '准备中',
      'transferring': '传输中',
      'completed': '已完成',
      'failed': '失败',
      'cancelled': '已取消',
    };
    final statusLabel = statusLabels[batch.status] ?? batch.status;
    final statusColor = switch (batch.status) {
      'completed' => Colors.green,
      'failed' => Colors.red,
      'cancelled' => Colors.grey,
      _ => theme.colorScheme.primary,
    };
    final progress = batch.totalBytes > 0
        ? (batch.transferredBytes / batch.totalBytes).clamp(0.0, 1.0)
        : (batch.status == 'completed' ? 1.0 : 0.0);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '发送到 $peerName',
                style: theme.textTheme.titleMedium,
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${batch.completedFiles}/${batch.totalFiles} 个文件',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (batch.currentFileName != null &&
              batch.status == 'transferring') ...[
            const SizedBox(height: 4),
            Text(
              '正在传输：${batch.currentFileName}',
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: theme.dividerColor,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_formatBytes(batch.transferredBytes)} / ${_formatBytes(batch.totalBytes)}',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          if (batch.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              batch.errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_upload_outlined,
              size: 64,
              color: theme.colorScheme.primary.withOpacity(0.4),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无正在进行的传输',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryItemRow(ThemeData theme, TransferItemState item) {
    final color = _statusColor(item.status);
    final progress =
        item.totalBytes > 0 ? item.bytesTransferred / item.totalBytes : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(progress * 100).toStringAsFixed(0)}%',
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
          const SizedBox(width: 6),
          Icon(
            item.status == 'completed'
                ? Icons.check_circle
                : item.status == 'failed'
                    ? Icons.error_outline
                    : Icons.hourglass_top,
            size: 14,
            color: color,
          ),
        ],
      ),
    );
  }

  // -- Current transfer card --------------------------------------------------

  Widget _buildTransferCard(
    ThemeData theme,
    MultiTransferScreenNotifier notifier,
    String key,
    TransferItemState item,
  ) {
    final progress =
        item.totalBytes > 0 ? item.bytesTransferred / item.totalBytes : 0.0;
    final statusColor = _statusColor(item.status);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.fileName,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '发送到 ${item.peerName}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    item.status.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '${_formatBytes(item.bytesTransferred)} / ${_formatBytes(item.totalBytes)}',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (item.status == 'transferring' && item.speed > 0)
                  Text(
                    '${_formatBytes(item.speed)}/s',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (item.status == 'transferring' || item.status == 'paused')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (item.status == 'transferring')
                      TextButton.icon(
                        onPressed: () => notifier.pauseTransfer(key),
                        icon: const Icon(Icons.pause, size: 18),
                        label: const Text('暂停'),
                      ),
                    if (item.status == 'paused')
                      TextButton.icon(
                        onPressed: () => notifier.resumeTransfer(key),
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('继续'),
                      ),
                    TextButton.icon(
                      onPressed: () => notifier.cancelTransfer(key),
                      icon: const Icon(Icons.cancel, size: 18),
                      label: const Text('取消'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                  ],
                ),
              ),
            if (item.status == 'failed')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // 会话过期（L13）：重试无意义，固定文案引导重新配对。
                    if (item.errorCode == ErrorCodes.sessionExpired)
                      Expanded(
                        child: Text(
                          '会话已失效，请重新配对',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.red,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    else if (item.errorMessage != null)
                      Expanded(
                        child: Text(
                          item.errorMessage!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.red,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (item.errorCode == ErrorCodes.sessionExpired)
                      TextButton.icon(
                        onPressed: () {
                          Navigator.of(context)
                              .pushNamedAndRemoveUntil('/devices', (_) => false);
                        },
                        icon: const Icon(Icons.link, size: 18),
                        label: const Text('去重新配对'),
                      )
                    else
                      TextButton.icon(
                        onPressed: () {
                          notifier.retryTransfer(key);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Transfer cancelled. Reselect files to retry.'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Color _statusColor(String status) {
    switch (status) {
      case 'transferring':
        return Colors.blue;
      case 'paused':
        return Colors.orange;
      case 'verifying':
        return Colors.purple;
      case 'completed':
        return Colors.green;
      case 'cancelled':
        return Colors.grey;
      case 'failed':
        return Colors.red;
      case 'waiting_accept':
        return Colors.amber;
      case 'preparing':
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }

  String _formatArchiveTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${t.month}/${t.day} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
