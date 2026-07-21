import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
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
  bool _loading = true;
  String? _error;

  FastDropHttpClient? _httpClient;
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
    final store = SessionStore();
    final data = await store.loadSession();
    if (data == null) {
      setState(() {
        _loading = false;
        _error = 'No active session. Pair with a PC first.';
      });
      return;
    }

    final client = FastDropHttpClient(baseUrl: data.serverBaseUrl);
    client.setSession(data.sessionId, data.accessToken);
    _httpClient = client;

    await _loadTransfers();
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _httpClient?.dispose();
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
        title: const Text('History'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _buildFilterBar(theme),
        ),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildFilterBar(ThemeData theme) {
    const filters = [
      ('all', 'All'),
      ('completed', 'Completed'),
      ('failed', 'Failed'),
      ('cancelled', 'Cancelled'),
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
              'No transfer history yet.',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadTransfers,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _transfers.length,
        itemBuilder: (context, index) {
          return _buildTransferTile(theme, _transfers[index]);
        },
      ),
    );
  }

  Widget _buildTransferTile(ThemeData theme, TransferRow transfer) {
    final statusColor = _statusColor(transfer.status);
    final directionIcon = transfer.direction == 'client_to_server'
        ? Icons.upload
        : Icons.download;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        leading: Icon(directionIcon, color: theme.colorScheme.primary),
        title: Text(
          '${transfer.totalFiles} file${transfer.totalFiles == 1 ? '' : 's'}',
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          _formatDate(transfer.createdAt),
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
                transfer.status,
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
                _detailRow('Transfer ID', transfer.id),
                _detailRow('Direction', transfer.direction == 'client_to_server'
                    ? 'Phone to PC'
                    : 'PC to Phone'),
                _detailRow('Status', transfer.status),
                _detailRow('Files', '${transfer.totalFiles}'),
                _detailRow('Size', _formatBytes(transfer.totalBytes)),
                _detailRow(
                  'Progress',
                  '${_formatBytes(transfer.transferredBytes)} / ${_formatBytes(transfer.totalBytes)}',
                ),
                _detailRow('Created', _formatDate(transfer.createdAt)),
                if (transfer.completedAt != null)
                  _detailRow('Completed', _formatDate(transfer.completedAt!)),
                if (transfer.errorCode != null)
                  _detailRow('Error', transfer.errorCode!),
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

  Future<void> _loadTransfers() async {
    if (_httpClient == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final queryParams = <String, String>{};
      if (_statusFilter != 'all') {
        queryParams['status'] = _statusFilter;
      }

      final response = await _httpClient!.get(
        '/api/v1/transfers',
        queryParams: queryParams.isNotEmpty ? queryParams : null,
      );

      final body = jsonDecode(response.body);
      final List<dynamic> items;
      if (body is List) {
        items = body;
      } else if (body is Map<String, dynamic> && body.containsKey('transfers')) {
        items = body['transfers'] as List<dynamic>;
      } else {
        items = [];
      }

      setState(() {
        _transfers = items
            .map((j) => TransferRow.fromJson(j as Map<String, dynamic>))
            .toList();
        _loading = false;
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
