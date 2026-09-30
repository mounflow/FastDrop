import 'package:flutter_test/flutter_test.dart';

import 'package:fastdrop_mobile/features/transfer/transfer_screen.dart';

/// 回归守卫：手机→PC 发送时批次任务卡片的进度与状态。
///
/// 修复前实测到的两个缺陷：
///  1. 字节显示 `1.2 GB / 0 B`——进度回调只累加已传字节，从不设置分母；
///  2. 状态永远"准备中"——状态回调未把批次状态透传进聚合。
TransferItemState item({
  required String status,
  int transferred = 0,
  int total = 0,
  String name = 'a.mp4',
}) {
  return TransferItemState(
    deviceId: 'dev',
    transferId: 't1',
    peerName: 'FastDrop-PC',
    fileName: name,
    bytesTransferred: transferred,
    totalBytes: total,
    speed: 0,
    status: status,
  );
}

void main() {
  group('批次卡片聚合 aggregateBatchFromItems', () {
    test('分母不为 0：预统计的批次总大小作为分母下限', () {
      final batch = const ActiveUploadBatch(
        totalFiles: 3,
        status: 'preparing',
        totalBytes: 3000, // setPendingFiles 预统计
      );
      final next = aggregateBatchFromItems(
        batch,
        [item(status: 'transferring', transferred: 500, total: 1000)],
      );
      expect(next.transferredBytes, 500);
      // 关键回归：分母保留预统计值，而不是退化成"已开始文件之和 1000"或 0。
      expect(next.totalBytes, 3000);
      expect(next.totalBytes, greaterThan(0));
    });

    test('已开始文件实际大小更大时以实际值为分母', () {
      final batch = const ActiveUploadBatch(
        totalFiles: 2,
        status: 'transferring',
        totalBytes: 100, // 预统计偏小（例如文件在选取后增长）
      );
      final next = aggregateBatchFromItems(
        batch,
        [
          item(status: 'transferring', transferred: 50, total: 1000),
          item(status: 'transferring', transferred: 0, total: 2000),
        ],
      );
      expect(next.totalBytes, 3000);
    });

    test('状态推导：preparing + 有文件在传 → transferring（不再卡在准备中）', () {
      final batch = const ActiveUploadBatch(
        totalFiles: 5,
        status: 'preparing',
        totalBytes: 5000,
      );
      final next = aggregateBatchFromItems(
        batch,
        [item(status: 'transferring', transferred: 100, total: 1000)],
      );
      expect(next.status, 'transferring');
      expect(next.currentFileName, 'a.mp4');
    });

    test('状态推导：仅凭已传字节也能从 preparing 升级为 transferring', () {
      final batch =
          const ActiveUploadBatch(totalFiles: 2, status: 'preparing');
      final next = aggregateBatchFromItems(
        batch,
        [item(status: 'completed', transferred: 10, total: 10)],
      );
      expect(next.status, 'transferring');
    });

    test('文件数进度：完成数与失败数随条目更新（0/N 起步）', () {
      final batch =
          const ActiveUploadBatch(totalFiles: 3, status: 'transferring');
      final next = aggregateBatchFromItems(batch, [
        item(status: 'completed', transferred: 10, total: 10, name: 'a'),
        item(status: 'failed', transferred: 0, total: 10, name: 'b'),
        item(status: 'transferring', transferred: 5, total: 10, name: 'c'),
      ]);
      expect(next.completedFiles, 1);
      expect(next.failedFiles, 1);
      expect(next.totalFiles, 3);
    });

    test('终态 completed：完成数补齐为总数', () {
      final batch =
          const ActiveUploadBatch(totalFiles: 4, status: 'transferring');
      final next = aggregateBatchFromItems(
        batch,
        [item(status: 'completed', transferred: 10, total: 10)],
        status: 'completed',
      );
      expect(next.status, 'completed');
      expect(next.completedFiles, 4);
    });

    test('失败状态透传（不被聚合覆盖）', () {
      final batch =
          const ActiveUploadBatch(totalFiles: 2, status: 'transferring');
      final next = aggregateBatchFromItems(
        batch,
        [item(status: 'failed', transferred: 0, total: 10)],
        status: 'failed',
      );
      expect(next.status, 'failed');
    });

    test('空批次（尚未有进度事件）保持准备中且分母为预统计值', () {
      final batch = const ActiveUploadBatch(
        totalFiles: 69,
        status: 'preparing',
        totalBytes: 4700000000,
      );
      final next = aggregateBatchFromItems(batch, const []);
      expect(next.completedFiles, 0);
      expect(next.totalFiles, 69);
      expect(next.totalBytes, 4700000000);
      expect(next.status, 'preparing');
    });
  });
}
