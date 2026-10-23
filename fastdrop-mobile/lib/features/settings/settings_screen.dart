import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/app/theme.dart';
import 'package:fastdrop_mobile/core/discovery/device_discovery.dart';
import 'package:fastdrop_mobile/core/discovery/discovery_providers.dart';
import 'package:fastdrop_mobile/core/app_info.dart';
import 'package:fastdrop_mobile/core/platform/background_receive_service.dart';
import 'package:fastdrop_mobile/core/server/server_providers.dart';
import 'package:fastdrop_mobile/core/storage/ignored_device_providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/features/devices/multi_device_connection.dart';
import 'package:fastdrop_mobile/features/pairing/pairing_screen.dart';
import 'package:fastdrop_mobile/core/utils/file_utils.dart';
import 'package:fastdrop_mobile/shared/widgets/app_navigation_bar.dart';

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// App settings screen.
///
/// Shows app version, paired device info, unpair option, and a manual server
/// IP entry field reserved for Phase 2.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Device? _activeDevice;
  final _manualIpController = TextEditingController();
  String? _customDownloadDir;
  bool? _ignoringBatteryOptimizations;

  @override
  void initState() {
    super.initState();
    _loadActiveDevice();
    _loadDownloadDir();
    _loadBatteryOptimizationState();
  }

  @override
  void dispose() {
    _manualIpController.dispose();
    super.dispose();
  }

  /// 问题 9（小改档）：检测电池优化白名单状态。各厂商后台杀进程策略
  /// 不同，但白名单是通用且用户可控的第一道保障。
  Future<void> _loadBatteryOptimizationState() async {
    final ignoring = await BackgroundReceiveService.isIgnoringBatteryOptimizations();
    if (mounted) {
      setState(() => _ignoringBatteryOptimizations = ignoring);
    }
  }

  Future<void> _openBatteryOptimizationSettings() async {
    await BackgroundReceiveService.openBatteryOptimizationSettings();
    // 用户大概率改完设置返回，刷新状态。
    if (mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _loadBatteryOptimizationState();
    }
  }

  Future<void> _loadActiveDevice() async {
    final device = await ref.read(deviceStoreProvider).getActiveDevice();
    if (mounted) {
      setState(() => _activeDevice = device);
    }
  }

  Future<void> _loadDownloadDir() async {
    final custom = await FileUtils.getCustomDownloadDir();
    if (mounted) {
      setState(() => _customDownloadDir = custom);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).extension<FastDropTokens>()!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        children: [
          // -- Paired Device ---------------------------------------------------
          if (_activeDevice != null) ...[
            const _SectionHeader(title: '当前设备'),
            // 与页面其余分组保持一致：平铺行 + 分隔线，不单独套卡片。
            // 整页只有这一组是卡片、其余是平面行，圆角与平面混排很跳。
            ListTile(
              leading: const Icon(Icons.computer),
              title: Text(
                _activeDevice!.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(_activeDevice!.serverBaseUrl),
              // 状态标签用"淡底 + 同色字"，不用实心色块：实心绿比主操作
              // 还抢眼，而这里表达的是状态，不是可点的操作。
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _activeDevice!.isExpired
                      ? tokens.dangerSoft
                      : tokens.successSoft,
                  borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                ),
                child: Text(
                  _activeDevice!.isExpired ? '已过期' : '有效',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _activeDevice!.isExpired
                        ? tokens.danger
                        : tokens.success,
                  ),
                ),
              ),
            ),
            // 危险操作做成同组内的第二行：既不占首屏视觉重心，也仍然可发现
            // （纯图标的删除按钮在手机上没有 hover 提示，等于不可发现）。
            ListTile(
              dense: true,
              leading: Icon(Icons.link_off, size: 20, color: tokens.danger),
              title: Text(
                '删除此设备',
                style: TextStyle(
                  color: tokens.danger,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onTap: _confirmUnpair,
            ),
            const Divider(),
          ],

          // -- Download Directory ------------------------------------------------
          const _SectionHeader(title: '下载目录'),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('保存位置'),
            subtitle: Text(
              _customDownloadDir ?? '默认（应用文档目录）',
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _changeDownloadDir,
          ),
          const Divider(),

          // -- 接收文件 (Embedded Server) -----------------------------------------
          const _SectionHeader(title: '接收文件'),
          Consumer(
            builder: (context, ref, child) {
              final serverState = ref.watch(fastdropServerProvider);
              final notifier = ref.read(fastdropServerProvider.notifier);
              return SwitchListTile(
                secondary: const Icon(Icons.cloud_download),
                title: const Text('允许其他设备向我发送文件'),
                subtitle: Text(
                  serverState.isRunning
                      ? '服务运行中 (端口 ${serverState.port})'
                      : serverState.status == ServerStatus.starting
                          ? '正在启动...'
                          : serverState.status == ServerStatus.error
                              ? '启动失败: ${serverState.errorMessage}'
                              : '已关闭',
                ),
                value: notifier.isEnabled,
                onChanged: (value) {
                  notifier.setEnabled(value);
                },
              );
            },
          ),
          Consumer(
            builder: (context, ref, child) {
              final serverState = ref.watch(fastdropServerProvider);
              final notifier = ref.read(fastdropServerProvider.notifier);
              return SwitchListTile(
                secondary: const Icon(Icons.fact_check_outlined),
                title: const Text('接收文件前需要确认'),
                subtitle: const Text(
                  '默认关闭：来自已配对设备的文件会直接接收。',
                ),
                value: serverState.requireReceiveConfirmation,
                onChanged: notifier.setRequireReceiveConfirmation,
              );
            },
          ),

          // -- 问题 9（小改档）：电池优化白名单引导 --------------------------
          if (_ignoringBatteryOptimizations == false) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Material(
                color: tokens.warningSoft,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.battery_saver,
                              size: 18, color: tokens.warning),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '为了保证后台接收稳定，建议将 FastDrop 加入电池优化白名单',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _openBatteryOptimizationSettings,
                          child: const Text('去设置'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],

          const Divider(),

          // -- 局域网发现 (mDNS) ------------------------------------------------
          const _SectionHeader(title: '局域网发现'),
          Consumer(
            builder: (context, ref, child) {
              final mdnsEnabled = ref.watch(mdnsEnabledProvider);
              return SwitchListTile(
                secondary: const Icon(Icons.radar),
                title: const Text('自动发现附近 PC'),
                subtitle: const Text(
                  '开启后可通过 mDNS 自动发现同一 WiFi 下的 FastDrop PC',
                ),
                value: mdnsEnabled,
                onChanged: (value) {
                  ref.read(mdnsEnabledProvider.notifier).setEnabled(value);
                },
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '需要 PC 端也开启 mDNS 广播（PC 网页版 Settings → 局域网设备发现）。',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),

          const Divider(),

          // -- Manual IP -------------------------------------------------------
          const _SectionHeader(title: '手动连接'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualIpController,
                    decoration: const InputDecoration(
                      hintText: '192.168.1.100:9527',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.text,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _onManualConnect,
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: '连接',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '输入 PC 的 IP 地址和端口直接连接，无需扫码或 mDNS。',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),

          const Divider(),

          const _SectionHeader(title: '配对安全'),
          Consumer(
            builder: (context, ref, child) {
              final serverState = ref.watch(fastdropServerProvider);
              final notifier = ref.read(fastdropServerProvider.notifier);
              return SwitchListTile(
                secondary: const Icon(Icons.verified_user_outlined),
                title: const Text('配对时需要确认'),
                subtitle: const Text(
                  '默认关闭：同一局域网内点击配对后直接连接；开启后需在本机确认。',
                ),
                value: serverState.requirePairConfirmation,
                onChanged: notifier.setRequirePairConfirmation,
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '关闭确认更方便，但同一局域网内的其他 FastDrop 设备也能发起配对。文件接收确认不受此开关影响。',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),

          const Divider(),

          // -- 已忽略设备 -----------------------------------------------------
          // 「删除设备」会写入忽略名单（该设备不再免确认自动配对）。过去没有
          // 任何入口能清除标记，导致删一次就等于永久拉黑。这里给出可恢复列表。
          const _SectionHeader(title: '已忽略设备'),
          Consumer(
            builder: (context, ref, child) {
              final ignored = ref.watch(ignoredDevicesProvider);
              if (ignored.isEmpty) {
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    '没有已忽略的设备。删除过的设备会出现在这里，可随时恢复。',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  for (final entry in ignored)
                    ListTile(
                      leading: const Icon(Icons.block_outlined),
                      title: Text(entry.name),
                      subtitle: const Text('已删除 · 不会自动重连'),
                      trailing: TextButton(
                        onPressed: () async {
                          await ref
                              .read(ignoredDevicesProvider.notifier)
                              .remove(
                                deviceId: entry.deviceId,
                                name: entry.name,
                              );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已恢复 ${entry.name}')),
                          );
                        },
                        child: const Text('恢复'),
                      ),
                    ),
                ],
              );
            },
          ),

          const Divider(),

          // -- About -----------------------------------------------------------
          const _SectionHeader(title: '关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('FastDrop'),
            subtitle: Text('局域网文件传输，无需登录，不上云'),
          ),
          ListTile(
            leading: const Icon(Icons.tag),
            title: const Text('版本'),
            subtitle: const Text(fastDropAppVersion),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('开源协议'),
            subtitle: const Text('MIT'),
          ),
        ],
      ),
      bottomNavigationBar: const FastDropNavigationBar(currentIndex: 2),
    );
  }

  // -- Actions ---------------------------------------------------------------

  Future<void> _confirmUnpair() async {
    final device = _activeDevice;
    if (device == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除此设备？'),
        content: Text(
          '将断开与 "${device.name}" 的连接并删除其会话。\n'
          '如需再次发送文件请重新扫码配对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    ref
        .read(multiDeviceConnectionProvider.notifier)
        .disconnectDevice(device.id);

    // Remove the device from the store.
    await ref.read(deviceStoreProvider).removeDevice(device.id);

    if (mounted) {
      setState(() => _activeDevice = null);

      // Back to devices screen — it will show the next device or the
      // empty state.
      Navigator.of(context).pushNamedAndRemoveUntil('/devices', (_) => false);
    }
  }

  Future<void> _changeDownloadDir() async {
    final controller = TextEditingController(text: _customDownloadDir ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载目录'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '留空使用默认',
            labelText: '路径',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();

    // null means the user pressed Cancel; empty string means "use default".
    if (result == null) return;

    if (result.isNotEmpty) {
      // Verify the directory can be created.
      try {
        final dir = Directory(result);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('无法创建目录：$e')),
          );
        }
        return;
      }
    }

    await FileUtils.setCustomDownloadDir(result);
    if (mounted) {
      setState(() => _customDownloadDir = result.isEmpty ? null : result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.isEmpty
              ? '已使用默认下载目录'
              : '下载目录：$result'),
        ),
      );
    }
  }

  /// 手动 IP 连接：解析地址 → 查已配对 → 直连 / 半自动配对。
  Future<void> _onManualConnect() async {
    final input = _manualIpController.text.trim();
    if (input.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入服务器地址')),
      );
      return;
    }

    // 解析输入 → baseUrl
    String baseUrl;
    if (input.startsWith('http://') || input.startsWith('https://')) {
      baseUrl = input;
    } else if (input.contains(':')) {
      baseUrl = 'http://$input';
    } else {
      baseUrl = 'http://$input:9527';
    }

    final discovered = DiscoveredDevice(
      deviceId: baseUrl,
      deviceName: baseUrl,
      baseUrl: baseUrl,
      protocolVersion: 1,
      platform: 'unknown',
      pairingRequired: true,
      tls: false,
    );

    // 查已配对设备
    final matched = await ref
        .read(deviceStoreProvider)
        .findMatch(discovered.baseUrl, discovered.deviceName);

    if (!mounted) return;

    if (matched != null) {
      // 已配对 → 直连
      ref.read(multiDeviceConnectionProvider.notifier).switchToDevice(matched);
      Navigator.of(context).pushNamedAndRemoveUntil('/devices', (_) => false);
    } else {
      // 未配对 → D-2 半自动配对
      ref.read(pairingProvider.notifier).pairViaMdns(discovered);
      Navigator.of(context).pushNamed('/pairing');
    }
  }
}

// -- Helper widget ------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          // 分组标题用中性色：拿主色制造分区会和"可点击/主操作"撞语义。
          // 层级由字号与间距承担，不靠颜色。
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}
