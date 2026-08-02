import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:fastdrop_mobile/core/security/token.dart';
import 'package:fastdrop_mobile/core/server/session_manager.dart';
import 'package:fastdrop_mobile/core/utils/file_utils.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// Server-side file task state.
class ServerFileTask {
  ServerFileTask({
    required this.fileId,
    required this.clientFileId,
    required this.name,
    required this.size,
    this.sha256,
  });

  final String fileId;
  final String clientFileId;
  final String name;
  final int size;
  final String? sha256;

  int get totalChunks => (size / FileUtils.chunkSize).ceil();

  /// Bitmap tracking which chunks have been received.
  final Set<int> receivedChunks = {};

  int get receivedBytes => receivedChunks.length * FileUtils.chunkSize > size
      ? size
      : receivedChunks.length * FileUtils.chunkSize;

  String? partPath;
  String? finalPath;
  String status = 'pending'; // pending | transferring | completed | failed
}

/// Server-side transfer batch state.
class ServerTransfer {
  ServerTransfer({
    required this.transferId,
    required this.sessionId,
    required this.direction,
    required this.files,
    required this.createdAt,
  });

  final String transferId;
  final String sessionId;
  final String direction;
  final List<ServerFileTask> files;
  final DateTime createdAt;

  /// created → waiting_accept → preparing → transferring → verifying → completed
  /// Also: rejected, cancelled, failed
  String status = 'waiting_accept';

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
  int get transferredBytes => files.fold(0, (sum, f) => sum + f.receivedBytes);
  int get totalFiles => files.length;

  Map<String, dynamic> toJson() => {
        'transferId': transferId,
        'status': status,
        'direction': direction,
        'totalFiles': totalFiles,
        'totalBytes': totalBytes,
        'transferredBytes': transferredBytes,
        'files': files
            .map((f) => {
                  'fileId': f.fileId,
                  'name': f.name,
                  'size': f.size,
                  'status': f.status,
                  'receivedBytes': f.receivedBytes,
                })
            .toList(),
      };
}

/// Progress event pushed via WebSocket.
class TransferProgressEvent {
  const TransferProgressEvent({
    required this.transferId,
    required this.fileId,
    required this.transferredBytes,
    required this.totalBytes,
    this.fileName,
    this.status,
    this.speedBps,
  });

  final String transferId;
  final String fileId;
  final int transferredBytes;
  final int totalBytes;
  final String? fileName;
  final String? status;
  final int? speedBps;

  Map<String, dynamic> toJson() => {
        'transferId': transferId,
        'fileId': fileId,
        'transferredBytes': transferredBytes,
        'totalBytes': totalBytes,
        if (fileName != null) 'fileName': fileName,
        if (status != null) 'status': status,
        if (speedBps != null) 'speedBps': speedBps,
      };
}

/// Callback for progress events (wired to WS hub).
typedef ProgressCallback = void Function(TransferProgressEvent event);

/// Callback when a new transfer arrives and needs user confirmation.
typedef TransferRequestCallback = void Function(ServerTransfer transfer);

/// Receives incoming file transfers on the embedded server.
///
/// Implements the Go `transfer.Manager` receive-side subset: offer handling,
/// chunk writing with concurrency limits, SHA-256 verification, and
/// atomic rename to the downloads directory.
class TransferReceiver {
  TransferReceiver({
    required SessionManager sessionManager,
    this.onTransferRequest,
    this.onProgress,
  });

  TransferRequestCallback? onTransferRequest;
  ProgressCallback? onProgress;

  final HashMap<String, ServerTransfer> _transfers = HashMap();

  // -- Concurrency semaphores (spec: 3 chunks/file, 2 files, 6 global) --------
  final Semaphore _globalSem = Semaphore(6);
  final HashMap<String, Semaphore> _fileSems = HashMap();
  int _activeFiles = 0;
  static const _maxActiveFiles = 2;

  // -- Progress throttle -------------------------------------------------------
  final HashMap<String, DateTime> _lastProgressPush = HashMap();
  static const _progressInterval = Duration(milliseconds: 300);

  // ---------------------------------------------------------------------------
  // Transfer lifecycle
  // ---------------------------------------------------------------------------

  /// Accept a pending transfer — moves to preparing → transferring.
  Future<void> acceptTransfer(String transferId) async {
    final transfer = _transfers[transferId];
    if (transfer == null || transfer.status != 'waiting_accept') return;

    transfer.status = 'preparing';

    // Create temp directories and part files for each file.
    for (final file in transfer.files) {
      file.partPath = await FileUtils.partFilePath(transferId, file.fileId);
      // Pre-allocate the part file.
      final partFile = File(file.partPath!);
      await partFile.create(recursive: true);
      final raf = await partFile.open(mode: FileMode.write);
      await raf.truncate(file.size);
      await raf.close();
      file.status = 'transferring';
    }

    transfer.status = 'transferring';
  }

  /// Reject a pending transfer.
  void rejectTransfer(String transferId) {
    final transfer = _transfers[transferId];
    if (transfer == null || transfer.status != 'waiting_accept') return;
    transfer.status = 'rejected';
  }

  /// Cancel an active transfer.
  void cancelTransfer(String transferId) {
    final transfer = _transfers[transferId];
    if (transfer == null) return;
    transfer.status = 'cancelled';
    for (final file in transfer.files) {
      if (file.status == 'transferring' || file.status == 'pending') {
        file.status = 'failed';
      }
    }
    _cleanupTempFiles(transfer);
  }

  ServerTransfer? getTransfer(String transferId) => _transfers[transferId];

  List<ServerTransfer> get activeTransfers =>
      _transfers.values.where((t) =>
          t.status == 'transferring' ||
          t.status == 'preparing' ||
          t.status == 'verifying' ||
          t.status == 'waiting_accept').toList();

  List<ServerTransfer> get allTransfers => _transfers.values.toList();

  // ---------------------------------------------------------------------------
  // Route handlers
  // ---------------------------------------------------------------------------

  /// POST /api/v1/transfers — receive a transfer offer.
  Future<Response> handleCreateTransfer(Request request) async {
    final sessionId = request.context['fastdrop.sessionId'] as String?;
    if (sessionId == null) return _error(401, 'UNAUTHORIZED', 'No session');

    final body = await _readJson(request);
    if (body == null) return _error(400, 'INVALID_REQUEST', 'Invalid JSON');

    final direction = body['direction'] as String? ?? 'client_to_server';
    final filesJson = body['files'] as List<dynamic>?;
    if (filesJson == null || filesJson.isEmpty) {
      return _error(400, 'INVALID_REQUEST', 'No files in offer');
    }

    final transferId = TokenManager.generateToken();
    final files = <ServerFileTask>[];

    for (final fj in filesJson) {
      final fm = fj as Map<String, dynamic>;
      files.add(ServerFileTask(
        fileId: TokenManager.generateToken(),
        clientFileId: (fm['clientFileId'] as String?) ?? '',
        name: FileUtils.sanitizeFileName(fm['name'] as String? ?? 'unnamed'),
        size: fm['size'] as int? ?? 0,
        sha256: fm['sha256'] as String?,
      ));
    }

    final transfer = ServerTransfer(
      transferId: transferId,
      sessionId: sessionId,
      direction: direction,
      files: files,
      createdAt: DateTime.now(),
    );
    _transfers[transferId] = transfer;

    // Notify UI for user confirmation.
    onTransferRequest?.call(transfer);

    // Build response matching Go backend format.
    final fileResults = files.map((f) => {
          'fileId': f.fileId,
          'clientFileId': f.clientFileId,
          'name': f.name,
          'chunkSize': FileUtils.chunkSize,
          'totalChunks': f.totalChunks,
        }).toList();

    return _json(201, {
      'transferId': transferId,
      'files': fileResults,
    });
  }

  /// PUT /api/v1/transfers/<tid>/files/<fid>/chunks/<idx> — receive a chunk.
  Future<Response> handleChunkUpload(
    Request request,
    String transferId,
    String fileId,
    String chunkIndexStr,
  ) async {
    final transfer = _transfers[transferId];
    if (transfer == null) {
      return _error(404, 'FILE_NOT_FOUND', 'Transfer not found');
    }
    if (transfer.status != 'transferring') {
      return _error(409, 'INVALID_REQUEST', 'Transfer is not in transferring state');
    }

    final file = transfer.files.where((f) => f.fileId == fileId).firstOrNull;
    if (file == null) {
      return _error(404, 'FILE_NOT_FOUND', 'File not found in transfer');
    }

    final chunkIndex = int.tryParse(chunkIndexStr);
    if (chunkIndex == null || chunkIndex < 0 || chunkIndex >= file.totalChunks) {
      return _error(400, 'INVALID_REQUEST', 'Invalid chunk index');
    }

    // Check file concurrency limit.
    if (_activeFiles >= _maxActiveFiles && !_fileSems.containsKey(fileId)) {
      return _error(429, 'INVALID_REQUEST', 'Too many concurrent files');
    }

    // Read the chunk body.
    Uint8List bytes;
    try {
      bytes = await _readBytes(request);
    } catch (e) {
      debugPrint('[Transfer] Failed to read chunk body: $e');
      return _error(400, 'INVALID_REQUEST', 'Failed to read chunk body: $e');
    }
    if (bytes.isEmpty) {
      return _error(400, 'INVALID_REQUEST', 'Empty chunk body');
    }

    // Acquire semaphores: global + per-file.
    final fileSem = _fileSems.putIfAbsent(fileId, () => Semaphore(3));

    await _globalSem.acquire();
    await fileSem.acquire();
    _activeFiles++;

    try {
      // Write at offset = chunkIndex * chunkSize.
      // Use FileMode.write (not append) so setPosition works reliably —
      // append mode may ignore setPosition on some platforms.
      final offset = chunkIndex * FileUtils.chunkSize;
      final partFile = File(file.partPath!);
      final raf = await partFile.open(mode: FileMode.write);
      await raf.setPosition(offset);
      await raf.writeFrom(bytes);
      await raf.close();

      file.receivedChunks.add(chunkIndex);

      // Throttled progress push.
      _maybePushProgress(transfer, file);

      return _json(200, {
        'chunkIndex': chunkIndex,
        'received': true,
      });
    } catch (e, s) {
      debugPrint('[Transfer] Chunk $chunkIndex write failed: $e');
      debugPrint('[Transfer] Stack: $s');
      return _error(500, 'INTERNAL_ERROR', 'Chunk write failed: $e');
    } finally {
      fileSem.release();
      _globalSem.release();
      _activeFiles--;
      if (_activeFiles <= 0) {
        _fileSems.remove(fileId);
      }
    }
  }

  /// POST /api/v1/transfers/<tid>/files/<fid>/complete — verify and finalize.
  Future<Response> handleFileComplete(
    Request request,
    String transferId,
    String fileId,
  ) async {
    final transfer = _transfers[transferId];
    if (transfer == null) {
      return _error(404, 'FILE_NOT_FOUND', 'Transfer not found');
    }

    final file = transfer.files.where((f) => f.fileId == fileId).firstOrNull;
    if (file == null) {
      return _error(404, 'FILE_NOT_FOUND', 'File not found');
    }

    // Verify all chunks received.
    if (file.receivedChunks.length < file.totalChunks) {
      return _error(400, 'INVALID_REQUEST',
          'Missing chunks: ${file.receivedChunks.length}/${file.totalChunks}');
    }

    transfer.status = 'verifying';
    file.status = 'verifying';

    try {
      // Compute SHA-256 of the assembled file.
      final actualSha = await FileUtils.computeFileSha256(file.partPath!);

      if (file.sha256 != null &&
          actualSha.toLowerCase() != file.sha256!.toLowerCase()) {
        file.status = 'failed';
        transfer.status = 'failed';
        return _error(400, 'FILE_HASH_MISMATCH',
            'SHA-256 mismatch: expected ${file.sha256}, got $actualSha');
      }

      // Atomic rename to downloads dir.
      final finalPath = await FileUtils.movePartToFinal(file.partPath!, file.name);
      file.finalPath = finalPath;
      file.status = 'completed';

      // Check if all files in the transfer are done.
      final allDone = transfer.files.every((f) => f.status == 'completed');
      if (allDone) {
        transfer.status = 'completed';
        _cleanupTempFiles(transfer);
      } else {
        transfer.status = 'transferring';
      }

      // Push final progress.
      onProgress?.call(TransferProgressEvent(
        transferId: transferId,
        fileId: fileId,
        transferredBytes: file.size,
        totalBytes: file.size,
        fileName: file.name,
        status: 'completed',
      ));

      return _json(200, {
        'fileId': fileId,
        'sha256': actualSha,
        'size': file.size,
      });
    } catch (e, s) {
      debugPrint('[Transfer] File complete failed: $e');
      debugPrint('[Transfer] Stack: $s');
      file.status = 'failed';
      transfer.status = 'failed';
      return _error(500, 'INTERNAL_ERROR', 'File completion failed: $e');
    }
  }

  /// GET /api/v1/transfers/<tid>/files/<fid>/content — download file (Range).
  Future<Response> handleFileDownload(
    Request request,
    String transferId,
    String fileId,
  ) async {
    final transfer = _transfers[transferId];
    if (transfer == null) {
      return _error(404, 'FILE_NOT_FOUND', 'Transfer not found');
    }

    final file = transfer.files.where((f) => f.fileId == fileId).firstOrNull;
    if (file == null || file.finalPath == null) {
      return _error(404, 'FILE_NOT_FOUND', 'File not available for download');
    }

    final localFile = File(file.finalPath!);
    if (!localFile.existsSync()) {
      return _error(404, 'FILE_NOT_FOUND', 'File not found on disk');
    }

    final fileSize = await localFile.length();
    final rangeHeader = request.headers['range'];

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      // Parse Range: bytes=start-end
      final rangeSpec = rangeHeader.substring(6);
      final parts = rangeSpec.split('-');
      final start = int.tryParse(parts[0]) ?? 0;
      final end = parts.length > 1 && parts[1].isNotEmpty
          ? int.tryParse(parts[1]) ?? fileSize - 1
          : fileSize - 1;

      if (start >= fileSize || end >= fileSize || start > end) {
        return Response(416, headers: {
          'content-range': 'bytes */$fileSize',
        });
      }

      final length = end - start + 1;
      final stream = localFile.openRead(start, end + 1);

      return Response(
        206,
        body: stream,
        headers: {
          'content-type': 'application/octet-stream',
          'content-range': 'bytes $start-$end/$fileSize',
          'content-length': '$length',
          'accept-ranges': 'bytes',
          'content-disposition': 'attachment; filename="${file.name}"',
        },
      );
    }

    // Full file response.
    final stream = localFile.openRead();
    return Response(
      200,
      body: stream,
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': '$fileSize',
        'accept-ranges': 'bytes',
        'content-disposition': 'attachment; filename="${file.name}"',
      },
    );
  }

  /// GET /api/v1/transfers — list transfers.
  Response handleListTransfers(Request request) {
    final transfers = _transfers.values.map((t) => {
          'id': t.transferId,
          'sessionId': t.sessionId,
          'peerDeviceId': '',
          'direction': t.direction,
          'status': t.status,
          'totalFiles': t.totalFiles,
          'totalBytes': t.totalBytes,
          'transferredBytes': t.transferredBytes,
          'createdAt': t.createdAt.millisecondsSinceEpoch ~/ 1000,
        }).toList();

    return _json(200, {'transfers': transfers});
  }

  /// Build the shelf Router for transfer endpoints.
  Router get router {
    final r = Router();
    r.post('/api/v1/transfers', handleCreateTransfer);
    r.get('/api/v1/transfers', handleListTransfers);
    r.put('/api/v1/transfers/<transferId>/files/<fileId>/chunks/<chunkIndex>',
        handleChunkUpload);
    r.post('/api/v1/transfers/<transferId>/files/<fileId>/complete',
        handleFileComplete);
    r.get('/api/v1/transfers/<transferId>/files/<fileId>/content',
        handleFileDownload);
    return r;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _maybePushProgress(ServerTransfer transfer, ServerFileTask file) {
    final key = '${transfer.transferId}:${file.fileId}';
    final now = DateTime.now();
    final last = _lastProgressPush[key];
    if (last != null && now.difference(last) < _progressInterval) return;
    _lastProgressPush[key] = now;

    onProgress?.call(TransferProgressEvent(
      transferId: transfer.transferId,
      fileId: file.fileId,
      transferredBytes: file.receivedBytes,
      totalBytes: file.size,
      fileName: file.name,
      status: 'transferring',
    ));
  }

  void _cleanupTempFiles(ServerTransfer transfer) {
    for (final file in transfer.files) {
      if (file.partPath != null) {
        try {
          final f = File(file.partPath!);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
    // Try to remove the transfer temp directory if empty.
    final firstPart = transfer.files.firstOrNull?.partPath;
    if (firstPart != null) {
      try {
        final dir = File(firstPart).parent;
        if (dir.existsSync() && dir.listSync().isEmpty) {
          dir.deleteSync();
        }
      } catch (_) {}
    }
  }

  static Future<Map<String, dynamic>?> _readJson(Request request) async {
    try {
      final raw = await request.readAsString();
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _readBytes(Request request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Response _json(int status, Map<String, dynamic> body) {
    return Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
  }

  static Response _error(int status, String code, String message) {
    return Response(
      status,
      body: jsonEncode({
        'error': {'code': code, 'message': message},
      }),
      headers: {'content-type': 'application/json'},
    );
  }
}

/// Simple counting semaphore for concurrency control.
class Semaphore {
  Semaphore(this._max);

  final int _max;
  int _count = 0;
  final _waitQueue = Queue<Completer<void>>();

  Future<void> acquire() async {
    if (_count < _max) {
      _count++;
      return;
    }
    final completer = Completer<void>();
    _waitQueue.add(completer);
    await completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      _waitQueue.removeFirst().complete();
    } else {
      _count--;
    }
  }
}
