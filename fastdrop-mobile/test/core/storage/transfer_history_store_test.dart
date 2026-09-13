import 'package:fastdrop_mobile/core/storage/transfer_history_store.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('history persists, replaces matching ids, and sorts newest first',
      () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      _row('old', createdAt: 1),
      _row('new', createdAt: 2),
    ]);
    await store.upsert(_row('old', createdAt: 1, status: 'completed'));

    final rows = await TransferHistoryStore().load();
    expect(rows.map((row) => row.id), ['new', 'old']);
    expect(rows.last.status, 'completed');
  });

  test('non-terminal records become failed after a process restart', () async {
    final store = TransferHistoryStore();
    await store.upsert(_row('active', createdAt: 1, status: 'transferring'));

    await store.markInterruptedTransfersFailed();
    final row = (await store.load()).single;

    expect(row.status, 'failed');
    expect(row.errorCode, 'INTERNAL_ERROR');
    expect(row.completedAt, isNotNull);
  });
}

TransferRow _row(
  String id, {
  required int createdAt,
  String status = 'transferring',
}) {
  return TransferRow(
    id: id,
    sessionId: 'session',
    peerDeviceId: 'peer',
    direction: 'client_to_server',
    status: status,
    totalFiles: 1,
    totalBytes: 10,
    transferredBytes: status == 'completed' ? 10 : 0,
    createdAt: createdAt,
    completedAt: status == 'completed' ? createdAt + 1 : null,
  );
}
