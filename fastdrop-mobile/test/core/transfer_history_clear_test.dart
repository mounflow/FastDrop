import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fastdrop_mobile/core/storage/transfer_history_store.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';

/// 「清空记录」回归测试。
///
/// 语义：只清**本机**历史；记录清空时间点，之后合并服务端记录时跳过此刻
/// 之前的数据（否则刷新一次旧记录又被合并回来）；已收发的文件本身不删。
TransferRow row({
  required String id,
  int createdAt = 1000,
  String status = 'completed',
  String direction = 'client_to_server',
}) {
  return TransferRow(
    id: id,
    sessionId: 's1',
    peerDeviceId: 'peer-1',
    direction: direction,
    status: status,
    totalFiles: 1,
    totalBytes: 100,
    transferredBytes: 100,
    createdAt: createdAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('clearAll 清空本地记录并记录清空时间点', () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      row(id: 'a', createdAt: 100),
      row(id: 'b', createdAt: 200),
    ]);
    expect(await store.load(), hasLength(2));
    expect(await store.clearedAt(), isNull);

    await store.clearAll();

    expect(await store.load(), isEmpty);
    final clearedAt = await store.clearedAt();
    expect(clearedAt, isNotNull);
    // 时间点应接近当前时间（秒级）。
    expect(
      (clearedAt! - DateTime.now().millisecondsSinceEpoch ~/ 1000).abs(),
      lessThan(60),
    );
  });

  test('清空后新的传输（晚于清空时刻）仍会正常记录', () async {
    final store = TransferHistoryStore();
    await store.clearAll();
    final clearedAt = (await store.clearedAt())!;

    await store.upsert(row(id: 'new', createdAt: clearedAt + 10));

    final rows = await store.load();
    expect(rows, hasLength(1));
    expect(rows.single.id, 'new');
  });

  test('清空时刻之前的服务端记录会被过滤（不再合并回来）', () async {
    final store = TransferHistoryStore();
    await store.clearAll();
    final clearedAt = (await store.clearedAt())!;

    // 模拟历史页合并逻辑：跳过 createdAt <= clearedAt 的记录。
    final remote = [
      row(id: 'old-1', createdAt: clearedAt - 100),
      row(id: 'old-2', createdAt: clearedAt), // 恰好同一秒也视为已清空
      row(id: 'fresh', createdAt: clearedAt + 5),
    ];
    final kept = remote.where((t) => t.createdAt > clearedAt).toList();

    expect(kept.map((t) => t.id), ['fresh']);
  });

  test('清空不影响传输方向/状态等字段语义（空态下两个方向筛选都为空）', () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      row(id: 'sent', direction: 'client_to_server'),
      row(id: 'recv', direction: 'server_to_client'),
    ]);
    await store.clearAll();

    final rows = await store.load();
    expect(rows.where((r) => r.direction == 'client_to_server'), isEmpty);
    expect(rows.where((r) => r.direction == 'server_to_client'), isEmpty);
  });

  group('逐条删除（左滑）', () {
    test('remove 删除单条并写入墓碑', () async {
      final store = TransferHistoryStore();
      await store.upsertAll([row(id: 'a'), row(id: 'b')]);

      await store.remove('a');

      final rows = await store.load();
      expect(rows.map((r) => r.id), ['b']);
      expect(await store.deletedIds(), contains('a'));
    });

    test('被删记录不会被服务端合并"复活"', () async {
      final store = TransferHistoryStore();
      await store.upsertAll([row(id: 'a'), row(id: 'b')]);
      await store.remove('a');

      // 模拟历史页把服务端记录合并回来（含已删的那条）。
      await store.upsertAll([row(id: 'a'), row(id: 'b'), row(id: 'c')]);

      final ids = (await store.load()).map((r) => r.id).toList();
      expect(ids, isNot(contains('a')));
      expect(ids, containsAll(['b', 'c']));
    });

    test('删除不存在的 id 不报错', () async {
      final store = TransferHistoryStore();
      await store.upsertAll([row(id: 'a')]);
      await store.remove('not-exist');
      expect((await store.load()).map((r) => r.id), ['a']);
    });

    test('清空后再删除仍正常（墓碑与清空时间点互不影响）', () async {
      final store = TransferHistoryStore();
      await store.clearAll();
      final clearedAt = (await store.clearedAt())!;
      await store.upsert(row(id: 'fresh', createdAt: clearedAt + 5));
      await store.remove('fresh');

      expect(await store.load(), isEmpty);
      expect(await store.clearedAt(), isNotNull);
    });
  });
}
