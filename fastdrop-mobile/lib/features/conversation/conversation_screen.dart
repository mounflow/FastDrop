import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/app/routes.dart';
import 'package:fastdrop_mobile/app/theme.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/storage/transfer_history_store.dart';
import 'package:fastdrop_mobile/features/devices/multi_device_connection.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';

/// 会话详情：与某台设备之间的传输往来（气泡流）+ 发送区。
///
/// 气泡表达的是「一次真实发生过的传输」，不是「消息」。FastDrop 是局域网
/// 直传、没有中转，所以设备离线时**直接禁用输入区**——绝不能做成看起来能发、
/// 实际发不出去的假队列（那比"仅接收"更伤信任）。
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({required this.device, super.key});

  final Device device;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final TextEditingController _text = TextEditingController();
  final TransferHistoryStore _store = TransferHistoryStore();
  List<TransferRow> _rows = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    List<TransferRow> rows;
    try {
      rows = await _store.load();
    } catch (e) {
      debugPrint('[Conversation] 加载传输历史失败: $e');
      rows = const [];
    }
    // 历史里 peerDeviceId 有时是 baseUrl、有时是 deviceId，两个键都认。
    final keys = {widget.device.id, widget.device.serverBaseUrl};
    final mine = rows.where((row) => keys.contains(row.peerDeviceId)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (!mounted) return;
    setState(() {
      _rows = mine;
      _loading = false;
    });
  }

  void _openFilePicker() {
    Navigator.of(context).pushNamed(
      AppRoutes.filePicker,
      arguments: {
        'initialDeviceIds': [widget.device.id],
      },
    );
  }

  void _send() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final ok = ref
        .read(multiDeviceConnectionProvider.notifier)
        .sendText(widget.device.id, text);
    if (!mounted) return;
    if (ok) {
      _text.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('文本已发出')));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('设备不在线，发送失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).extension<FastDropTokens>()!;
    final peer = ref.watch(multiDeviceConnectionProvider).peer(widget.device.id);
    final online = peer?.isConnected ?? false;
    final connecting =
        peer?.status == MultiConnectionStatus.connecting && !online;
    final statusLabel = online ? '在线' : (connecting ? '连接中…' : '离线');

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(
              child: Text(
                widget.device.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: online
                    ? tokens.successSoft
                    : connecting
                        ? tokens.warningSoft
                        : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppTheme.radiusPill),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  color: online
                      ? tokens.success
                      : connecting
                          ? tokens.warning
                          : scheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildBubbleArea()),
          _buildComposer(online),
        ],
      ),
    );
  }

  Widget _buildBubbleArea() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rows.isEmpty) {
      return Center(
        child: Text(
          '还没有传输记录',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = _rows[index];
        // 服务端记录的 direction 是"对端的视角"，client_to_server = 本机接收。
        final received = row.direction == 'client_to_server';
        return Align(
          alignment: received ? Alignment.centerLeft : Alignment.centerRight,
          child: _buildBubble(row, received),
        );
      },
    );
  }

  Widget _buildBubble(TransferRow row, bool received) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).extension<FastDropTokens>()!;
    final failed = row.status == 'failed' || row.status == 'cancelled';
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: received ? scheme.surface : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row.totalFiles} 个文件',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            '${_formatBytes(row.totalBytes)} · ${_formatTime(row.createdAt)}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            failed ? '失败' : (row.status == 'completed' ? '已完成' : '进行中'),
            style: TextStyle(
              color: failed ? tokens.danger : tokens.success,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(bool online) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            IconButton.filledTonal(
              onPressed: online ? _openFilePicker : null,
              icon: const Icon(Icons.attach_file_rounded),
              tooltip: '发送文件',
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _text,
                enabled: online,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: online ? '输入要发送的文本…' : '设备不在线，无法发送',
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusControl),
                  ),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: online ? _send : null,
              icon: Icon(Icons.send_rounded, color: online ? scheme.onPrimary : null),
              tooltip: '发送',
            ),
          ],
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  /// createdAt 是 Unix 秒。
  static String _formatTime(int seconds) {
    if (seconds <= 0) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.month)}/${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }
}
