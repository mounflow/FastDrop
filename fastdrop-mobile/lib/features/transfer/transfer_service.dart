import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:fastdrop_mobile/core/errors/app_error.dart';
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

typedef TransferReadyCallback = Future<void> Function(String transferId);

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
    this.waitForReady,
    this.cleanupSourceFiles = true,
    this.fileLimiter,
  });

  final FastDropHttpClient httpClient;
  final FastDropWsClient? wsClient;

  /// Called every ~200-500ms with per-file progress.
  final TransferProgressCallback? onProgress;

  /// Called when a transfer batch reaches a terminal state.
  final TransferStateCallback? onStateChange;

  /// Waits for receivers that require explicit user acceptance before their
  /// first chunk can be uploaded. Desktop receivers leave this null.
  final TransferReadyCallback? waitForReady;

  /// Fan-out disables per-service cleanup because all recipients read the
  /// same private picker copy. The pool removes it once every send settles.
  final bool cleanupSourceFiles;

  /// Shared by the M:N pool so the two-file ceiling applies across all
  /// recipients, not once per peer.
  final HttpRequestLimiter? fileLimiter;

  // ---------------------------------------------------------------------------
  // Concurrency limits (matching Go backend spec)
  // ---------------------------------------------------------------------------

  static const int _maxChunksPerFile = 3;
  static const int _maxConcurrentFiles = 2;

  /// 全局在途传输计数（上传+下载，跨实例共享）。App 生命周期据此在任意
  /// 传输进行中保持 Android 前台保活服务，即使"允许接收文件"开关是关闭
  /// 的（问题 8：纯发送场景此前完全没有保活，切后台数分钟后被系统冻结）。
  static int _activeTransfers = 0;
  static bool get hasActiveTransfers => _activeTransfers > 0;
  static void _beginActiveTransfer() => _activeTransfers++;
  static void _endActiveTransfer() {
    if (_activeTransfers > 0) _activeTransfers--;
  }

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  final Map<String, _FileUploadState> _uploadStates = {};

  // Pause gates are keyed by the local offerId. Server transferIds are
  // resolved through [_transferIdToOfferId].
  final Map<String, _PauseController> _pauseControllers = {};

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
    final pauseController = _PauseController();
    _cancelTokens[batchOfferId] = cancelToken;
    _pauseControllers[batchOfferId] = pauseController;
    var callbackTransferId = batchOfferId;
    _beginActiveTransfer();

    // Declared outside try so the finally block can clean up temp copies.
    final fileInfos = <_FileInfo>[];

    try {
      // 1. 校验文件存在（廉价 stat，不做全量哈希/拷贝）——批次立即创建，
      //    传输页秒出"准备中"卡片；搬迁与哈希逐文件懒执行（B 方案）。
      onStateChange?.call(batchOfferId, 'preparing');
      for (final path in filePaths) {
        final file = File(path);
        if (!await file.exists()) {
          debugPrint('[TransferService] skip missing file: $path');
          continue;
        }
        fileInfos.add(_FileInfo(
          path: path,
          name: _extractFileName(path),
          size: await file.length(),
          sha256: '',
        ));
        if (cancelToken.isCancelled) return;
      }
      if (fileInfos.isEmpty) {
        throw FileSystemException('No selectable files remain', filePaths.first);
      }

      // 2. Create the transfer batch on the server.
      //    sha256 留空：每个文件的哈希在其上传前计算、complete 时提交，
      //    服务端按该哈希校验完整性（安全语义不变）。
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
      callbackTransferId = createResult.transferId;
      debugPrint('[TransferService] transferId=${createResult.transferId} '
          'files=${createResult.files.map((f) => f.fileId).toList()}');

      if (cancelToken.isCancelled) return;

      // Store mapping so cancel-by-transferId works.
      _transferIdToOfferId[createResult.transferId] = batchOfferId;

      if (waitForReady != null) {
        onStateChange?.call(createResult.transferId, 'waiting_accept');
        await waitForReady!(createResult.transferId);
      }
      onStateChange?.call(createResult.transferId, 'transferring');

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

      // 4. Upload files with concurrency limits. 单文件失败不中止整批。
      final batchResult = await _uploadBatch(
        transferId: createResult.transferId,
        fileTasks: fileTasks,
        cancelToken: cancelToken,
        pauseController: pauseController,
      );

      if (cancelToken.isCancelled) {
        onStateChange?.call(createResult.transferId, 'cancelled');
        return;
      }

      if (batchResult.failedCount > 0) {
        // 部分文件失败时整批以 failed 收尾，但保留已完成文件的结果，
        // errorMessage 注明失败比例（M13）。
        final errorCode =
            batchResult.firstError != null && _isSessionError(batchResult.firstError!)
                ? ErrorCodes.sessionExpired
                : ErrorCodes.transferFailed;
        final message = '${batchResult.failedCount}/${fileTasks.length} 个文件失败';
        onStateChange?.call(
          createResult.transferId,
          'failed',
          errorCode: errorCode,
          errorMessage: message,
        );
        // 问题 7②：主动告知 PC，避免其权威传输行永久停留在"传输中"。
        _notifyPeerTransferFailed(
          createResult.transferId,
          errorCode,
          message,
        );
        return;
      }

      onStateChange?.call(createResult.transferId, 'completed');
    } catch (e) {
      debugPrint('[TransferService] uploadFiles error: $e');
      if (cancelToken.isCancelled) {
        onStateChange?.call(callbackTransferId, 'cancelled');
      } else {
        // 会话类错误（401 / SESSION_*）单独标注，供 UI 引导重新配对（L13）。
        onStateChange?.call(
          callbackTransferId,
          'failed',
          errorCode: _errorCodeFor(e),
          errorMessage: e.toString(),
        );
        // 问题 7②：任务已在服务端创建过才上报（否则服务端没有这一行）。
        if (callbackTransferId != batchOfferId) {
          _notifyPeerTransferFailed(
            callbackTransferId,
            _errorCodeFor(e),
            e.toString(),
          );
        }
      }
      rethrow;
    } finally {
      // Clean up private temp copies created by the file picker
      // relocation step (fastdrop_upload directory). Runs on success,
      // failure, AND cancel so no scannable images linger on disk.
      for (final fi in fileInfos) {
        try {
          final cached = File(fi.path);
          if (cleanupSourceFiles &&
              fi.path.contains('fastdrop_upload') &&
              await cached.exists()) {
            await cached.delete();
          }
        } catch (_) {
          // Best-effort cleanup.
        }
      }
      _cancelTokens.remove(batchOfferId);
      _pauseControllers.remove(batchOfferId)?.resume();
      _transferIdToOfferId.removeWhere((_, offerId) => offerId == batchOfferId);
      _endActiveTransfer();
    }
  }

  /// Download a file from the PC (server_to_client direction).
  ///
  /// Downloads in 4 MB chunks using Range requests, writes to a temp part file,
  /// verifies SHA-256, and moves to the final download path.
  ///
  /// 支持断点续传（H10）：`.part` 已存在时按其长度对齐到完整块边界后继续；
  /// 下载失败保留 `.part` 供下次续传，仅取消与哈希不一致时清理。
  Future<String> downloadFile({
    required String transferId,
    required String fileId,
    required String fileName,
    required int totalBytes,
    required String expectedSha256,
  }) async {
    final partPath = await FileUtils.partFilePath(transferId, fileId);
    final pauseController =
        _pauseControllers.putIfAbsent(transferId, _PauseController.new);
    // 为下载注册取消令牌（M15）：复用 _cancelTokens 机制，key 用 transferId，
    // cancelTransfer(transferId) 即可触发。
    final cancelToken = _cancelTokens.putIfAbsent(transferId, CancelToken.new);
    _beginActiveTransfer();

    try {
      final chunkSize = FileUtils.chunkSize;
      final totalChunks = (totalBytes + chunkSize - 1) ~/ chunkSize;

      // 续传对齐：按已有 .part 长度折算起始块。尾部不足一块的残余数据无法
      // 保证完整，截断丢弃；异常超长的 .part（> totalBytes）直接作废重传。
      final partFile = File(partPath);
      final existingLen = await partFile.exists() ? await partFile.length() : 0;
      final partChunks = existingLen ~/ chunkSize;
      final startChunk = partChunks < totalChunks ? partChunks : 0;

      // Dart RAF 语义说明：FileMode.write 打开即截断，无法续传；FileMode.append
      // 与 write 的区别仅是不截断、初始位置在文件末尾（且 POSIX 实现落在
      // O_APPEND 上，setPosition 对写入终点不可靠）。因此这里以 append 打开
      // 后先 truncate 到对齐边界，再逐块顺序写入——每块都紧跟上一块追加，
      // 不依赖 setPosition，写入顺序由顺序 await 保证。
      final raf = await partFile.open(mode: FileMode.append);
      try {
        await raf.truncate(startChunk * chunkSize);
        for (int i = startChunk; i < totalChunks; i++) {
          if (cancelToken.isCancelled) {
            throw const _TransferCancelledException();
          }
          await pauseController.waitWhilePaused();

          final start = i * chunkSize;
          final end = ((start + chunkSize - 1) < (totalBytes - 1))
              ? (start + chunkSize - 1)
              : (totalBytes - 1);

          // 与 ChunkUploader 同款 5 次退避重试（500ms..8s），401/403 等会话类
          // 错误不重试；4 MB 数据请求使用更长的 per-request 超时（L7）。
          final response = await ChunkUploader.retry(
            () => httpClient.get(
              '/api/v1/transfers/$transferId/files/$fileId/content',
              headers: {'Range': 'bytes=$start-$end'},
              timeout: FastDropHttpClient.largeTransferTimeout,
            ),
            beforeAttempt: () async {
              await pauseController.waitWhilePaused();
              if (cancelToken.isCancelled) {
                throw const _TransferCancelledException();
              }
            },
          );

          final bodyBytes = response.bodyBytes;
          if (bodyBytes.length != end - start + 1) {
            throw Exception(
              'Range response truncated for $fileName: '
              'expected ${end - start + 1} bytes, got ${bodyBytes.length}',
            );
          }
          // append 模式写入总落在文件末尾，顺序写入即块序。
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
          // 整个文件内容已损坏，续传无从谈起：删除 .part 让下次全新下载。
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
    } on Exception catch (e) {
      if (e is _TransferCancelledException) {
        // 取消即中止并清理 .part（M15）；cancelTransfer 已删整个临时目录，
        // 这里兜底处理目录删除失败（如 Windows 下句柄未释放）的情况。
        try {
          if (await File(partPath).exists()) {
            await File(partPath).delete();
          }
        } catch (_) {}
      } else {
        // 下载失败保留 .part 供断点续传（H10c），仅上报失败状态。
        debugPrint('[TransferService] downloadFile failed: $e');
        onStateChange?.call(
          transferId,
          'failed',
          errorCode: _errorCodeFor(e),
          errorMessage: e.toString(),
        );
      }
      rethrow;
    } finally {
      _endActiveTransfer();
      if (identical(_pauseControllers[transferId], pauseController)) {
        _pauseControllers.remove(transferId)?.resume();
      }
      if (identical(_cancelTokens[transferId], cancelToken)) {
        _cancelTokens.remove(transferId);
      }
    }
  }

  /// Stop scheduling new chunks for an active upload or download.
  void pauseTransfer(String identifier) {
    _pauseControllerFor(identifier)?.pause();
  }

  /// Release a paused upload or download so it continues from its next chunk.
  void resumeTransfer(String identifier) {
    _pauseControllerFor(identifier)?.resume();
  }

  /// 问题 7②：把批次失败上报给 PC（fire-and-forget）。PC 端据此把权威
  /// 传输行置为 failed 并清理临时文件；socket 已断时静默丢弃——那种情况
  /// 由 PC 端的断线宽限兜底（H7）。
  void _notifyPeerTransferFailed(String transferId, String code, String message) {
    try {
      wsClient?.send({
        'version': 1,
        'type': 'transfer.failed',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'payload': {'transferId': transferId, 'code': code, 'reason': message},
      });
    } catch (_) {
      // Best-effort：本端状态已正确，上报失败不影响本地流程。
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
    _pauseControllerFor(identifier)?.resume();

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
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    for (final controller in _pauseControllers.values) {
      controller.resume();
    }
    _pauseControllers.clear();
    _transferIdToOfferId.clear();
  }

  // ---------------------------------------------------------------------------
  // Private: upload orchestration
  // ---------------------------------------------------------------------------

  /// Upload all files in [fileTasks] respecting concurrency limits.
  ///
  /// 单文件失败只计入结果并继续其余文件，不中止整批（M13）。
  Future<_BatchResult> _uploadBatch({
    required String transferId,
    required List<_FileUploadTask> fileTasks,
    required CancelToken cancelToken,
    required _PauseController pauseController,
  }) async {
    final result = _BatchResult();
    // Process files in groups of up to _maxConcurrentFiles.
    for (int i = 0; i < fileTasks.length; i += _maxConcurrentFiles) {
      if (cancelToken.isCancelled) return result;
      await pauseController.waitWhilePaused();
      if (cancelToken.isCancelled) return result;

      final group = fileTasks.skip(i).take(_maxConcurrentFiles).toList();
      await Future.wait(
        group.map((task) {
          Future<void> upload() async {
            try {
              await _uploadFile(
                transferId: transferId,
                task: task,
                cancelToken: cancelToken,
                pauseController: pauseController,
              );
            } catch (e) {
              result.failedCount++;
              result.firstError ??= e;
              debugPrint('[TransferService] file ${task.fileInfo.name} '
                  'failed (${result.failedCount}/${fileTasks.length}): $e');
            }
          }

          return fileLimiter?.run(upload) ?? upload();
        }),
      );
    }
    return result;
  }

  /// Upload all chunks for a single file, with up to [_maxChunksPerFile]
  /// chunks in flight at a time.
  Future<void> _uploadFile({
    required String transferId,
    required _FileUploadTask task,
    required CancelToken cancelToken,
    required _PauseController pauseController,
  }) async {
    final fi = task.fileInfo;
    final fr = task.fileResult;
    final totalChunks = task.totalChunks;
    final chunkSize = FileUtils.chunkSize;

    final state = _FileUploadState();
    _uploadStates[fr.fileId] = state;

    debugPrint('[TransferService] _uploadFile: ${fi.name} '
        '(size=${fi.size}, chunks=$totalChunks, fileId=${fr.fileId})');

    // B(方案)：搬迁与哈希按文件懒执行——创建批次不再等待全量拷贝与
    // 全量哈希；complete 时服务端按此处计算的哈希校验完整性。
    // 搬迁：file_picker 缓存 → 应用私有稳定目录（.nomedia 防相册重复，
    // 不被系统回收）；哈希对稳定副本计算。
    if (cancelToken.isCancelled) return;
    final readPath = await FileUtils.relocateToUploadDir(fi.path, fi.name);
    fi.path = readPath;
    if (cancelToken.isCancelled) return;
    if (fi.sha256.isEmpty) {
      fi.sha256 = await FileUtils.computeFileSha256(readPath);
    }

    try {
      final file = File(fi.path);
      int chunkIndex = 0;

      while (chunkIndex < totalChunks) {
        if (cancelToken.isCancelled) break;
        await pauseController.waitWhilePaused();
        if (cancelToken.isCancelled) break;

        // Determine how many chunks we can launch this round.
        final remaining = totalChunks - chunkIndex;
        final batchSize = min(remaining, _maxChunksPerFile - state.inFlight);

        if (batchSize <= 0) {
          // All slot full; wait for one to complete.
          await state.onSlotFree();
          continue;
        }

        // Launch a batch of chunk uploads.
        final futures = <Future<void>>[];
        for (int j = 0; j < batchSize; j++) {
          // chunkIndex is advanced at the end of each iteration, so it is
          // already the next unscheduled chunk. Adding j here would skip
          // chunk 1 and eventually try to read one chunk past EOF.
          final idx = chunkIndex;
          final start = idx * chunkSize;
          final end = min(start + chunkSize, fi.size);

          // Open-seek-read-close per chunk. Keeping a single
          // RandomAccessFile open for the whole upload (~30 s on a
          // 200 MB file) triggers FileSystemException errno=0 on
          // some Android devices (Xiaomi / MIUI FUSE storage).
          final raf = await file.open(mode: FileMode.read);
          await raf.setPosition(start);
          final data = await raf.read(end - start);
          await raf.close();

          state.inFlight++;
          final f = () async {
            try {
              await ChunkUploader.upload(
                client: httpClient,
                transferId: transferId,
                fileId: fr.fileId,
                chunkIndex: idx,
                data: data,
                beforeAttempt: () async {
                  await pauseController.waitWhilePaused();
                  if (cancelToken.isCancelled) {
                    throw const _TransferCancelledException();
                  }
                },
              );
              debugPrint('[TransferService] chunk $idx uploaded OK '
                  '(${data.length} bytes)');
              state.bytesUploaded += data.length;

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
                    status:
                        pauseController.isPaused ? 'paused' : 'transferring',
                  ),
                );
              }
            } catch (e) {
              debugPrint('[TransferService] chunk $idx FAILED: $e');
              rethrow;
            } finally {
              state.inFlight--;
              state._slotCompleter?.complete();
              state._slotCompleter = null;
            }
          }();

          futures.add(f);
          chunkIndex++;
        }

        await Future.wait(futures);
        debugPrint('[TransferService] chunk batch done, '
            'chunkIndex=$chunkIndex/$totalChunks');
      }

      if (cancelToken.isCancelled) return;

      await pauseController.waitWhilePaused();
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
      _uploadStates.remove(fr.fileId);
    }
  }

  // ---------------------------------------------------------------------------
  // Private: helpers
  // ---------------------------------------------------------------------------

  /// Whether [error] is a session-class failure (401 / `SESSION_*` code),
  /// including ones wrapped by [ChunkUploadException].
  static bool _isSessionError(Object error) {
    final appError = error is ChunkUploadException ? error.cause : error;
    return appError is AppError &&
        (appError.code.startsWith('SESSION_') || appError.statusCode == 401);
  }

  /// Map an exception to a stable error code for state callbacks (L13).
  static String _errorCodeFor(Object error) {
    if (_isSessionError(error)) return ErrorCodes.sessionExpired;
    return error is ChunkUploadException
        ? ErrorCodes.transferFailed
        : ErrorCodes.internalError;
  }

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

  _PauseController? _pauseControllerFor(String identifier) {
    final offerId = _transferIdToOfferId[identifier] ?? identifier;
    return _pauseControllers[offerId] ?? _pauseControllers[identifier];
  }
}

// ---------------------------------------------------------------------------
// Private types
// ---------------------------------------------------------------------------

class _FileInfo {
  _FileInfo({
    required this.path,
    required this.name,
    required this.size,
    required this.sha256,
  });

  /// 可变：批次创建后逐文件搬迁（缓存 → 应用私有稳定目录）会更新该路径，
  /// 哈希也在搬迁后的稳定副本上计算（创建批次时留空、complete 时提交）。
  String path;
  final String name;
  final int size;
  String sha256;
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

/// Aggregated outcome of one upload batch (M13).
class _BatchResult {
  int failedCount = 0;

  /// First failure observed, used to classify the batch error code.
  Object? firstError;
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

class _PauseController {
  bool _paused = false;
  Completer<void>? _resumeCompleter;

  bool get isPaused => _paused;

  void pause() {
    if (_paused) return;
    _paused = true;
    _resumeCompleter = Completer<void>();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    final completer = _resumeCompleter;
    _resumeCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> waitWhilePaused() async {
    while (_paused) {
      await _resumeCompleter!.future;
    }
  }
}

class _TransferCancelledException implements Exception {
  const _TransferCancelledException();
}
