import 'package:flutter/material.dart';

/// A card showing transfer progress for a single file.
class ProgressCard extends StatelessWidget {
  const ProgressCard({
    super.key,
    required this.fileName,
    required this.bytesTransferred,
    required this.totalBytes,
    this.speed,
    this.status,
  });

  final String fileName;
  final int bytesTransferred;
  final int totalBytes;
  final int? speed;
  final String? status;

  double get _progress =>
      totalBytes > 0 ? bytesTransferred / totalBytes : 0.0;

  String get _sizeText {
    final transferred = _formatBytes(bytesTransferred);
    final total = _formatBytes(totalBytes);
    return '$transferred / $total';
  }

  String get _speedText {
    if (speed == null) return '';
    return '${_formatBytes(speed!)}/s';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    fileName,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (status != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      status!,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _sizeText,
                  style: theme.textTheme.bodySmall,
                ),
                if (speed != null)
                  Text(
                    _speedText,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
