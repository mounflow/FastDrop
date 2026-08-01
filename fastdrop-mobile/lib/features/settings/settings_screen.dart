import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/discovery/device_discovery.dart';
import 'package:fastdrop_mobile/core/discovery/discovery_providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/features/devices/devices_screen.dart';
import 'package:fastdrop_mobile/features/pairing/pairing_screen.dart';
import 'package:fastdrop_mobile/core/utils/file_utils.dart';

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

  @override
  void initState() {
    super.initState();
    _loadActiveDevice();
    _loadDownloadDir();
  }

  @override
  void dispose() {
    _manualIpController.dispose();
    super.dispose();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // -- Paired Device ---------------------------------------------------
          if (_activeDevice != null) ...[
            const _SectionHeader(title: '当前设备'),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ListTile(
                leading: const Icon(Icons.computer),
                title: Text(_activeDevice!.name),
                subtitle: Text(_activeDevice!.serverBaseUrl),
                trailing: _activeDevice!.isExpired
                    ? const Chip(
                        label: Text('Expired', style: TextStyle(fontSize: 11)),
                        backgroundColor: Colors.red,
                        labelStyle: TextStyle(color: Colors.white),
                      )
                    : const Chip(
                        label: Text('Active', style: TextStyle(fontSize: 11)),
                        backgroundColor: Colors.green,
                        labelStyle: TextStyle(color: Colors.white),
                      ),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // -- Unpair ----------------------------------------------------------
          if (_activeDevice != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: OutlinedButton.icon(
                onPressed: _confirmUnpair,
                icon: const Icon(Icons.link_off, color: Colors.red),
                label: const Text(
                  '删除此设备',
                  style: TextStyle(color: Colors.red),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                ),
              ),
            ),
            const Divider(),
          ],

          // -- Download Directory ------------------------------------------------
          const _SectionHeader(title: 'Download Directory'),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Save location'),
            subtitle: Text(
              _customDownloadDir ?? 'Default (app documents)',
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _changeDownloadDir,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Files received from the PC are saved here. '
              'Leave empty to use the default location.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),

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
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '需要 PC 端也开启 mDNS 广播（PC 网页版 Settings → 局域网设备发现）。',
              style: TextStyle(color: Colors.grey, fontSize: 12),
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
                  tooltip: 'Connect',
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '输入 PC 的 IP 地址和端口直接连接，无需扫码或 mDNS。',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),

          const Divider(),

          // -- About -----------------------------------------------------------
          const _SectionHeader(title: 'About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('FastDrop'),
            subtitle: Text('LAN file transfer, no cloud, no accounts.'),
          ),
          ListTile(
            leading: const Icon(Icons.tag),
            title: const Text('Version'),
            subtitle: const Text('1.0.0'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('License'),
            subtitle: const Text('MIT'),
          ),
        ],
      ),
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
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Disconnect WebSocket if this is the active connection.
    try {
      ref.read(wsClientProvider).disconnect();
    } catch (_) {}

    ref.read(httpClientProvider).clearSession();

    // Remove the device from the store.
    await ref.read(deviceStoreProvider).removeDevice(device.id);

    if (mounted) {
      setState(() => _activeDevice = null);

      // Back to devices screen — it will show the next device or the
      // empty state.
      Navigator.of(context).pushNamedAndRemoveUntil(
          '/devices', (_) => false);
    }
  }

  Future<void> _changeDownloadDir() async {
    final controller = TextEditingController(text: _customDownloadDir ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download Directory'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Leave empty for default',
            labelText: 'Path',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
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
            SnackBar(content: Text('Cannot create directory: $e')),
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
              ? 'Using default download directory'
              : 'Download directory: $result'),
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
      ref.read(deviceConnectionProvider.notifier).switchToDevice(matched);
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/devices', (_) => false);
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
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}
