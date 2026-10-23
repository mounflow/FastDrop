/// 相对时间文案（历史记录页 / 传输归档区共用）。
///
/// 此前 history_screen 与 transfer_screen 各有一份实现（一份英文 `Just now` /
/// `Nm ago`，一份中文「刚刚」/「N 分钟前」），阈值与文案容易分叉。这里只定义
/// 一次，两处都调用。
///
/// 返回 `null` 表示已超出"相对时间"的表达范围（≥ 7 天），由调用方决定绝对
/// 时间格式（两个调用点的绝对格式不同：一个 `YYYY-MM-DD`，一个 `M/D HH:mm`）。
String? formatRelativeTime(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return null;
}
