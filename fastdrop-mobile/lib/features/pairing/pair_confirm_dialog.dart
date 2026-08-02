import 'package:fastdrop_mobile/core/server/pairing_handler.dart';
import 'package:fastdrop_mobile/core/server/pairing_providers.dart';
import 'package:fastdrop_mobile/core/server/server_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Watches for incoming pair requests and shows a confirmation dialog.
///
/// Place this widget once inside the MaterialApp builder so it can react
/// to server-side pair requests from any screen.  Because the builder
/// context sits *above* the Navigator, we need [navigatorKey] to obtain a
/// context that is *inside* the Navigator for [showDialog].
class PairConfirmDialogWatcher extends ConsumerStatefulWidget {
  const PairConfirmDialogWatcher({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<PairConfirmDialogWatcher> createState() =>
      _PairConfirmDialogWatcherState();
}

class _PairConfirmDialogWatcherState
    extends ConsumerState<PairConfirmDialogWatcher> {
  final Set<String> _shownRequestIds = {};

  @override
  Widget build(BuildContext context) {
    final requests = ref.watch(pendingPairRequestsProvider);

    for (final request in requests) {
      if (request.status == 'waiting_confirmation' &&
          !_shownRequestIds.contains(request.requestId)) {
        _shownRequestIds.add(request.requestId);
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _showDialog(request);
        });
      }
    }

    return widget.child;
  }

  void _showDialog(ServerPairRequest request) {
    // Use the navigator's overlay context — this is *inside* the Navigator
    // so Navigator.of will succeed.  The builder context itself is above
    // the Navigator and would throw if used with showDialog.
    final navContext = widget.navigatorKey.currentState?.overlay?.context;
    if (navContext == null) return;

    Navigator.of(navContext, rootNavigator: true).push(
      DialogRoute<void>(
        context: navContext,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.phonelink, size: 24),
              SizedBox(width: 8),
              Expanded(child: Text('配对请求')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '"${request.device.deviceName}" 请求与本机配对',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Text(
                '平台: ${request.device.platform}\n'
                '${request.viaDiscover ? '来源: mDNS 自动发现' : '来源: 扫码配对'}',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '接受后，该设备可以向本机发送文件。',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                ref
                    .read(fastdropServerProvider.notifier)
                    .rejectPairRequest(request.requestId);
                Navigator.of(ctx).pop();
              },
              child: const Text('拒绝'),
            ),
            FilledButton(
              onPressed: () {
                ref
                    .read(fastdropServerProvider.notifier)
                    .acceptPairRequest(request.requestId);
                Navigator.of(ctx).pop();
              },
              child: const Text('接受'),
            ),
          ],
        ),
      ),
    );
  }
}
