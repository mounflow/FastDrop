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

    // Attempts are counted inside the action so ChunkUploadException can
    // still report how many network tries were made.
    var attempts = 0;
    try {
      await retry(
        () {
          attempts++;
          // 4 MB 数据请求使用更长的 per-request 超时（L7）。
          return client.putBytes(
            path,
            data,
            timeout: FastDropHttpClient.largeTransferTimeout,
          );
        },
        maxRetries: maxRetries,
        beforeAttempt: beforeAttempt,
        delay: delay,
        random: random,
      );
    } on Exception catch (e) {
      throw ChunkUploadException(
        transferId: transferId,
        fileId: fileId,
        chunkIndex: chunkIndex,
        attempts: attempts,
        cause: e,
      );
    }
  }

  /// Run [action] with the shared retry policy: at most [maxRetries] retries
  /// (5 by default) with exponential backoff (500ms, 1s, 2s, 4s, 8s).
  ///
  /// Session/validation errors are not retried ([_isRetryable]); the last
  /// error is rethrown to the caller. Shared by chunk upload and Range
  /// download so both sides follow the same backoff curve.
  static Future<T> retry<T>(
    Future<T> Function() action, {
    int maxRetries = _maxRetries,
    Future<void> Function()? beforeAttempt,
    Future<void> Function(Duration duration)? delay,
    Random? random,
  }) async {
    int attempt = 0;

    while (true) {
      // Pause/cancel gates run outside the retry catch so their exceptions do
      // not consume a network retry attempt.
      await beforeAttempt?.call();
      try {
        return await action();
      } on Exception catch (e) {
        attempt++;
        if (attempt > maxRetries || !_isRetryable(e)) throw e;

        // Exponential backoff with jitter.
        final backoffIndex = (attempt - 1).clamp(0, _backoffMs.length - 1);
        final backoff = _backoffMs[backoffIndex];
        final jitter = (random ?? Random()).nextInt(backoff ~/ 2 + 1);
        final duration = Duration(milliseconds: backoff + jitter);
        await (delay ?? Future<void>.delayed)(duration);
      }
    }
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
    return 'ChunkUploadException: 分块 $chunkIndex 上传失败'
        '（文件 $fileId，传输 $transferId），已尝试 $attempts 次';
  }
}
