import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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

  static Future<Directory> getDownloadsDir({String subDir = 'FastDrop'}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}${Platform.pathSeparator}$subDir');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
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
  static Future<String> movePartToFinal(
    String partPath,
    String originalFileName,
  ) async {
    final downloadsDir = await getDownloadsDir();
    final sanitized = sanitizeFileName(originalFileName);
    var finalPath =
        '${downloadsDir.path}${Platform.pathSeparator}$sanitized';
    finalPath = renameOnConflict(finalPath);

    final partFile = File(partPath);
    await partFile.rename(finalPath);

    // Clean up the transfer temp directory if empty.
    final transferDir = partFile.parent;
    final contents = transferDir.listSync();
    if (contents.isEmpty) {
      transferDir.deleteSync();
    }

    return finalPath;
  }

  // -- Storage check ----------------------------------------------------------

  static const _platformChannel = MethodChannel('fastdrop/platform');

  /// Return available free space in bytes at the downloads directory.
  ///
  /// On Android, queries StatFs via a platform channel. Falls back to 1 GB
  /// if the channel is unavailable (e.g. running on desktop or in tests).
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
    return 1024 * 1024 * 1024; // Fallback: assume 1 GB.
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
