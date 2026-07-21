import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fastdrop_mobile/shared/widgets/file_icon.dart';

/// A file browser with three category tabs (Images, Videos, All Files)
/// that uses the system file picker for selection.
///
/// Selected files are shown in a list with thumbnails, sizes, and the
/// ability to remove individual items before sending. A "Send" FAB
/// navigates to the transfer screen with the final selection.
class FilePickerScreen extends StatefulWidget {
  const FilePickerScreen({super.key});

  @override
  State<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends State<FilePickerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final List<_SelectedFile> _selected = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Send Files'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.image), text: 'Images'),
            Tab(icon: Icon(Icons.movie), text: 'Videos'),
            Tab(icon: Icon(Icons.folder), text: 'All Files'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_selected.isNotEmpty)
            Container(
              width: double.infinity,
              color: theme.colorScheme.primaryContainer.withOpacity(0.3),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                '${_selected.length} file${_selected.length == 1 ? '' : 's'} selected  '
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
                  'images',
                  Icons.image_outlined,
                  'Tap to browse images',
                  FileType.image,
                ),
                _buildCategoryTab(
                  theme,
                  'videos',
                  Icons.movie_outlined,
                  'Tap to browse videos',
                  FileType.video,
                ),
                _buildCategoryTab(
                  theme,
                  'all files',
                  Icons.folder_outlined,
                  'Tap to browse files',
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
              label: Text('Send (${_selected.length})'),
            )
          : null,
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
          Icon(icon, size: 64, color: theme.colorScheme.primary.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text(hint, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => _pickFiles(fileType),
            icon: const Icon(Icons.add),
            label: Text('Select $label'),
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
          final ext = file.name.contains('.')
              ? file.name.split('.').last
              : null;

          return ListTile(
            leading: file.platformFile.path != null &&
                    ['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext?.toLowerCase())
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
      );

      if (result == null || result.files.isEmpty) return;

      // Prevent Android MediaScanner from indexing cached copies
      // (avoids duplicate photos appearing in the gallery).
      _ensureNoMedia(result.files);

      setState(() {
        for (final pf in result.files) {
          // Avoid duplicates by path.
          final alreadyIn = _selected.any((s) => s.platformFile.path == pf.path);
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
        SnackBar(content: Text('Could not open file picker: ${e.message}')),
      );
    }
  }

  void _onSend() {
    if (_selected.isEmpty) return;

    final paths = _selected
        .map((f) => f.platformFile.path)
        .whereType<String>()
        .toList();

    if (paths.isEmpty) return;

    Navigator.of(context).pushNamed(
      '/transfer',
      arguments: {'filePaths': paths},
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Creates a `.nomedia` file in each picked file's cache directory so
  /// Android's MediaScanner does not index the cached copies (which would
  /// cause duplicate photos in the gallery).
  void _ensureNoMedia(List<PlatformFile> files) {
    final dirs = <String>{};
    for (final f in files) {
      if (f.path == null) continue;
      final parent = File(f.path!).parent.path;
      dirs.add(parent);
    }
    for (final dir in dirs) {
      try {
        final nomedia = File('$dir/.nomedia');
        if (!nomedia.existsSync()) {
          nomedia.createSync(recursive: true);
        }
      } catch (_) {
        // Best-effort; not critical.
      }
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
