import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fastdrop_mobile/app/theme.dart';
import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/core/server/pairing_providers.dart';
import 'package:fastdrop_mobile/core/server/ws_server.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/features/devices/multi_device_connection.dart';
import 'package:fastdrop_mobile/shared/widgets/file_icon.dart';

/// A file browser with three category tabs (图片 / 视频 / 所有文件)
/// that uses the system file picker for selection.
///
/// Selected files are shown in a list with thumbnails, sizes, and the
/// ability to remove individual items before sending. A "发送" FAB
/// navigates to the transfer screen with the final selection.
class FilePickerScreen extends ConsumerStatefulWidget {
  const FilePickerScreen({super.key});

  @override
  ConsumerState<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends ConsumerState<FilePickerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final List<_SelectedFile> _selected = [];
  final Set<String> _selectedDeviceIds = {};
  List<Device> _devices = const [];
  bool _routeArgsLoaded = false;
  final TextEditingController _textController = TextEditingController();

  /// 文本快传的 UI 本地状态：本轮已投出、尚在等待 `text.ack` 的设备数。
  /// 只用于"发送中"反馈，不参与协议（WS 消息类型/字段均未改动）。
  int _textPendingAcks = 0;

  /// 回执超时定时器：ack 始终不回时结束「发送中」态，避免卡片永久转圈。
  /// 与 PC 端 TEXT_ACK_TIMEOUT_MS 对齐（8s）；纯 UI 侧，不重发、不改协议超时。
  Timer? _textAckTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadDevices();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeArgsLoaded) return;
    _routeArgsLoaded = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic>) {
      final ids = (args['initialDeviceIds'] as List<dynamic>? ?? const [])
          .map((value) => value.toString());
      _selectedDeviceIds.addAll(ids);
    }
  }

  @override
  void dispose() {
    _textAckTimer?.cancel();
    _tabController.dispose();
    _textController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connections = ref.watch(multiDeviceConnectionProvider);

    // 文本送达确认（text.ack）→ SnackBar。
    ref.listen(textDeliveryStatusProvider, (previous, next) {
      if (next.startsWith('delivered:')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文本已送达')),
        );
        // 全部确认返回后结束「发送中」态。
        if (mounted && _textPendingAcks > 0) {
          setState(() => _textPendingAcks -= 1);
          if (_textPendingAcks == 0) _textAckTimer?.cancel();
        }
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('发送文件'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.image), text: '图片'),
            Tab(icon: Icon(Icons.movie), text: '视频'),
            Tab(icon: Icon(Icons.folder), text: '所有文件'),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildRecipientSelector(theme, connections),
          // 操作流：选设备 → 文本快传 → 已选文件 → 文件选择。
          _buildTextSendCard(theme),
          if (_selected.isNotEmpty)
            Container(
              width: double.infinity,
              color: theme.colorScheme.primaryContainer.withOpacity(0.3),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                '已选 ${_selected.length} 个文件  '
                '(${_formatBytes(_selected.fold<int>(0, (sum, f) => sum + f.size))})',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildCategoryTab(
                  theme,
                  '图片',
                  Icons.image_outlined,
                  '点击浏览图片',
                  FileType.image,
                ),
                _buildCategoryTab(
                  theme,
                  '视频',
                  Icons.movie_outlined,
                  '点击浏览视频',
                  FileType.video,
                ),
                _buildCategoryTab(
                  theme,
                  '所有文件',
                  Icons.folder_outlined,
                  '点击浏览文件',
                  FileType.any,
                ),
              ],
            ),
          ),
          if (_selected.isNotEmpty) _buildSelectedList(theme),
        ],
      ),
      floatingActionButton: _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _onSend,
              icon: const Icon(Icons.send),
              label: Text('发送 (${_selected.length})'),
            )
          : null,
    );
  }

  Widget _buildRecipientSelector(
      ThemeData theme, MultiDeviceConnectionState connections) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.35),
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '发送到（可多选）',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          if (_devices.isEmpty)
            const Text('暂无已配对设备')
          else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _devices.map((device) {
                // 在线判定覆盖双向连接：pool 追踪的（手机主动连接）+
                // 入站连接的（PC 主动连接手机，在 map 里即在线）。
                final poolConnected =
                    connections.peer(device.id)?.isConnected ?? false;
                final incomingPeers = ref
                    .watch(incomingPeerConnectionsProvider)
                    .values
                    .toList();
                final incoming = incomingPeers
                    .any((peer) => peer.deviceName == device.name);
                final connected = poolConnected || incoming;
                return FilterChip(
                  selected: _selectedDeviceIds.contains(device.id),
                  onSelected: connected
                      ? (selected) => setState(() {
                            if (selected) {
                              _selectedDeviceIds.add(device.id);
                            } else {
                              _selectedDeviceIds.remove(device.id);
                            }
                          })
                      : null,
                  avatar: Icon(
                    connected ? Icons.circle : Icons.circle_outlined,
                    size: 10,
                    color: connected ? Colors.green : Colors.grey,
                  ),
                  label: Text(connected ? device.name : '${device.name}（离线）'),
                );
              }).toList(),
            ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  /// 文本快传卡片（text.send）：网址 / 验证码 / API key 等短文本，走已认证
  /// WS 控制通道直传，发送目标复用上方选中的设备。
  ///
  /// 语义上"发文本"不属于"选择收件人"，因此从 [_buildRecipientSelector]
  /// 中独立出来，插在设备选择之后、已选文件之前。
  Widget _buildTextSendCard(ThemeData theme) {
    final bytes = utf8.encode(_textController.text).length;
    final overLimit = bytes > WsServer.textMaxBytes;
    final hasTargets = _selectedDeviceIds.isNotEmpty;

    // 未选设备 / 超限时不能只靠置灰，必须用可见文字说明原因。
    final String? blockedReason = !hasTargets
        ? '请先选择接收设备'
        : overLimit
            ? '文本超出 64 KB 上限，请缩短后发送'
            : null;
    final blockedIsError = overLimit;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('文本快传', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                '直接发送网址、验证码、API key 等短文本',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _textController,
                minLines: 2,
                maxLines: 4,
                style: theme.textTheme.bodyMedium,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '输入要发送的文本…',
                  suffixIcon: IconButton(
                    tooltip: '粘贴',
                    icon: const Icon(Icons.content_paste, size: 20),
                    onPressed: _pasteText,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // 字数提示：UTF-8 字节数 / 上限，超限变红。
                  Text(
                    '$bytes / ${WsServer.textMaxBytes} 字节',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: overLimit
                          ? AppTheme.danger
                          : AppTheme.textSecondary,
                    ),
                  ),
                  if (_textPendingAcks > 0) ...[
                    const SizedBox(width: 10),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 6),
                    Text('发送中…', style: theme.textTheme.bodySmall),
                  ],
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: blockedReason == null ? _sendText : null,
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('发送'),
                  ),
                ],
              ),
              if (blockedReason != null) ...[
                const SizedBox(height: 6),
                Text(
                  blockedReason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: blockedIsError
                        ? AppTheme.danger
                        : AppTheme.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pasteText() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _textController.text = text;
      setState(() {});
    }
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入要发送的文本')),
      );
      return;
    }
    if (_selectedDeviceIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择接收设备')),
      );
      return;
    }
    if (utf8.encode(text).length > WsServer.textMaxBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文本超出 64 KB 上限，请缩短后发送')),
      );
      return;
    }
    final notifier = ref.read(multiDeviceConnectionProvider.notifier);
    var queued = 0;
    for (final deviceId in _selectedDeviceIds) {
      if (notifier.sendText(deviceId, text)) queued++;
    }
    final failed = _selectedDeviceIds.length - queued;
    if (!mounted) return;
    if (queued == 0) {
      // 全部失败：所选设备都没有可用的发送连接。
      setState(() => _textPendingAcks = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('发送失败：所选设备暂无可用发送连接')),
      );
      return;
    }
    _textController.clear();
    // 已投出 queued 条，等待 queued 个 text.ack；期间状态行显示「发送中…」。
    setState(() => _textPendingAcks = queued);
    // ack 可能永远不回（对端掉线等）：超时后结束「发送中」并如实告知未确认数量，
    // 否则卡片会永久停在转圈状态。只影响 UI，不重发、不改协议超时。
    _textAckTimer?.cancel();
    _textAckTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      final pending = _textPendingAcks;
      if (pending <= 0) return;
      setState(() => _textPendingAcks = 0);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$pending 台设备未回执确认，请检查连接')),
      );
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failed == 0
            ? '已向 $queued 台设备发送文本'
            : '已向 $queued 台设备发送文本，$failed 台发送失败（连接不可用）'),
      ),
    );
  }

  Widget _buildCategoryTab(
    ThemeData theme,
    String label,
    IconData icon,
    String hint,
    FileType fileType,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 64, color: theme.colorScheme.primary.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text(hint, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => _pickFiles(fileType),
            icon: const Icon(Icons.add),
            label: Text('选择$label'),
          ),
        ],
      ),
    );
  }

  /// Shows the list of already-selected files with thumbnails and remove
  /// buttons.
  Widget _buildSelectedList(ThemeData theme) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _selected.length,
        itemBuilder: (context, index) {
          final file = _selected[index];
          final ext =
              file.name.contains('.') ? file.name.split('.').last : null;

          return ListTile(
            leading: file.platformFile.path != null &&
                    ['jpg', 'jpeg', 'png', 'gif', 'webp']
                        .contains(ext?.toLowerCase())
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(
                      File(file.platformFile.path!),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          FileIcon(extension: ext, size: 48),
                    ),
                  )
                : FileIcon(extension: ext, size: 48),
            title: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_formatBytes(file.size)),
            trailing: IconButton(
              icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
              onPressed: () => setState(() => _selected.removeAt(index)),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _pickFiles(FileType fileType) async {
    try {
      // Allow picking while keeping accumulated selections.
      final result = await FilePicker.platform.pickFiles(
        type: fileType,
        allowMultiple: true,
        allowCompression: false,
      );

      if (result == null || result.files.isEmpty) return;

      // 选取后不再整批拷贝到私有目录（问题：大批次选完卡住数分钟）——
      // 搬迁挪到上传时逐文件进行（TransferService._uploadFile 内的
      // FileUtils.relocateToUploadDir）。这里仅放置 .nomedia 关闭
      // MediaScanner，防止 file_picker 缓存副本出现在相册。
      if (result.files.isNotEmpty && result.files.first.path != null) {
        _ensureNoMedia(File(result.files.first.path!).parent);
      }

      setState(() {
        for (final pf in result.files) {
          // Avoid duplicates by path.
          final alreadyIn =
              _selected.any((s) => s.platformFile.path == pf.path);
          if (!alreadyIn && pf.path != null) {
            _selected.add(_SelectedFile(
              name: pf.name,
              size: pf.size,
              platformFile: pf,
            ));
          }
        }
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开文件选择器：${e.message}')),
      );
    }
  }

  Future<void> _onSend() async {
    if (_selected.isEmpty) return;

    final connectedIds = ref
        .read(multiDeviceConnectionProvider)
        .connectedDevices
        .map((device) => device.id)
        .toSet();
    // 入站连接的设备（PC 主动连接手机）按名称匹配回 id，同样可作为
    // 发送目标——在 map 里即在线。
    final incomingNames = ref
        .read(incomingPeerConnectionsProvider)
        .values
        .map((peer) => peer.deviceName)
        .toSet();
    for (final device in _devices) {
      if (incomingNames.contains(device.name)) connectedIds.add(device.id);
    }
    final targets = _selectedDeviceIds.intersection(connectedIds).toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少选择一个在线接收设备')),
      );
      return;
    }

    final paths =
        _selected.map((f) => f.platformFile.path).whereType<String>().toList();

    if (paths.isEmpty) return;

    // Snapshot the paths, then clear the selection BEFORE navigating.
    // TransferService.uploadFiles deletes the fastdrop_upload temp
    // copies in its finally block (success / failure / cancel), so any
    // entry we keep here becomes a dangling path — the next Send would
    // hit "File not found" on that path and abort the whole batch.
    setState(() {
      _selected.clear();
    });

    Navigator.of(context).pushNamed(
      '/transfer',
      arguments: {
        'filePaths': paths,
        'targetDeviceIds': targets,
      },
    );
  }

  Future<void> _loadDevices() async {
    final devices = await ref.read(deviceStoreProvider).loadDevices();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _selectedDeviceIds.removeWhere(
        (id) => !devices.any((device) => device.id == id),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  // （搬迁逻辑已挪至 FileUtils.relocateToUploadDir，上传时逐文件懒执行。）

  /// Create a `.nomedia` file in [dir] so Android's MediaScanner skips it.
  static void _ensureNoMedia(Directory dir) {
    try {
      final nomedia = File('${dir.path}${Platform.pathSeparator}.nomedia');
      if (!nomedia.existsSync()) {
        nomedia.createSync();
      }
    } catch (_) {
      // Best-effort; if we can't write .nomedia the transfer still works.
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Internal holder for a selected file.
class _SelectedFile {
  const _SelectedFile({
    required this.name,
    required this.size,
    required this.platformFile,
  });

  final String name;
  final int size;
  final PlatformFile platformFile;
}
