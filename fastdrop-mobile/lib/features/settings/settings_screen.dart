import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/providers.dart';
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
  SessionData? _session;
  final _manualIpController = TextEditingController();
  String? _customDownloadDir;

  @override
  void initState() {
    super.initState();
    _loadSession();
    _loadDownloadDir();
  }

  @override
  void dispose() {
    _manualIpController.dispose();
    super.dispose();
  }

  Future<void> _loadSession() async {
    final session = await ref.read(sessionStoreProvider).loadSession();
    if (mounted) {
      setState(() => _session = session);
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
          if (_session != null) ...[
            const _SectionHeader(title: 'Paired Device'),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ListTile(
                leading: const Icon(Icons.computer),
                title: Text(_session!.serverName ?? 'PC'),
                subtitle: Text(_session!.serverBaseUrl),
                trailing: _session!.isExpired
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
          if (_session != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: OutlinedButton.icon(
                onPressed: _confirmUnpair,
                icon: const Icon(Icons.link_off, color: Colors.red),
                label: const Text(
                  'Unpair',
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

          // -- Manual IP (Phase 2 placeholder) ---------------------------------
          const _SectionHeader(title: 'Manual Connection (Phase 2)'),
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
              'Enter a server IP address and port to connect manually. '
              'This option will be fully implemented in Phase 2.',
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair?'),
        content: const Text(
          'This will disconnect from the PC and clear the saved session. '
          'You will need to scan the QR code again to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Disconnect WebSocket.
    try {
      ref.read(wsClientProvider).disconnect();
    } catch (_) {}

    // Clear HTTP client session.
    ref.read(httpClientProvider).clearSession();

    // Clear persisted session.
    await ref.read(sessionStoreProvider).clearSession();

    if (mounted) {
      setState(() => _session = null);

      // Navigate to pairing screen, clearing the navigation stack.
      Navigator.of(context).pushNamedAndRemoveUntil('/pairing', (_) => false);
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

  void _onManualConnect() {
    final input = _manualIpController.text.trim();
    if (input.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a server address.')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Manual connection will be available in Phase 2.'),
      ),
    );
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
