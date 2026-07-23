import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/network/ws_client.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/features/transfer/transfer_service.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Immutable state for one transfer item in the list.
class TransferItemState {
  const TransferItemState({
    required this.fileName,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.speed,
    required this.status,
    this.errorMessage,
  });

  final String fileName;
  final int bytesTransferred;
  final int totalBytes;
  final int speed;
  final String status;
  final String? errorMessage;

  TransferItemState copyWith({
    String? fileName,
    int? bytesTransferred,
    int? totalBytes,
    int? speed,
    String? status,
    String? errorMessage,
  }) {
    return TransferItemState(
      fileName: fileName ?? this.fileName,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      totalBytes: totalBytes ?? this.totalBytes,
      speed: speed ?? this.speed,
      status: status ?? this.status,
      errorMessage: errorMessage,
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

  TransferScreenState copyWith({
    Map<String, TransferItemState>? transfers,
    Set<String>? currentBatchKeys,
    List<TransferHistoryBatch>? history,
    String? currentPeerName,
    bool? serviceReady,
  }) {
    return TransferScreenState(
      transfers: transfers ?? this.transfers,
      currentBatchKeys: currentBatchKeys ?? this.currentBatchKeys,
      history: history ?? this.history,
      currentPeerName: currentPeerName ?? this.currentPeerName,
      serviceReady: serviceReady ?? this.serviceReady,
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
    _tryStartUpload();
  }

  /// Move every key in `currentBatchKeys` into a new HistoryBatch and
  /// clear the current set. The items themselves stay in
  /// `state.transfers` so any in-flight progress updates still land.
  void archiveCurrentToHistory() {
    if (state.currentBatchKeys.isEmpty) return;
    final batch = TransferHistoryBatch(
      peerName: state.currentPeerName ?? 'PC',
      direction: '→',
      archivedAt: DateTime.now(),
      itemKeys: Set<String>.from(state.currentBatchKeys),
    );
    state = state.copyWith(
      currentBatchKeys: <String>{},
      history: [...state.history, batch],
    );
  }

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

  void _onProgress(String transferId, String fileId, TransferProgress progress) {
    if (!mounted) return;
    final key = '$transferId::$fileId';
    final existing = state.transfers[key];
    final updated = Map<String, TransferItemState>.from(state.transfers);
    updated[key] = TransferItemState(
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
        updated[key] = updated[key]!.copyWith(
          status: status,
          errorMessage: errorMessage,
        );
      }
    }
    state = state.copyWith(transfers: updated);
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

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final transferScreenProvider =
    StateNotifierProvider<TransferScreenNotifier, TransferScreenState>((ref) {
  return TransferScreenNotifier(ref);
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(transferScreenProvider.notifier).init();
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
        if (paths.isNotEmpty) {
          ref.read(transferScreenProvider.notifier).setPendingFiles(paths);
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
      ref.read(transferScreenProvider.notifier).archiveCurrentToHistory();
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
    final historyBatches = state.history.reversed.toList(); // newest first

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
        actions: [
          if (currentEntries.any((e) => e.value.status == 'transferring'))
            IconButton(
              icon: const Icon(Icons.cancel_outlined),
              tooltip: 'Cancel all',
              onPressed: notifier.cancelAllActive,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (currentEntries.isEmpty)
            _buildEmptyState(theme)
          else
            ...currentEntries.map(
              (e) => _buildTransferCard(theme, notifier, e.key, e.value),
            ),

          if (state.history.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildHistorySection(theme, historyBatches, state.transfers),
          ],
        ],
      ),
    );
  }

  // -- Sections ---------------------------------------------------------------

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
              'No active transfers.',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySection(
    ThemeData theme,
    List<TransferHistoryBatch> batches,
    Map<String, TransferItemState> transfers,
  ) {
    return ExpansionTile(
      title: Text(
        '历史 (${batches.length})',
        style: theme.textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
      initiallyExpanded: false,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: batches
          .map((b) => _buildHistoryBatchCard(theme, b, transfers))
          .toList(),
    );
  }

  Widget _buildHistoryBatchCard(
    ThemeData theme,
    TransferHistoryBatch batch,
    Map<String, TransferItemState> transfers,
  ) {
    final items = batch.itemKeys
        .map((k) => transfers[k])
        .whereType<TransferItemState>()
        .toList();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Direction + peer name header.
          Row(
            children: [
              Icon(
                batch.direction == '→'
                    ? Icons.arrow_forward_rounded
                    : Icons.arrow_back_rounded,
                size: 18,
                color: batch.direction == '→' ? Colors.blue : Colors.green,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  batch.peerName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatArchiveTime(batch.archivedAt),
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ],
          ),
          const Divider(height: 12),
          ...items.map((item) => _buildHistoryItemRow(theme, item)),
        ],
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
    TransferScreenNotifier notifier,
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
                  child: Text(
                    item.fileName,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                        label: const Text('Pause'),
                      ),
                    if (item.status == 'paused')
                      TextButton.icon(
                        onPressed: () => notifier.resumeTransfer(key),
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Resume'),
                      ),
                    TextButton.icon(
                      onPressed: () => notifier.cancelTransfer(key),
                      icon: const Icon(Icons.cancel, size: 18),
                      label: const Text('Cancel'),
                      style:
                          TextButton.styleFrom(foregroundColor: Colors.red),
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
                    if (item.errorMessage != null)
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
                    TextButton.icon(
                      onPressed: () {
                        final transferId = key.split('::').first;
                        notifier.retryTransfer(transferId);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Transfer cancelled. Reselect files to retry.'),
                          ),
                        );
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Retry'),
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
