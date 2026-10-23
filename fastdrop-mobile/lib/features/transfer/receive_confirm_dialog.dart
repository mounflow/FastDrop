import 'dart:async';

import 'package:fastdrop_mobile/core/server/server_providers.dart';
import 'package:fastdrop_mobile/core/server/transfer_providers.dart';
import 'package:fastdrop_mobile/core/server/transfer_receiver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Watches for incoming transfer offers and shows a confirmation dialog.
///
/// Uses [navigatorKey] to get a context inside the Navigator (the builder
/// context is above the Navigator and cannot be used with showDialog).
class ReceiveConfirmDialogWatcher extends ConsumerStatefulWidget {
  const ReceiveConfirmDialogWatcher({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<ReceiveConfirmDialogWatcher> createState() =>
      _ReceiveConfirmDialogWatcherState();
}

class _ReceiveConfirmDialogWatcherState
    extends ConsumerState<ReceiveConfirmDialogWatcher> {
  final Set<String> _shownTransferIds = {};

  /// 确认超时：与发送端 2 分钟等待超时（multi_device_connection.dart 的
  /// _waitForTransferReady）对齐，超时未确认按拒绝处理，消除僵尸传输。
  static const _confirmTimeout = Duration(minutes: 2);

  @override
  Widget build(BuildContext context) {
    final transfers = ref.watch(incomingTransfersProvider);

    for (final transfer in transfers) {
      if (transfer.status == 'waiting_accept' &&
          !_shownTransferIds.contains(transfer.transferId)) {
        _shownTransferIds.add(transfer.transferId);
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _showDialog(transfer);
        });
      }
    }

    return widget.child;
  }

  void _showDialog(ServerTransfer transfer) {
    final navContext = widget.navigatorKey.currentState?.overlay?.context;
    if (navContext == null) return;

    final fileNames = transfer.files.map((f) => f.name).toList();
    final displayNames = fileNames.length <= 3
        ? fileNames.join('\n')
        : '${fileNames.take(3).join('\n')}\n... 还有 ${fileNames.length - 3} 个文件';

    final navigator = Navigator.of(navContext, rootNavigator: true);
    final route = DialogRoute<void>(
      context: navContext,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.file_download, size: 24),
            SizedBox(width: 8),
            Expanded(child: Text('接收文件')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '有设备要向本机发送 ${transfer.totalFiles} 个文件',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                child: Text(
                  displayNames,
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '总大小: ${_formatBytes(transfer.totalBytes)}',
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref
                  .read(fastdropServerProvider.notifier)
                  .rejectTransfer(transfer.transferId);
              Navigator.of(ctx).pop();
            },
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(fastdropServerProvider.notifier)
                  .acceptTransfer(transfer.transferId);
              Navigator.of(ctx).pop();
            },
            child: const Text('接收'),
          ),
        ],
        ),
    );

    // 超时自动拒绝（M17）：先按拒绝处理（通知对端），再撤下仍挂着的对话框。
    final timeout = Timer(_confirmTimeout, () {
      ref
          .read(fastdropServerProvider.notifier)
          .rejectTransfer(transfer.transferId);
      if (route.navigator != null) {
        navigator.removeRoute(route);
      }
    });
    // 用户主动确认/拒绝后取消超时。
    route.popped.whenComplete(timeout.cancel);
    navigator.push(route);
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
