import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:fastdrop_mobile/core/errors/app_error.dart';
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
    Future<void> Function()? beforeAttempt,
    Future<void> Function(Duration duration)? delay,
    Random? random,
  }) async {
    final path =
        '/api/v1/transfers/$transferId/files/$fileId/chunks/$chunkIndex';

    int attempt = 0;
    Exception? lastError;

    while (attempt <= maxRetries) {
      // Pause/cancel gates run outside the retry catch so their exceptions do
      // not consume a network retry attempt.
      await beforeAttempt?.call();
      try {
        await client.putBytes(path, data);
        return; // success
      } on Exception catch (e) {
        lastError = e;
        attempt++;
        if (attempt > maxRetries || !_isRetryable(e)) break;

        // Exponential backoff with jitter.
        final backoffIndex = (attempt - 1).clamp(0, _backoffMs.length - 1);
        final backoff = _backoffMs[backoffIndex];
        final jitter = (random ?? Random()).nextInt(backoff ~/ 2 + 1);
        final duration = Duration(milliseconds: backoff + jitter);
        await (delay ?? Future<void>.delayed)(duration);
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

  static bool _isRetryable(Exception error) {
    if (error is! AppError) return true;
    final status = error.statusCode;
    if (status == 408 || status == 429 || (status != null && status >= 500)) {
      return true;
    }
    return error.code == 'CHUNK_HASH_MISMATCH' ||
        error.code == 'TOO_MANY_REQUESTS' ||
        error.code == ErrorCodes.internalError;
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
