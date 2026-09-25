// M16 回归测试：写链的一次失败不得中断后续写入。
//
// 与 transfer_history_store_test.dart 分开成文件：该场景要求
// SharedPreferences 处于未 mock 状态（底层 MethodChannel 在测试环境中抛
// MissingPluginException），而主测试文件的 setUp 会全局 mock。
import 'package:fastdrop_mobile/core/storage/transfer_history_store.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

TransferRow _row(String id, {required int createdAt}) {
  return TransferRow(
    id: id,
    sessionId: 'session',
    peerDeviceId: 'peer',
    direction: 'client_to_server',
    status: 'transferring',
    totalFiles: 1,
    totalBytes: 10,
    transferredBytes: 0,
    createdAt: createdAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed write does not poison the write chain (M16)', () async {
    final store = TransferHistoryStore();

    // SharedPreferences 未 mock：首次写链会在内部失败（MissingPluginException），
    // 但必须被吞掉并正常完成，不能让 _writeTail 变成永久失败的 Future。
    await store.upsert(_row('poison', createdAt: 1));

    // 恢复正常存储后，后续写必须照常落盘。
    SharedPreferences.setMockInitialValues({});
    await store.upsert(_row('good', createdAt: 2));

    final rows = await TransferHistoryStore().load();
    expect(rows.map((row) => row.id), ['good']);
  });
}
