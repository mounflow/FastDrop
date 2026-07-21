import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/network/ws_client.dart';
import 'package:fastdrop_mobile/core/utils/file_utils.dart';
import 'package:fastdrop_mobile/features/transfer/chunk_uploader.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';

/// Callback for progress updates during a transfer.
typedef TransferProgressCallback = void Function(
  String transferId,
  String fileId,
  TransferProgress progress,
);

/// Callback for transfer state changes (completed, failed, cancelled).
typedef TransferStateCallback = void Function(
  String transferId,
  String status, {
  String? errorCode,
  String? errorMessage,
});

/// Core business logic for file transfers between the phone and the PC.
///
/// Handles chunk splitting, concurrent upload with spec limits
/// (3 chunks/file, 2 files concurrent, 6 max global HTTP), SHA-256
/// verification, retries, and progress reporting.
class TransferService {
  TransferService({
    required this.httpClient,
    this.wsClient,
    this.onProgress,
    this.onStateChange,
  });

  final FastDropHttpClient httpClient;
  final FastDropWsClient? wsClient;

  /// Called every ~200-500ms with per-file progress.
  final TransferProgressCallback? onProgress;

  /// Called when a transfer batch reaches a terminal state.
  final TransferStateCallback? onStateChange;

  // ---------------------------------------------------------------------------
  // Concurrency limits (matching Go backend spec)
  // ---------------------------------------------------------------------------

  static const int _maxChunksPerFile = 3;
  static const int _maxConcurrentFiles = 2;
  static const int _maxGlobalHttp = 6;

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  final Map<String, _FileUploadState> _uploadStates = {};
  bool _disposed = false;

  // Token for cancelling an in-flight transfer, keyed by offerId.
  final Map<String, CancelToken> _cancelTokens = {};

  // Maps server-assigned transferIds to offerIds for cancellation lookup.
  final Map<String, String> _transferIdToOfferId = {};

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Upload a list of files to the PC (client_to_server direction).
  ///
  /// Flow:
  /// 1. Compute SHA-256 for each file.
  /// 2. POST /api/v1/transfers to create the transfer batch.
  /// 3. Split each file into 4 MB chunks.
  /// 4. Upload chunks respecting concurrency limits (3 per file, 2 files).
  /// 5. POST /complete for each file after all its chunks are uploaded.
  /// 6. Report progress throughout.
  Future<void> uploadFiles(
    List<String> filePaths, {
    String? offerId,
  }) async {
    if (filePaths.isEmpty) return;

    final batchOfferId = offerId ?? _generateOfferId();
    final cancelToken = CancelToken();
    _cancelTokens[batchOfferId] = cancelToken;

    try {
      // 1. Validate all files exist and compute SHA-256.
      final fileInfos = <_FileInfo>[];
      for (final path in filePaths) {
        final file = File(path);
        if (!await file.exists()) {
          throw FileSystemException('File not found', path);
        }
        final size = await file.length();
        final sha256 = await FileUtils.computeFileSha256(path);
        final name = _extractFileName(path);
        fileInfos.add(_FileInfo(
          path: path,
          name: name,
          size: size,
          sha256: sha256,
        ));
      }

      if (cancelToken.isCancelled) return;

      // 2. Create the transfer batch on the server.
      final createBody = CreateTransferBody(
        offerId: batchOfferId,
        direction: 'client_to_server',
        files: fileInfos.map((fi) {
          return TransferFileInput(
            clientFileId: _shortHash(fi.path),
            name: fi.name,
            size: fi.size,
            sha256: fi.sha256,
            mimeType: _mimeTypeForExtension(fi.name),
          );
        }).toList(),
      );

      final createResponse = await httpClient.post(
        '/api/v1/transfers',
        body: createBody.toJson(),
      );
      debugPrint('[TransferService] transfer created: '
          '${createResponse.statusCode}');
      final createResult = CreateTransferResult.fromJson(
        jsonDecode(createResponse.body) as Map<String, dynamic>,
      );
      debugPrint('[TransferService] transferId=${createResult.transferId} '
          'files=${createResult.files.map((f) => f.fileId).toList()}');

      if (cancelToken.isCancelled) return;

      // Store mapping so cancel-by-transferId works.
      _transferIdToOfferId[createResult.transferId] = batchOfferId;

      // 3. Build the chunk plan for each file.
      final chunkSize = FileUtils.chunkSize;
      final fileTasks = <_FileUploadTask>[];
      for (int i = 0; i < fileInfos.length; i++) {
        final fi = fileInfos[i];
        final fr = createResult.files[i];
        final totalChunks = (fi.size + chunkSize - 1) ~/ chunkSize;
        fileTasks.add(_FileUploadTask(
          fileInfo: fi,
          fileResult: fr,
          totalChunks: totalChunks,
        ));
      }

      // 4. Upload files with concurrency limits.
      await _uploadBatch(
        transferId: createResult.transferId,
        fileTasks: fileTasks,
        cancelToken: cancelToken,
      );

      onStateChange?.call(createResult.transferId, 'completed');

      // Clean up file_picker cache copies to avoid duplicate photos
      // in the Android gallery.
      for (final fi in fileInfos) {
        try {
          final cached = File(fi.path);
          if (fi.path.contains('file_picker') && await cached.exists()) {
            await cached.delete();
          }
        } catch (_) {
          // Best-effort cleanup.
        }
      }
    } catch (e) {
      debugPrint('[TransferService] uploadFiles error: $e');
      if (cancelToken.isCancelled) {
        onStateChange?.call(batchOfferId, 'cancelled');
      } else {
        final code = e is ChunkUploadException ? 'TRANSFER_FAILED' : 'INTERNAL_ERROR';
        onStateChange?.call(
          batchOfferId,
          'failed',
          errorCode: code,
          errorMessage: e.toString(),
        );
      }
      rethrow;
    } finally {
      _cancelTokens.remove(batchOfferId);
      _transferIdToOfferId
          .removeWhere((_, offerId) => offerId == batchOfferId);
    }
  }

  /// Download a file from the PC (server_to_client direction).
  ///
  /// Downloads in 4 MB chunks using Range requests, writes to a temp part file,
  /// verifies SHA-256, and moves to the final download path.
  Future<String> downloadFile({
    required String transferId,
    required String fileId,
    required String fileName,
    required int totalBytes,
    required String expectedSha256,
  }) async {
    final partPath = await FileUtils.partFilePath(transferId, fileId);

    try {
      final chunkSize = FileUtils.chunkSize;
      final totalChunks = (totalBytes + chunkSize - 1) ~/ chunkSize;

      // Download each chunk via Range requests and write to the part file.
      final file = File(partPath);
      final raf = await file.open(mode: FileMode.write);

      try {
        for (int i = 0; i < totalChunks; i++) {
          final start = i * chunkSize;
          final end = ((start + chunkSize - 1) < (totalBytes - 1))
              ? (start + chunkSize - 1)
              : (totalBytes - 1);

          final response = await httpClient.get(
            '/api/v1/transfers/$transferId/files/$fileId/content',
            headers: {'Range': 'bytes=$start-$end'},
          );

          final bodyBytes = response.bodyBytes;
          await raf.setPosition(start);
          await raf.writeFrom(bodyBytes);

          onProgress?.call(
            transferId,
            fileId,
            TransferProgress(
              transferId: transferId,
              fileId: fileId,
              bytesTransferred: start + bodyBytes.length,
              totalBytes: totalBytes,
              fileName: fileName,
            ),
          );
        }
      } finally {
        await raf.close();
      }

      // Verify SHA-256 of the downloaded file (skip if no expected hash).
      if (expectedSha256.isNotEmpty) {
        final actualSha256 = await FileUtils.computeFileSha256(partPath);
        if (actualSha256.toLowerCase() != expectedSha256.toLowerCase()) {
          await File(partPath).delete();
          throw Exception(
            'SHA-256 mismatch for $fileName: expected $expectedSha256, got $actualSha256',
          );
        }
      }

      // Move from part file to final destination.
      final finalPath = await FileUtils.movePartToFinal(partPath, fileName);
      onStateChange?.call(transferId, 'completed');
      return finalPath;
    } on Exception {
      // Clean up partial download on failure.
      final partFile = File(partPath);
      if (await partFile.exists()) {
        await partFile.delete();
      }
      rethrow;
    }
  }

  /// Cancel an active transfer and clean up any temp files.
  ///
  /// [identifier] can be either the transfer's offerId (local) or the
  /// server-assigned transferId.
  Future<void> cancelTransfer(String identifier) async {
    // Cancel the local upload operation.
    _cancelTokens[identifier]?.cancel();
    // Also check the transferId-to-offerId mapping.
    final mappedOfferId = _transferIdToOfferId[identifier];
    if (mappedOfferId != null) {
      _cancelTokens[mappedOfferId]?.cancel();
    }

    // Notify the server via HTTP.
    try {
      await httpClient.post('/api/v1/transfers/$identifier/cancel');
    } catch (_) {
      // Best-effort; the local state is already cancelled.
    }

    // Also notify via WS so the PC UI updates immediately.
    wsClient?.send({
      'version': 1,
      'type': 'transfer.cancel',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'transferId': identifier},
    });

    // Clean up temp part files.
    try {
      final tempDir = await FileUtils.getTempDir();
      final transferDir = Directory(
        '${tempDir.path}${Platform.pathSeparator}$identifier',
      );
      if (await transferDir.exists()) {
        await transferDir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  /// Release resources held by this service.
  void dispose() {
    _disposed = true;
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _transferIdToOfferId.clear();
  }

  // ---------------------------------------------------------------------------
  // Private: upload orchestration
  // ---------------------------------------------------------------------------

  /// Upload all files in [fileTasks] respecting concurrency limits.
  Future<void> _uploadBatch({
    required String transferId,
    required List<_FileUploadTask> fileTasks,
    required CancelToken cancelToken,
  }) async {
    // Process files in groups of up to _maxConcurrentFiles.
    for (int i = 0; i < fileTasks.length; i += _maxConcurrentFiles) {
      if (cancelToken.isCancelled) return;

      final group = fileTasks.skip(i).take(_maxConcurrentFiles).toList();
      await Future.wait(
        group.map((task) => _uploadFile(
              transferId: transferId,
              task: task,
              cancelToken: cancelToken,
            )),
      );
    }
  }

  /// Upload all chunks for a single file, with up to [_maxChunksPerFile]
  /// chunks in flight at a time.
  Future<void> _uploadFile({
    required String transferId,
    required _FileUploadTask task,
    required CancelToken cancelToken,
  }) async {
    final fi = task.fileInfo;
    final fr = task.fileResult;
    final totalChunks = task.totalChunks;
    final chunkSize = FileUtils.chunkSize;

    final state = _FileUploadState();
    _uploadStates[fr.fileId] = state;

    debugPrint('[TransferService] _uploadFile: ${fi.name} '
        '(size=${fi.size}, chunks=$totalChunks, fileId=${fr.fileId})');

    try {
      final file = File(fi.path);
      final raf = await file.open(mode: FileMode.read);

      try {
        int chunkIndex = 0;

        while (chunkIndex < totalChunks) {
          if (cancelToken.isCancelled) break;

          // Determine how many chunks we can launch this round.
          final remaining = totalChunks - chunkIndex;
          final batchSize =
              min(remaining, _maxChunksPerFile - state.inFlight);

          if (batchSize <= 0) {
            // All slot full; wait for one to complete.
            await state.onSlotFree();
            continue;
          }

          // Launch a batch of chunk uploads.
          final futures = <Future<void>>[];
          for (int j = 0; j < batchSize; j++) {
            final idx = chunkIndex + j;
            final start = idx * chunkSize;
            final end = min(start + chunkSize, fi.size);
            final data = await raf.read(end - start);

            state.inFlight++;
            final f = ChunkUploader.upload(
              client: httpClient,
              transferId: transferId,
              fileId: fr.fileId,
              chunkIndex: idx,
              data: data,
            ).then((_) {
              debugPrint('[TransferService] chunk $idx uploaded OK '
                  '(${data.length} bytes)');
              state.bytesUploaded += data.length;
              state.inFlight--;
              state._slotCompleter?.complete();
              state._slotCompleter = null;

              // Emit progress at reasonable intervals.
              final now = DateTime.now();
              if (state.lastProgressUpdate == null ||
                  now.difference(state.lastProgressUpdate!).inMilliseconds >=
                      200) {
                state.lastProgressUpdate = now;
                onProgress?.call(
                  transferId,
                  fr.fileId,
                  TransferProgress(
                    transferId: transferId,
                    fileId: fr.fileId,
                    bytesTransferred: state.bytesUploaded,
                    totalBytes: fi.size,
                    fileName: fi.name,
                    speed: state.currentSpeed,
                  ),
                );
              }
            }).catchError((Object e) {
              debugPrint('[TransferService] chunk $idx FAILED: $e');
              state.inFlight--;
              throw e;
            });

            futures.add(f);
            chunkIndex++;
          }

          await Future.wait(futures);
          debugPrint('[TransferService] chunk batch done, '
              'chunkIndex=$chunkIndex/$totalChunks');
        }

        if (cancelToken.isCancelled) return;

        // All chunks uploaded — call complete.
        debugPrint('[TransferService] all chunks done for ${fi.name}, '
            'calling complete (size=${fi.size}, sha256=${fi.sha256})');
        final completeResponse = await httpClient.post(
          '/api/v1/transfers/$transferId/files/${fr.fileId}/complete',
          body: {'size': fi.size, 'sha256': fi.sha256},
        );
        debugPrint('[TransferService] complete response: '
            '${completeResponse.statusCode} ${completeResponse.body}');

        final completeResult = ChunkCompleteResult.fromJson(
          jsonDecode(completeResponse.body) as Map<String, dynamic>,
        );

        if (completeResult.sha256.toLowerCase() != fi.sha256.toLowerCase()) {
          throw Exception(
            'Server SHA-256 mismatch for ${fi.name}: '
            'expected ${fi.sha256}, got ${completeResult.sha256}',
          );
        }

        // Final progress update.
        onProgress?.call(
          transferId,
          fr.fileId,
          TransferProgress(
            transferId: transferId,
            fileId: fr.fileId,
            bytesTransferred: fi.size,
            totalBytes: fi.size,
            fileName: fi.name,
            status: 'completed',
          ),
        );
      } finally {
        await raf.close();
      }
    } finally {
      _uploadStates.remove(fr.fileId);
    }
  }

  // ---------------------------------------------------------------------------
  // Private: helpers
  // ---------------------------------------------------------------------------

  static String _generateOfferId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _shortHash(String input) {
    // FNV-1a 64-bit hash for low collision probability.
    var hash = 0xcbf29ce484222325;
    for (var i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String _extractFileName(String filePath) {
    return filePath.split('/').last.split('\\').last;
  }

  static String? _mimeTypeForExtension(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'mp4':
        return 'video/mp4';
      case 'mkv':
        return 'video/x-matroska';
      case 'avi':
        return 'video/x-msvideo';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      case 'apk':
        return 'application/vnd.android.package-archive';
      default:
        return 'application/octet-stream';
    }
  }
}

// ---------------------------------------------------------------------------
// Private types
// ---------------------------------------------------------------------------

class _FileInfo {
  const _FileInfo({
    required this.path,
    required this.name,
    required this.size,
    required this.sha256,
  });

  final String path;
  final String name;
  final int size;
  final String sha256;
}

class _FileUploadTask {
  const _FileUploadTask({
    required this.fileInfo,
    required this.fileResult,
    required this.totalChunks,
  });

  final _FileInfo fileInfo;
  final TransferFileResult fileResult;
  final int totalChunks;
}

class _FileUploadState {
  int bytesUploaded = 0;
  int inFlight = 0;
  DateTime? lastProgressUpdate;
  Completer<void>? _slotCompleter;

  int? _prevBytes;
  DateTime? _prevTime;

  /// Estimated speed in bytes per second.
  int get currentSpeed {
    final now = DateTime.now();
    if (_prevBytes == null || _prevTime == null) {
      _prevBytes = bytesUploaded;
      _prevTime = now;
      return 0;
    }
    final elapsedMs = now.difference(_prevTime!).inMilliseconds;
    _prevTime = now;
    if (elapsedMs <= 0) return 0;
    final speed = ((bytesUploaded - _prevBytes!) * 1000) ~/ elapsedMs;
    _prevBytes = bytesUploaded;
    return speed;
  }

  /// Blocks the calling code until a chunk slot frees up.
  Future<void> onSlotFree() async {
    _slotCompleter ??= Completer<void>();
    return _slotCompleter!.future;
  }
}

/// Simple cancellation token for in-flight transfers.
class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}
