import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Token-free, device-local transfer history used when peers are offline or
/// their in-memory embedded server has restarted.
class TransferHistoryStore {
  static const _key = 'fastdrop.transfer_history.v1';
  static const _clearedAtKey = 'fastdrop.transfer_history.cleared_at.v1';
  static const _deletedIdsKey = 'fastdrop.transfer_history.deleted_ids.v1';
  static const _maxRows = 500;
  static const _maxDeletedIds = 500;
  static Future<void> _writeTail = Future<void>.value();

  /// 用户上次「清空记录」的时间（秒）。历史页合并服务端记录时会跳过此时刻
  /// 之前的数据——否则清空后一刷新，服务端旧记录又被合并回来。
  Future<int?> clearedAt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_clearedAtKey);
  }

  /// 清空本机历史：删除全部本地行并记录清空时间点。
  ///
  /// 只影响**本机**历史；对端设备上的记录不受影响（各自管理）。
  Future<void> clearAll() async {
    _writeTail = _writeTail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
      await prefs.setInt(
        _clearedAtKey,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    }).catchError((Object e) {
      debugPrint('[TransferHistory] clear failed: $e');
    });
    return _writeTail;
  }

  Future<List<TransferRow>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final deleted = await deletedIds();
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TransferRow.fromJson)
          .where((row) => !deleted.contains(row.id))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  /// 被用户逐条删除的记录 id（墓碑）。
  ///
  /// 历史页会定期把**服务端**的传输记录合并回本地；若不记住"用户删过这条"，
  /// 删掉的记录下一次刷新就被合并回来了。合并与读取都会跳过这些 id。
  Future<Set<String>> deletedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_deletedIdsKey) ?? const <String>[]).toSet();
  }

  /// 逐条删除（左滑删除单条记录）。仅影响本机历史；文件本身不删除。
  Future<void> remove(String id) async {
    if (id.isEmpty) return;
    _writeTail = _writeTail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final tombstones = prefs.getStringList(_deletedIdsKey) ?? <String>[];
      if (!tombstones.contains(id)) {
        tombstones.add(id);
        // 上限防止无界增长（按删除顺序保留最近的 N 条）。
        final trimmed = tombstones.length > _maxDeletedIds
            ? tombstones.sublist(tombstones.length - _maxDeletedIds)
            : tombstones;
        await prefs.setStringList(_deletedIdsKey, trimmed);
      }
      final current = await load();
      final remaining = current.where((row) => row.id != id).toList();
      await prefs.setString(
        _key,
        jsonEncode(remaining.take(_maxRows).map((row) => row.toJson()).toList()),
      );
    }).catchError((Object e) {
      debugPrint('[TransferHistory] remove failed: $e');
    });
    return _writeTail;
  }

  Future<void> upsert(TransferRow row) => upsertAll([row]);

  Future<void> upsertAll(Iterable<TransferRow> rows) {
    final incoming = rows.toList(growable: false);
    if (incoming.isEmpty) return Future<void>.value();
    // 写链每步都要继续（M16）：单次写失败只记录日志，不中断后续写入，
    // 否则一次失败会让 _writeTail 永久带着错误、拖垮之后所有落盘。
    _writeTail = _writeTail.then((_) async {
      // 用户删过的记录不允许被服务端合并"复活"。
      final deleted = await deletedIds();
      final current = await load();
      final merged = <String, TransferRow>{
        for (final row in current)
          if (!deleted.contains(row.id)) row.id: row,
        for (final row in incoming)
          if (!deleted.contains(row.id)) row.id: row,
      };
      final ordered = merged.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(ordered.take(_maxRows).map((row) => row.toJson()).toList()),
      );
    }).catchError((Object e) {
      debugPrint('[TransferHistory] write failed: $e');
    });
    return _writeTail;
  }

  /// A process restart interrupts every non-terminal local operation. Marking
  /// it failed avoids showing a permanently "transferring" stale record.
  ///
  /// 同时清理旧版本遗留的"同一批次两行"（见 [_pruneInterruptedDuplicates]）。
  Future<void> markInterruptedTransfersFailed() {
    _writeTail = _writeTail.then((_) async {
      final rows = await load();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      var changed = false;
      final marked = rows.map((row) {
        if (_terminalStatuses.contains(row.status)) return row;
        changed = true;
        return row.copyWith(
          status: 'failed',
          completedAt: now,
          errorCode: 'INTERNAL_ERROR',
          errorMessage: 'Transfer interrupted when the app stopped.',
        );
      }).toList();

      final pruned = _pruneInterruptedDuplicates(marked);
      if (pruned.length != marked.length) changed = true;
      if (!changed) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(pruned.map((row) => row.toJson()).toList()),
      );
    }).catchError((Object e) {
      debugPrint('[TransferHistory] write failed: $e');
    });
    return _writeTail;
  }

  /// 删除旧版本遗留的重复批次行。
  ///
  /// 历史成因：早期实现在 preparing/transferring 阶段就用**本地 offerId**
  /// 建行（修复后改为只在终态写服务端 transferId），残留行在下次启动时被
  /// 标记为"interrupted when the app stopped"，于是同一批次出现两行：
  /// completed（服务端 UUID）+ failed（本地 offerId）。用户看到的是
  /// "历史里同一批文件出现两条"。
  ///
  /// 判定条件严格到不会误伤正常记录：仅当该行是"中断失败"、id 不是服务端
  /// UUID（不含 `-`），且存在同方向/同文件数/同大小/创建时间相差 ≤120 秒的
  /// completed 或 cancelled 行时才丢弃。
  ///
  /// 注意**不比较 peerDeviceId**：本地行写的是设备基址（`http://<ip>:9527`），
  /// 而服务端合并回来的是对端 deviceId，两者本就不同（实测数据如此）。
  static List<TransferRow> _pruneInterruptedDuplicates(List<TransferRow> rows) {
    bool interruptedFailure(TransferRow row) =>
        row.status == 'failed' &&
        (row.errorMessage ?? '').contains('interrupted when the app stopped');

    final result = <TransferRow>[];
    for (final row in rows) {
      if (interruptedFailure(row) && !row.id.contains('-')) {
        final duplicatedBy = rows.any((other) =>
            other.id != row.id &&
            other.direction == row.direction &&
            other.totalFiles == row.totalFiles &&
            other.totalBytes == row.totalBytes &&
            (other.createdAt - row.createdAt).abs() <= 120 &&
            (other.status == 'completed' || other.status == 'cancelled'));
        if (duplicatedBy) continue;
      }
      result.add(row);
    }
    return result;
  }

  static const _terminalStatuses = {
    'completed',
    'failed',
    'cancelled',
    'rejected',
  };
}
