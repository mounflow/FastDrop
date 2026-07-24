import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/discovery/device_discovery.dart';
import 'package:fastdrop_mobile/core/discovery/discovery_providers.dart';
import 'package:fastdrop_mobile/features/pairing/pairing_screen.dart';

// ---------------------------------------------------------------------------
// 附近设备 BottomSheet
// ---------------------------------------------------------------------------

/// 显示 mDNS 发现到的附近 FastDrop PC 列表。
///
/// 每行显示：🖥 设备名 / IP / protocol 版本 / 状态（已配对✓ / 待配对）。
/// 点击已配对设备 → 直接切换连接（阶段 4 实现）。
/// 点击未配对设备 → 进配对流程（阶段 5 实现）。
/// 当前阶段（3）只做展示 + 点击后进扫码页。
class NearbyDevicesSheet extends ConsumerWidget {
  const NearbyDevicesSheet({super.key});

  /// 以 BottomSheet 形式弹出。
  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const NearbyDevicesSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(nearbyDevicesProvider);
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      minChildSize: 0.25,
      maxChildSize: 0.75,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // 拖拽手柄
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题行
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.radar, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '附近设备',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (devices.isEmpty)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            // 设备列表
            Expanded(
              child: devices.isEmpty
                  ? _buildEmpty(theme)
                  : _buildDeviceList(context, ref, devices, scrollController),
            ),
            // 底部：扫码配对按钮
            const Divider(height: 1),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop(); // 关闭 sheet
                      ref.read(pairingProvider.notifier).resetToScanning();
                      Navigator.of(context).pushNamed('/pairing');
                    },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('扫码配对'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              '正在搜索附近的 FastDrop PC…',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 4),
            Text(
              '确保 PC 端已开启 mDNS 广播',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceList(
    BuildContext context,
    WidgetRef ref,
    List<DiscoveredDevice> devices,
    ScrollController scrollController,
  ) {
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: devices.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final device = devices[index];
        return _NearbyDeviceTile(device: device);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 单个设备行
// ---------------------------------------------------------------------------

class _NearbyDeviceTile extends ConsumerWidget {
  const _NearbyDeviceTile({required this.device});

  final DiscoveredDevice device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 检查此设备是否已配对（DeviceStore 里有记录）
    final isPaired = _checkPaired(ref);

    // 从 baseUrl 提取 IP 显示
    final displayUrl = device.baseUrl
        .replaceFirst('http://', '')
        .replaceFirst('https://', '');

    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            isPaired ? Colors.green.shade50 : Colors.grey.shade100,
        child: Icon(
          Icons.computer,
          color: isPaired ? Colors.green : Colors.grey,
        ),
      ),
      title: Text(
        device.deviceName,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        '$displayUrl · protocol v${device.protocolVersion}',
        style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
      ),
      trailing: isPaired
          ? const Chip(
              label: Text('已配对', style: TextStyle(fontSize: 11)),
              backgroundColor: Colors.green,
              labelStyle: TextStyle(color: Colors.white),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            )
          : const Chip(
              label: Text('待配对', style: TextStyle(fontSize: 11)),
              backgroundColor: Colors.orange,
              labelStyle: TextStyle(color: Colors.white),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
      onTap: () => _onTap(context, ref, isPaired),
    );
  }

  /// 检查 DeviceStore 里是否有此设备的记录。
  /// 用 baseUrl 匹配（Device.id == serverBaseUrl）。
  bool _checkPaired(WidgetRef ref) {
    // 同步检查不可行（DeviceStore 是异步的），
    // 用 device.pairingRequired 字段作为近似判断。
    // 阶段 4 会改为真正查 DeviceStore。
    return !device.pairingRequired;
  }

  void _onTap(BuildContext context, WidgetRef ref, bool isPaired) {
    // 关闭 BottomSheet
    Navigator.of(context).pop();

    if (isPaired) {
      // 阶段 4：自动重连（switchToDevice）
      // 当前阶段：提示用户
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已配对设备 — 自动重连将在后续版本支持')),
      );
    } else {
      // 阶段 5：半自动配对（D-2）
      // 当前阶段：进扫码页
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请通过扫码配对此设备')),
      );
    }
  }
}
