import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fastdrop_mobile/core/storage/transfer_history_store.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';

/// 历史记录去重回归测试。
///
/// 用户实测："手机的传输历史为啥看到具体的传输文件？"——同一批次出现两行：
/// completed（服务端 UUID）+ failed（旧版用本地 offerId 建的行，启动自愈时
/// 被标成 interrupted）。修复见 TransferHistoryStore._pruneInterruptedDuplicates。
TransferRow row({
  required String id,
  required String status,
  int totalFiles = 14,
  int totalBytes = 300 * 1024 * 1024,
  int createdAt = 1000,
  String direction = 'client_to_server',
  String peerDeviceId = 'http://192.168.1.11:9527',
  String? errorMessage,
  int? completedAt,
}) {
  return TransferRow(
    id: id,
    sessionId: 'session-1',
    peerDeviceId: peerDeviceId,
    direction: direction,
    status: status,
    totalFiles: totalFiles,
    totalBytes: totalBytes,
    transferredBytes: totalBytes,
    createdAt: createdAt,
    completedAt: completedAt,
    errorMessage: errorMessage,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('旧版遗留的"中断失败"复制行会被清理（保留 completed 行）', () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      // 服务端 transferId 的真实完成行（peerDeviceId 为手机自身 id，
      // 来自服务端记录合并——与本地行的设备基址不同，实测即如此）
      row(
        id: '45d1297e-7216-4d5b-9d3f-0a1b2c3d4e5f',
        status: 'completed',
        peerDeviceId: 'VIchkxlFFJtklwsRbfeBs3s0QDUo-e8PehyzA_og4uQ',
      ),
      // 旧版本地 offerId 残留行，启动自愈后被标成 interrupted
      row(
        id: '084a65160ff4abcdef',
        status: 'failed',
        createdAt: 1001,
        peerDeviceId: 'http://192.168.1.11:9527',
        errorMessage: 'Transfer interrupted when the app stopped.',
      ),
    ]);

    await store.markInterruptedTransfersFailed();
    final rows = await store.load();

    expect(rows, hasLength(1));
    expect(rows.single.status, 'completed');
    expect(rows.single.id.contains('-'), isTrue);
  });

  test('不同文件数的两条独立传输不会被误删', () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      row(id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', status: 'completed'),
      row(
        id: 'local-offer-id-1',
        status: 'failed',
        totalFiles: 8, // 不同批次
        errorMessage: 'Transfer interrupted when the app stopped.',
      ),
    ]);

    await store.markInterruptedTransfersFailed();
    expect(await store.load(), hasLength(2));
  });

  test('没有对应完成行的中断失败会保留（真实失败要可见）', () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      row(
        id: 'local-offer-id-2',
        status: 'failed',
        errorMessage: 'Transfer interrupted when the app stopped.',
      ),
    ]);

    await store.markInterruptedTransfersFailed();
    final rows = await store.load();
    expect(rows, hasLength(1));
    expect(rows.single.status, 'failed');
  });

  test('时间相差超过 120 秒的同规格传输不会被误删', () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      row(id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', status: 'completed'),
      row(
        id: 'local-offer-id-3',
        status: 'failed',
        createdAt: 5000, // 与上一行相差 4000 秒
        errorMessage: 'Transfer interrupted when the app stopped.',
      ),
    ]);

    await store.markInterruptedTransfersFailed();
    expect(await store.load(), hasLength(2));
  });

  test('非中断原因的失败行不受影响', () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      row(id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', status: 'completed'),
      row(
        id: 'local-offer-id-4',
        status: 'failed',
        createdAt: 1001,
        errorMessage: 'FILE_HASH_MISMATCH',
      ),
    ]);

    await store.markInterruptedTransfersFailed();
    expect(await store.load(), hasLength(2));
  });

  test('非终态行仍会被标记为中断失败', () async {
    final store = TransferHistoryStore();
    await store.upsertAll([
      row(id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', status: 'transferring'),
    ]);

    await store.markInterruptedTransfersFailed();
    final rows = await store.load();
    expect(rows.single.status, 'failed');
    expect(rows.single.errorMessage, contains('interrupted'));
  });
}
