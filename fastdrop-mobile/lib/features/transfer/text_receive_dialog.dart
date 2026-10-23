import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/server/server_providers.dart';
import 'package:fastdrop_mobile/core/server/ws_server.dart';

/// Watches for incoming text messages (text.send) and shows a dialog with
/// the full text and a copy button. Text does not need an accept prompt —
/// it is inert content between already-paired devices.
///
/// Uses the same navigatorKey pattern as the other dialog watchers: the
/// watcher sits above the Navigator, so it must obtain a context *inside*
/// the Navigator to call showDialog.
class TextReceiveDialogWatcher extends ConsumerStatefulWidget {
  const TextReceiveDialogWatcher({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<TextReceiveDialogWatcher> createState() =>
      _TextReceiveDialogWatcherState();
}

class _TextReceiveDialogWatcherState
    extends ConsumerState<TextReceiveDialogWatcher> {
  final Set<String> _shownTextIds = {};

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(receivedTextsProvider);

    for (final message in messages) {
      if (!_shownTextIds.contains(message.textId)) {
        _shownTextIds.add(message.textId);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showDialog(message);
        });
      }
    }

    return widget.child;
  }

  void _showDialog(ServerTextMessage message) {
    final navContext = widget.navigatorKey.currentState?.overlay?.context;
    if (navContext == null) return;

    showDialog<void>(
      context: navContext,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.text_fields, size: 24),
            SizedBox(width: 8),
            Expanded(child: Text('收到文本')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.deviceName.isEmpty
                  ? '有设备发来一段文本'
                  : '${message.deviceName} 发来一段文本',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  message.text,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message.text));
              ScaffoldMessenger.of(navContext).showSnackBar(
                const SnackBar(content: Text('已复制到剪贴板')),
              );
              Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制'),
          ),
        ],
      ),
    ).whenComplete(() {
      ref.read(receivedTextsProvider.notifier).remove(message.textId);
    });
  }
}
