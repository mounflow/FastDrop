import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Utility functions for local file operations used during transfers.
class FileUtils {
  FileUtils._();

  // -- Chunk size matching the Go backend (4 MB) ------------------------------

  static const int chunkSize = 4 * 1024 * 1024; // 4 194 304 bytes

  // -- Windows-illegal characters and reserved names --------------------------

  /// Characters illegal in Windows file names.
  static const Set<int> _illegalChars = {
    // \ / : * ? " < > |
    0x5C, 0x2F, 0x3A, 0x2A, 0x3F, 0x22, 0x3C, 0x3E, 0x7C,
    // NUL
    0x00,
  };

  /// Windows reserved names (case-insensitive).
  static const Set<String> _reservedNames = {
    'CON',  'PRN',  'AUX',  'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5',
    'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5',
    'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// Sanitize a file name by stripping dangerous characters, `../`, and
  /// reserved names. Always returns only the basename.
  static String sanitizeFileName(String rawName) {
    // Strip any directory traversal.
    var name = rawName
        .replaceAll(r'..\', '')
        .replaceAll('../', '')
        .replaceAll('\\', '')
        .replaceAll('/', '');

    // Take only the basename.
    name = name.split(RegExp(r'[\\/]')).last;

    // Remove illegal characters.
    final cleaned = StringBuffer();
    for (final codeUnit in name.codeUnits) {
      if (!_illegalChars.contains(codeUnit)) {
        cleaned.writeCharCode(codeUnit);
      }
    }
    name = cleaned.toString().trim();

    // Strip leading/trailing dots and spaces.
    name = name.replaceAll(RegExp(r'^[ .]+'), '').replaceAll(RegExp(r'[ .]+$'), '');

    // Fallback for empty results.
    if (name.isEmpty) {
      name = 'unnamed_file';
    }

    // Check reserved names (case-insensitive, with or without extension).
    final upperName = name.toUpperCase();
    final dotIndex = upperName.lastIndexOf('.');
    final baseName = dotIndex >= 0 ? upperName.substring(0, dotIndex) : upperName;
    if (_reservedNames.contains(baseName)) {
      name = '_$name';
    }

    return name;
  }

  /// Generate the rename-on-conflict name: `photo.jpg` -> `photo (1).jpg`.
  static String renameOnConflict(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return filePath;

    final dir = file.parent.path;
    final baseName = file.uri.pathSegments.last;
    final dotIndex = baseName.lastIndexOf('.');
    final stem = dotIndex >= 0 ? baseName.substring(0, dotIndex) : baseName;
    final ext = dotIndex >= 0 ? baseName.substring(dotIndex) : '';

    var counter = 1;
    String candidate;
    do {
      candidate = '$dir${Platform.pathSeparator}$stem ($counter)$ext';
      counter++;
    } while (File(candidate).existsSync());

    return candidate;
  }

  // -- SHA-256 verification ---------------------------------------------------

  /// Compute the SHA-256 hash of a file at [path].
  static Future<String> computeFileSha256(String path) async {
    final file = File(path);
    final stream = file.openRead();
    final digest = await sha256.bind(stream).single;
    return digest.toString();
  }

  /// Verify that a collection of sorted chunks produces the expected SHA-256.
  static Future<bool> verifyChunks(
    List<Uint8List> chunks,
    String expectedSha256,
  ) async {
    final digestSink = _DigestSink();
    final conversionSink = sha256.startChunkedConversion(digestSink);
    for (final chunk in chunks) {
      conversionSink.add(chunk);
    }
    conversionSink.close();
    final actual = digestSink.value.toString();
    return actual.toLowerCase() == expectedSha256.toLowerCase();
  }

  // -- Temp directory for in-progress transfers -------------------------------

  static Future<Directory> getTempDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final tempDir = Directory('${appDir.path}${Platform.pathSeparator}.fastdrop-temp');
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }
    return tempDir;
  }

  // -- Downloads directory ----------------------------------------------------

  /// SharedPreferences key for the custom download directory.
  static const String _downloadDirKey = 'fastdrop_download_dir';

  /// Returns the download directory. If the user has set a custom path
  /// via SharedPreferences, that path is used; otherwise falls back to
  /// `<appDocuments>/FastDrop`.
  static Future<Directory> getDownloadsDir({String subDir = 'FastDrop'}) async {
    final prefs = await SharedPreferences.getInstance();
    final custom = prefs.getString(_downloadDirKey);
    if (custom != null && custom.isNotEmpty) {
      final dir = Directory(custom);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}${Platform.pathSeparator}$subDir');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// Save a custom download directory path to SharedPreferences.
  static Future<void> setCustomDownloadDir(String path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path.isEmpty) {
      await prefs.remove(_downloadDirKey);
    } else {
      await prefs.setString(_downloadDirKey, path);
    }
  }

  /// Get the current custom download directory path (or null if default).
  static Future<String?> getCustomDownloadDir() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_downloadDirKey);
  }

  // -- Upload relocation (B 方案：逐文件懒搬迁) -------------------------------

  /// 将 file_picker 缓存中的选取文件搬迁到应用私有上传目录（稳定、不被
  /// 系统回收、.nomedia 防相册重复），返回稳定路径供上传读取。
  /// 源缺失/拷贝失败时返回原路径（尽力上传）；重名追加序号（M14）。
  static Future<String> relocateToUploadDir(
      String sourcePath, String fileName) async {
    try {
      final src = File(sourcePath);
      if (!src.existsSync()) return sourcePath;
      final support = await getApplicationSupportDirectory();
      final uploadDir =
          Directory('${support.path}${Platform.pathSeparator}fastdrop_upload');
      if (!uploadDir.existsSync()) {
        uploadDir.createSync(recursive: true);
      }
      _ensureNoMedia(uploadDir);

      final separator = Platform.pathSeparator;
      var destPath = '${uploadDir.path}$separator$fileName';
      var counter = 1;
      while (File(destPath).existsSync()) {
        final dotIndex = fileName.lastIndexOf('.');
        final stem = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
        final ext = dotIndex > 0 ? fileName.substring(dotIndex) : '';
        destPath = '${uploadDir.path}$separator$stem ($counter)$ext';
        counter++;
      }
      await src.copy(destPath);
      // 删除 file_picker 缓存副本（立即回收，关闭 MediaScanner 竞态窗口）。
      try {
        await src.delete();
      } catch (_) {}
      return destPath;
    } catch (_) {
      // 搬迁失败（缓存副本被系统回收等）：回退用原路径尽力上传。
      return sourcePath;
    }
  }

  static void _ensureNoMedia(Directory dir) {
    try {
      final marker = File('${dir.path}${Platform.pathSeparator}.nomedia');
      if (!marker.existsSync()) marker.createSync();
    } catch (_) {}
  }

  // -- Part-file helpers ------------------------------------------------------

  /// Generate the path for a `.part` temp file.
  static Future<String> partFilePath(String transferId, String fileId) async {
    final tempDir = await getTempDir();
    final transferDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}$transferId',
    );
    if (!transferDir.existsSync()) {
      transferDir.createSync(recursive: true);
    }
    return '${transferDir.path}${Platform.pathSeparator}$fileId.part';
  }

  /// Atomically move a `.part` file to the final destination.
  ///
  /// 产品决策 B：Android 上默认经 MediaStore 落盘到**公共媒体目录**
  /// （图片 → Pictures/FastDrop 相册可见，视频 → Movies/FastDrop，
  /// 其他 → Downloads/FastDrop），重名由 MediaStore 自动追加 "(1)"。
  /// 用户设置了自定义目录、或 MediaStore 失败时，退回应用内目录的
  /// 旧逻辑（rename + 跨卷拷贝 fallback），保证接收不失败。
  static Future<String> movePartToFinal(
    String partPath,
    String originalFileName, {
    String? mimeType,
  }) async {
    if (Platform.isAndroid) {
      final custom = await getCustomDownloadDir();
      if (custom == null || custom.isEmpty) {
        try {
          final publicPath = await saveToPublicStorage(
            sourcePath: partPath,
            fileName: originalFileName,
            mimeType: mimeType ?? _mimeTypeForFileName(originalFileName),
          );
          // 公共目录落盘成功，.part 已无用；清理空的传输临时目录。
          try {
            await File(partPath).delete();
          } catch (_) {}
          final transferDir = File(partPath).parent;
          try {
            if (transferDir.listSync().isEmpty) transferDir.deleteSync();
          } catch (_) {}
          return publicPath;
        } catch (e) {
          // 极少发生（存储满/MediaStore 异常）：退回应用内目录，保证接收成功。
          // （静默回退即可——接收本身仍然成功，路径照常入历史记录。）
        }
      }
    }

    final downloadsDir = await getDownloadsDir();
    final sanitized = sanitizeFileName(originalFileName);
    var finalPath =
        '${downloadsDir.path}${Platform.pathSeparator}$sanitized';
    finalPath = renameOnConflict(finalPath);

    final partFile = File(partPath);
    try {
      await partFile.rename(finalPath);
    } on FileSystemException {
      // 跨卷（目标目录与临时目录不在同一分区，EXDEV）或权限受限时裸
      // rename 会失败：退化为流式拷贝到目标分区，成功后删除 .part，
      // 保证任意存储布局下接收文件都能落盘。
      await _copyToFinal(partFile, finalPath);
      await partFile.delete();
    }

    // Clean up the transfer temp directory if empty.
    final transferDir = partFile.parent;
    final contents = transferDir.listSync();
    if (contents.isEmpty) {
      transferDir.deleteSync();
    }

    return finalPath;
  }

  /// B(方案)：经 MediaStore 写入公共媒体目录，返回落盘路径（DATA 列）。
  static Future<String> saveToPublicStorage({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    final value = await const MethodChannel('fastdrop/platform').invokeMethod<String>(
      'saveToPublicStorage',
      {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'mimeType': mimeType,
      },
    );
    if (value == null || value.isEmpty) {
      throw Exception('saveToPublicStorage returned no path');
    }
    return value;
  }

  /// 按扩展名推断 MIME 类型（MediaStore 集合归属与打开行为都依赖它）。
  static String _mimeTypeForFileName(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.substring(fileName.lastIndexOf('.') + 1).toLowerCase()
        : '';
    const map = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'bmp': 'image/bmp',
      'heic': 'image/heic',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'mkv': 'video/x-matroska',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'pdf': 'application/pdf',
      'txt': 'text/plain',
      'zip': 'application/zip',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  /// Stream-copy a `.part` file to [finalPath] (cross-volume rename fallback).
  static Future<void> _copyToFinal(File partFile, String finalPath) async {
    final target = File(finalPath);
    // 目标父目录确保存在（rename 路径同样受益于目录已创建的假设）。
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    try {
      await sink.addStream(partFile.openRead());
      await sink.flush();
    } catch (copyError) {
      try {
        await sink.close();
      } catch (_) {}
      // 半成品目标文件不能留在下载目录。
      try {
        if (target.existsSync()) target.deleteSync();
      } catch (_) {}
      rethrow;
    }
    await sink.close();
  }

  // -- Storage check ----------------------------------------------------------

  static const _platformChannel = MethodChannel('fastdrop/platform');

  /// Return available free space in bytes at the downloads directory.
  ///
  /// On Android, queries StatFs via a platform channel. Returns -1 when the
  /// platform cannot determine the value so callers do not reject valid large
  /// transfers based on a fabricated fallback.
  static Future<int> availableSpace() async {
    final dir = await getDownloadsDir();
    try {
      final freeBytes = await _platformChannel.invokeMethod<int>(
        'getAvailableSpace',
        {'path': dir.path},
      );
      if (freeBytes != null && freeBytes >= 0) return freeBytes;
    } on PlatformException {
      // Channel not implemented — fall through to default.
    } on MissingPluginException {
      // Channel not registered — fall through to default.
    }
    return -1;
  }
}

/// Internal sink that captures a [Digest] for later retrieval.
class _DigestSink implements Sink<Digest> {
  Digest? _value;

  @override
  void add(Digest data) {
    _value = data;
  }

  @override
  void close() {}

  Digest get value {
    if (_value == null) {
      throw StateError('Digest not yet computed');
    }
    return _value!;
  }
}
