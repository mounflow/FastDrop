import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/network/ws_client.dart';
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

class TransferScreenState {
  const TransferScreenState({
    this.transfers = const {},
    this.serviceReady = false,
  });

  /// Transfer items keyed by "transferId::fileId".
  final Map<String, TransferItemState> transfers;
  final bool serviceReady;

  TransferScreenState copyWith({
    Map<String, TransferItemState>? transfers,
    bool? serviceReady,
  }) {
    return TransferScreenState(
      transfers: transfers ?? this.transfers,
      serviceReady: serviceReady ?? this.serviceReady,
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class TransferScreenNotifier extends StateNotifier<TransferScreenState> {
  TransferScreenNotifier() : super(const TransferScreenState());

  TransferService? _service;
  FastDropHttpClient? _httpClient;
  FastDropWsClient? _wsClient;
  List<String>? _pendingFilePaths;

  Future<void> init() async {
    if (state.serviceReady) return;

    final store = SessionStore();
    final data = await store.loadSession();
    if (data == null) return;

    final client = FastDropHttpClient(baseUrl: data.serverBaseUrl);
    client.setSession(data.sessionId, data.accessToken);
    _httpClient = client;

    final wsClient = FastDropWsClient();
    wsClient.baseUrl = data.serverBaseUrl;
    wsClient.setSession(data.sessionId, data.accessToken);
    // Connect the WS client so pause/resume/cancel messages actually reach
    // the server. Without this the client is created but never connected,
    // causing pause/resume to silently do nothing.
    try {
      await wsClient.connect();
    } catch (_) {
      // Non-fatal: transfers still work via HTTP; WS is for control messages.
    }
    _wsClient = wsClient;

    _service = TransferService(
      httpClient: client,
      wsClient: wsClient,
      onProgress: _onProgress,
      onStateChange: _onStateChange,
    );

    if (mounted) {
      state = state.copyWith(serviceReady: true);
    }

    _tryStartUpload();
  }

  /// Queue file paths for upload (called from the screen when route args arrive).
  void setPendingFiles(List<String> paths) {
    if (paths.isEmpty) return;
    _pendingFilePaths = paths;
    _tryStartUpload();
  }

  void _tryStartUpload() {
    if (!state.serviceReady || _pendingFilePaths == null || _service == null) {
      return;
    }
    final paths = _pendingFilePaths!;
    _pendingFilePaths = null;

    _service!.uploadFiles(paths).catchError((Object e) {
      debugPrint('[TransferScreen] upload error: $e');
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
    state = state.copyWith(transfers: updated);
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
    // Optimistic local update.
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
    for (final key in state.transfers.keys) {
      transferIds.add(key.split('::').first);
    }
    for (final id in transferIds) {
      await _service?.cancelTransfer(id);
    }
  }

  void retryTransfer(String transferId) {
    final updated = Map<String, TransferItemState>.from(state.transfers);
    updated.removeWhere((key, _) => key.startsWith('$transferId::'));
    state = state.copyWith(transfers: updated);
  }

  @override
  void dispose() {
    _service?.dispose();
    _httpClient?.dispose();
    _wsClient?.disconnect();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final transferScreenProvider =
    StateNotifierProvider<TransferScreenNotifier, TransferScreenState>((ref) {
  return TransferScreenNotifier();
});

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Displays live transfer progress for all active transfers.
///
/// Each transfer item shows filename, progress bar with percentage,
/// transfer speed (KB/s or MB/s), status, cancel button for active
/// transfers, and retry button for failed transfers.
class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  bool _argsChecked = false;

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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(transferScreenProvider);
    final notifier = ref.read(transferScreenProvider.notifier);
    final entries = state.transfers.entries.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
        actions: [
          if (entries.any((e) => e.value.status == 'transferring'))
            IconButton(
              icon: const Icon(Icons.cancel_outlined),
              tooltip: 'Cancel all',
              onPressed: notifier.cancelAllActive,
            ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
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
                        color: theme.colorScheme.onSurface.withOpacity(0.6)),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries.elementAt(index);
                return _buildTransferCard(theme, notifier, entry.key, entry.value);
              },
            ),
    );
  }

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
            // Header: filename + status badge.
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
            // Progress bar.
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
            // Stats row.
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
            // Action buttons.
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
