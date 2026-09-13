import 'dart:convert';

import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Token-free, device-local transfer history used when peers are offline or
/// their in-memory embedded server has restarted.
class TransferHistoryStore {
  static const _key = 'fastdrop.transfer_history.v1';
  static const _maxRows = 500;
  static Future<void> _writeTail = Future<void>.value();

  Future<List<TransferRow>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TransferRow.fromJson)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> upsert(TransferRow row) => upsertAll([row]);

  Future<void> upsertAll(Iterable<TransferRow> rows) {
    final incoming = rows.toList(growable: false);
    if (incoming.isEmpty) return Future<void>.value();
    _writeTail = _writeTail.then((_) async {
      final current = await load();
      final merged = <String, TransferRow>{
        for (final row in current) row.id: row,
        for (final row in incoming) row.id: row,
      };
      final ordered = merged.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(ordered.take(_maxRows).map((row) => row.toJson()).toList()),
      );
    });
    return _writeTail;
  }

  /// A process restart interrupts every non-terminal local operation. Marking
  /// it failed avoids showing a permanently "transferring" stale record.
  Future<void> markInterruptedTransfersFailed() {
    _writeTail = _writeTail.then((_) async {
      final rows = await load();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      var changed = false;
      final updated = rows.map((row) {
        if (_terminalStatuses.contains(row.status)) return row;
        changed = true;
        return row.copyWith(
          status: 'failed',
          completedAt: now,
          errorCode: 'INTERNAL_ERROR',
          errorMessage: 'Transfer interrupted when the app stopped.',
        );
      }).toList();
      if (!changed) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(updated.map((row) => row.toJson()).toList()),
      );
    });
    return _writeTail;
  }

  static const _terminalStatuses = {
    'completed',
    'failed',
    'cancelled',
    'rejected',
  };
}
