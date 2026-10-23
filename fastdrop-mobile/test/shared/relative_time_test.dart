import 'package:flutter_test/flutter_test.dart';

import 'package:fastdrop_mobile/shared/utils/relative_time.dart';

/// 抽出的公共「相对时间」函数（history_screen / transfer_screen 共用）。
///
/// 此前两处各有一份实现（一份英文、一份中文），这里锁住阈值与中文文案，
/// 防止再次分叉。
void main() {
  final now = DateTime(2026, 1, 10, 12);

  test('阈值与中文文案', () {
    expect(formatRelativeTime(now, now: now), '刚刚');
    expect(
      formatRelativeTime(now.subtract(const Duration(seconds: 59)), now: now),
      '刚刚',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(minutes: 1)), now: now),
      '1 分钟前',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(minutes: 59)), now: now),
      '59 分钟前',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(hours: 1)), now: now),
      '1 小时前',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(hours: 23)), now: now),
      '23 小时前',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(days: 1)), now: now),
      '1 天前',
    );
    expect(
      formatRelativeTime(now.subtract(const Duration(days: 6)), now: now),
      '6 天前',
    );
  });

  test('≥7 天返回 null，由调用方决定绝对时间格式', () {
    expect(
      formatRelativeTime(now.subtract(const Duration(days: 7)), now: now),
      isNull,
    );
  });
}
