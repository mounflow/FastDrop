import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/platform/background_receive_service.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/storage/transfer_history_store.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';

/// Displays historical transfers fetched from the backend via
/// `GET /api/v1/transfers`.
///
/// Supports filtering by status (all / completed / failed), tap-to-expand
/// details, and pull-to-refresh.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<TransferRow> _transfers = [];
  String _statusFilter = 'all';

  /// 方向筛选：all / sent（发送，手机→电脑）/ received（接收，电脑→手机）。
  String _directionFilter = 'all';
  bool _loading = true;
  String? _error;

  final List<FastDropHttpClient> _httpClients = [];
  final TransferHistoryStore _historyStore = TransferHistoryStore();
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    _initClientAndLoad();
    // Auto-refresh every 5 seconds while the screen is visible.
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) _loadTransfers();
    });
  }

  Future<void> _initClientAndLoad() async {
    final devices = await DeviceStore().loadDevices();
    for (final device in devices.where((device) => !device.isExpired)) {
      final client = FastDropHttpClient(baseUrl: device.serverBaseUrl)
        ..setSession(device.sessionId, device.accessToken);
      _httpClients.add(client);
    }

    await _loadTransfers();
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    for (final client in _httpClients) {
      client.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('传输记录'),
        actions: [
          IconButton(
            tooltip: '清空记录',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _transfers.isEmpty ? null : _onClearHistory,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDirectionBar(theme),
              _buildFilterBar(theme),
            ],
          ),
        ),
      ),
      body: _buildBody(theme),
    );
  }

  /// 方向筛选：全部 / 发送 / 接收（历史必须能一眼区分方向）。
  Widget _buildDirectionBar(ThemeData theme) {
    const options = [
      ('all', '全部', Icons.list_alt_rounded),
      ('sent', '发送', Icons.upload_rounded),
      ('received', '接收', Icons.download_rounded),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SegmentedButton<String>(
        segments: options
            .map((o) => ButtonSegment<String>(
                  value: o.$1,
                  label: Text(o.$2),
                  icon: Icon(o.$3, size: 16),
                ))
            .toList(),
        selected: {_directionFilter},
        showSelectedIcon: false,
        onSelectionChanged: (selection) {
          setState(() => _directionFilter = selection.first);
        },
      ),
    );
  }

  Widget _buildFilterBar(ThemeData theme) {
    const filters = [
      ('all', '全部状态'),
      ('completed', '已完成'),
      ('failed', '失败'),
      ('cancelled', '已取消'),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: filters.map((f) {
          final (value, label) = f;
          final selected = _statusFilter == value;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              label: Text(label),
              selected: selected,
              onSelected: (_) {
                setState(() => _statusFilter = value);
                _loadTransfers();
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadTransfers,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_transfers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history,
              size: 64,
              color: theme.colorScheme.primary.withOpacity(0.4),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无传输记录',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      );
    }

    // 方向筛选（发送/接收）在本地完成：两个方向的数据同源，无需重新拉取。
    final visible = _transfers.where((t) {
      if (_directionFilter == 'all') return true;
      final sent = t.direction == 'client_to_server';
      return _directionFilter == 'sent' ? sent : !sent;
    }).toList();

    if (visible.isEmpty) {
      return Center(
        child: Text(
          _directionFilter == 'sent' ? '没有发送记录' : '没有接收记录',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadTransfers,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          return _buildTransferTile(theme, visible[index]);
        },
      ),
    );
  }

  Widget _buildTransferTile(ThemeData theme, TransferRow transfer) {
    final statusColor = _statusColor(transfer.status);
    final sent = transfer.direction == 'client_to_server';
    final directionIcon = sent ? Icons.upload_rounded : Icons.download_rounded;
    final directionLabel = sent ? '发送' : '接收';
    final directionColor = sent ? const Color(0xFF2F6BFF) : const Color(0xFF17864B);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        leading: Icon(directionIcon, color: directionColor),
        title: Row(
          children: [
            // 方向徽标：历史列表必须一眼看出是发送还是接收。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: directionColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                directionLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: directionColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${transfer.totalFiles} 个文件',
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: Text(
          '${_formatDirectionPeer(sent)} · ${_formatDate(transfer.createdAt)}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _formatBytes(transfer.totalBytes),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _statusLabel(transfer.status),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                const SizedBox(height: 8),
                _detailRow('方向', sent ? '发送（本机 → 对方）' : '接收（对方 → 本机）'),
                _detailRow('状态', _statusLabel(transfer.status)),
                _detailRow('文件数', '${transfer.totalFiles}'),
                _detailRow('大小', _formatBytes(transfer.totalBytes)),
                _detailRow(
                  '进度',
                  '${_formatBytes(transfer.transferredBytes)} / ${_formatBytes(transfer.totalBytes)}',
                ),
                _detailRow('创建时间', _formatDate(transfer.createdAt)),
                if (transfer.completedAt != null)
                  _detailRow('完成时间', _formatDate(transfer.completedAt!)),
                if (transfer.errorCode != null)
                  _detailRow('错误码', transfer.errorCode!),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '任务 ID：${transfer.id}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ),
                if (transfer.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      transfer.errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.red,
                      ),
                    ),
                  ),
                if (transfer.savedPath != null &&
                    transfer.status == 'completed' &&
                    transfer.direction == 'server_to_client')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _openSavedFile(transfer.savedPath!),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('打开文件'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  /// 方向说明文案（副标题用；对端名称不在本机记录里，按方向描述即可）。
  static String _formatDirectionPeer(bool sent) =>
      sent ? '发送到电脑' : '来自电脑';

  /// 状态中文标签（列表与详情共用）。
  static String _statusLabel(String status) {
    switch (status) {
      case 'completed':
        return '已完成';
      case 'failed':
        return '失败';
      case 'cancelled':
        return '已取消';
      case 'rejected':
        return '已拒绝';
      case 'paused':
        return '已暂停';
      case 'transferring':
        return '传输中';
      case 'preparing':
        return '准备中';
      case 'verifying':
        return '校验中';
      default:
        return status;
    }
  }

  /// 清空本机传输记录（用户主动操作）。
  ///
  /// 只清本机历史：记录清空时间点，之后合并服务端记录时跳过该时刻之前的
  /// 数据（否则刷新一次旧记录又被合并回来）。对端设备上的记录不受影响，
  /// 已接收/已发送的文件本身也不会被删除。
  Future<void> _onClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空传输记录？'),
        content: Text(
          '将删除本机 ${_transfers.length} 条传输记录。\n\n'
          '· 只清本机显示的历史，不影响电脑端的记录\n'
          '· 已接收/已发送的文件本身不会被删除',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _historyStore.clearAll();
    if (!mounted) return;
    setState(() {
      _transfers = [];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('传输记录已清空')),
    );
  }

  Future<void> _loadTransfers() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final responses = await Future.wait(_httpClients.map((client) async {
        try {
          return await client.get('/api/v1/transfers');
        } catch (_) {
          return null;
        }
      }));

      // 用户清空过记录：清空时刻之前的服务端记录不再合并回来。
      final clearedAt = await _historyStore.clearedAt();
      final remoteTransfers = <TransferRow>[];
      for (final response in responses) {
        if (response == null) continue;
        final body = jsonDecode(response.body);
        final List<dynamic> items;
        if (body is List) {
          items = body;
        } else if (body is Map<String, dynamic> && body['transfers'] is List) {
          items = body['transfers'] as List<dynamic>;
        } else {
          items = const [];
        }
        remoteTransfers.addAll(items.map(
          (item) => TransferRow.fromJson(item as Map<String, dynamic>),
        ));
      }
      final freshRemote = clearedAt == null
          ? remoteTransfers
          : remoteTransfers
              .where((transfer) => transfer.createdAt > clearedAt)
              .toList();
      await _historyStore.upsertAll(freshRemote);

      final merged = <String, TransferRow>{
        for (final transfer in await _historyStore.load())
          if (clearedAt == null || transfer.createdAt > clearedAt)
            transfer.id: transfer,
        for (final transfer in freshRemote) transfer.id: transfer,
      };
      final transfers = merged.values
          .where((transfer) =>
              _statusFilter == 'all' || transfer.status == _statusFilter)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      setState(() {
        _transfers = transfers;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load history: $e';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// L15: 用系统查看器打开已接收的文件；失败时给用户可见的提示。
  Future<void> _openSavedFile(String path) async {
    try {
      await BackgroundReceiveService.openFile(path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开该文件（可能已被移动或删除）')),
        );
      }
    }
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return Colors.green;
      case 'failed':
        return Colors.red;
      case 'cancelled':
        return Colors.grey;
      case 'transferring':
        return Colors.blue;
      default:
        return Colors.orange;
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  static String _formatDate(int unixSeconds) {
    // Go backend stores timestamps as Unix seconds (not milliseconds).
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
