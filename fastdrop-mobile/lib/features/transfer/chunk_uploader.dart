import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:fastdrop_mobile/core/network/http_client.dart';

/// Uploads a single chunk to the FastDrop backend with retry logic.
///
/// PUT /api/v1/transfers/{transferId}/files/{fileId}/chunks/{chunkIndex}
/// Body: raw bytes (Content-Type: application/octet-stream)
/// Max 5 retries with exponential backoff (500ms, 1s, 2s, 4s, 8s).
class ChunkUploader {
  ChunkUploader._();

  static const int _maxRetries = 5;
  static const List<int> _backoffMs = [500, 1000, 2000, 4000, 8000];

  /// Upload a single chunk with automatic retry on failure.
  ///
  /// Throws if all retries are exhausted.
  static Future<void> upload({
    required FastDropHttpClient client,
    required String transferId,
    required String fileId,
    required int chunkIndex,
    required Uint8List data,
    int maxRetries = _maxRetries,
  }) async {
    final path =
        '/api/v1/transfers/$transferId/files/$fileId/chunks/$chunkIndex';

    int attempt = 0;
    Exception? lastError;

    while (attempt <= maxRetries) {
      try {
        await client.putBytes(path, data);
        return; // success
      } on Exception catch (e) {
        lastError = e;
        attempt++;
        if (attempt > maxRetries) break;

        // Exponential backoff with jitter.
        final backoffIndex = (attempt - 1).clamp(0, _backoffMs.length - 1);
        final backoff = _backoffMs[backoffIndex];
        final jitter = Random().nextInt(backoff ~/ 2 + 1);
        await Future.delayed(Duration(milliseconds: backoff + jitter));
      }
    }

    throw ChunkUploadException(
      transferId: transferId,
      fileId: fileId,
      chunkIndex: chunkIndex,
      attempts: attempt,
      cause: lastError,
    );
  }
}

/// Thrown when all chunk upload retries are exhausted.
class ChunkUploadException implements Exception {
  const ChunkUploadException({
    required this.transferId,
    required this.fileId,
    required this.chunkIndex,
    required this.attempts,
    this.cause,
  });

  final String transferId;
  final String fileId;
  final int chunkIndex;
  final int attempts;
  final Exception? cause;

  @override
  String toString() {
    return 'ChunkUploadException: failed to upload chunk $chunkIndex '
        'for file $fileId (transfer $transferId) after $attempts attempts';
  }
}
