import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fastdrop_mobile/core/errors/app_error.dart';
import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/utils/file_utils.dart';
import 'package:fastdrop_mobile/features/transfer/transfer_service.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A minimal mock HTTP server that records every chunk upload it receives.
class _MockTransferServer {
  _MockTransferServer(this._totalChunks);

  final int _totalChunks;

  /// chunkIndex → received byte count.
  final Map<int, int> chunkSizes = {};

  /// chunkIndex → received bytes (only populated when [recordData] is true).
  final Map<int, Uint8List> chunkData = {};

  /// Set to true to store actual chunk payloads for integrity checks.
  bool recordData = false;

  String? expectedSha256;
  int fileSize = 0;
  String fileName = 'test.bin';
  Duration chunkDelay = Duration.zero;
  int chunkRequestCount = 0;

  /// When set, chunk PUTs respond with this HTTP status and [chunkErrorCode]
  /// instead of accepting the chunk (used to simulate non-retryable errors).
  int? chunkFailureStatus;
  String chunkErrorCode = 'INTERNAL_ERROR';

  final Completer<void> firstChunkReceived = Completer<void>();
  late HttpServer server;

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;

      if (request.method == 'POST' && path == '/api/v1/transfers') {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        final files = body['files'] as List<dynamic>;
        final f = files.single as Map<String, dynamic>;
        expectedSha256 = f['sha256'] as String;
        fileSize = f['size'] as int;
        fileName = f['name'] as String;

        request.response.statusCode = HttpStatus.created;
        request.response.write(jsonEncode({
          'transferId': 'transfer-1',
          'files': [
            {
              'fileId': 'file-1',
              'name': fileName,
              'chunkSize': FileUtils.chunkSize,
              'totalChunks': _totalChunks,
            },
          ],
        }));
      } else if (request.method == 'PUT' && path.contains('/chunks/')) {
        chunkRequestCount++;
        if (!firstChunkReceived.isCompleted) firstChunkReceived.complete();
        if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
        final chunkIndex = int.parse(request.uri.pathSegments.last);
        if (chunkFailureStatus != null) {
          request.response.statusCode = chunkFailureStatus!;
          request.response.write(jsonEncode({
            'error': {'code': chunkErrorCode, 'message': 'mock failure'},
          }));
        } else {
          final bytes = await request.fold<List<int>>(
            <int>[],
            (all, chunk) => all..addAll(chunk),
          );
          chunkSizes[chunkIndex] = bytes.length;
          if (recordData) {
            chunkData[chunkIndex] = Uint8List.fromList(bytes);
          }
          request.response.write(jsonEncode({
            'chunkIndex': chunkIndex,
            'received': true,
          }));
        }
      } else if (request.method == 'POST' && path.endsWith('/complete')) {
        await request.drain<void>();
        request.response.write(jsonEncode({
          'fileId': 'file-1',
          'sha256': expectedSha256,
          'size': fileSize,
        }));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }

      await request.response.close();
    });
  }

  Future<void> stop() async {
    await server.close(force: true);
  }
}

/// Create a sparse file of [size] bytes (all zeros) and return its path.
Future<File> _createSparseFile(Directory dir, String name, int size) async {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  final handle = await file.open(mode: FileMode.write);
  await handle.truncate(size);
  await handle.close();
  return file;
}

/// Deterministic pseudo-random byte pattern (for download content).
Uint8List _patternBytes(int length) {
  return Uint8List.fromList(
    List<int>.generate(length, (i) => (i * 31 + 7) % 251),
  );
}

/// Redirects path_provider to a temp root so FileUtils temp/download dirs
/// land inside the per-test temp directory.
class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// Minimal mock server for [TransferService.downloadFile]: serves raw bytes
/// over Range requests the same way the embedded receiver does.
class _MockDownloadServer {
  _MockDownloadServer(this.content);

  final Uint8List content;

  /// Every served Range header, in request order.
  final List<String> ranges = [];

  final Completer<void> firstRangeRequest = Completer<void>();

  /// Artificial delay before answering each Range request.
  Duration responseDelay = Duration.zero;

  /// When non-zero, Range GETs respond with this status instead of data.
  int failureStatus = 0;

  late HttpServer server;

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (request.method == 'POST' && path.endsWith('/cancel')) {
        await request.drain<void>();
        request.response.write(jsonEncode({'status': 'cancelled'}));
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && path.endsWith('/content')) {
        if (!firstRangeRequest.isCompleted) firstRangeRequest.complete();
        if (responseDelay > Duration.zero) {
          await Future<void>.delayed(responseDelay);
        }
        final range =
            request.headers.value(HttpHeaders.rangeHeader) ?? '';
        if (failureStatus != 0) {
          request.response.statusCode = failureStatus;
          request.response.write(jsonEncode({
            'error': {'code': 'INVALID_REQUEST', 'message': 'mock failure'},
          }));
          await request.response.close();
          return;
        }
        ranges.add(range);
        final spec = range.substring('bytes='.length);
        final parts = spec.split('-');
        final start = int.parse(parts[0]);
        final end = int.parse(parts[1]);
        request.response.statusCode = 206;
        request.response.add(content.sublist(start, end + 1));
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
  }

  Future<void> stop() async {
    await server.close(force: true);
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fastdrop-upload-test-');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Chunk index correctness
  // ---------------------------------------------------------------------------

  test('single-chunk file (< 4 MB) uploads chunk 0 only', () async {
    final sourceFile = await _createSparseFile(tempDir, 'small.bin', 1024);
    final mock = _MockTransferServer(1);
    await mock.start();
    addTearDown(mock.stop);

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    await service.uploadFiles([sourceFile.path]);

    expect(mock.chunkSizes.keys.toList(), [0]);
    expect(mock.chunkSizes[0], 1024);
  });

  test('two-chunk file uploads indices [0, 1]', () async {
    final sourceFile = await _createSparseFile(
        tempDir, 'two.bin', FileUtils.chunkSize + 1);
    final mock = _MockTransferServer(2);
    await mock.start();
    addTearDown(mock.stop);

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    await service.uploadFiles([sourceFile.path]);

    expect(mock.chunkSizes.keys.toList()..sort(), [0, 1]);
    expect(mock.chunkSizes[0], FileUtils.chunkSize);
    expect(mock.chunkSizes[1], 1);
  });

  test('10-chunk file uploads all indices [0..9] exactly once', () async {
    final size = FileUtils.chunkSize * 9 + 100; // 9 full + 1 partial = 10
    final sourceFile = await _createSparseFile(tempDir, 'ten.bin', size);
    final mock = _MockTransferServer(10);
    await mock.start();
    addTearDown(mock.stop);

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    await service.uploadFiles([sourceFile.path]);

    final indices = mock.chunkSizes.keys.toList()..sort();
    expect(indices, List.generate(10, (i) => i),
        reason: 'All 10 chunk indices must be present exactly once');
    // First 9 chunks are full-size.
    for (int i = 0; i < 9; i++) {
      expect(mock.chunkSizes[i], FileUtils.chunkSize,
          reason: 'Chunk $i should be full size');
    }
    // Last chunk is the remainder.
    expect(mock.chunkSizes[9], 100);
  });

  test('exact-boundary file (N * chunkSize) has N chunks, all full', () async {
    const n = 5;
    final size = FileUtils.chunkSize * n;
    final sourceFile =
        await _createSparseFile(tempDir, 'exact.bin', size);
    final mock = _MockTransferServer(n);
    await mock.start();
    addTearDown(mock.stop);

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    await service.uploadFiles([sourceFile.path]);

    final indices = mock.chunkSizes.keys.toList()..sort();
    expect(indices, List.generate(n, (i) => i));
    for (int i = 0; i < n; i++) {
      expect(mock.chunkSizes[i], FileUtils.chunkSize);
    }
  });

  // ---------------------------------------------------------------------------
  // Data integrity
  // ---------------------------------------------------------------------------

  test('chunk payload matches source file content', () async {
    // Write a file with recognisable per-chunk patterns so we can verify
    // that each chunk carries the correct slice of the source.
    final sourceFile =
        File('${tempDir.path}${Platform.pathSeparator}pattern.bin');
    final handle = await sourceFile.open(mode: FileMode.write);
    // Fill first chunk with 0xAA, second with 0xBB, tail with 0xCC.
    await handle.writeFrom(Uint8List(FileUtils.chunkSize)..fillRange(0, FileUtils.chunkSize, 0xAA));
    await handle.writeFrom(Uint8List(FileUtils.chunkSize)..fillRange(0, FileUtils.chunkSize, 0xBB));
    await handle.writeFrom(Uint8List(512)..fillRange(0, 512, 0xCC));
    await handle.close();

    final mock = _MockTransferServer(3)..recordData = true;
    await mock.start();
    addTearDown(mock.stop);

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    await service.uploadFiles([sourceFile.path]);

    expect(mock.chunkData[0]!.every((b) => b == 0xAA), isTrue,
        reason: 'Chunk 0 should be all 0xAA');
    expect(mock.chunkData[1]!.every((b) => b == 0xBB), isTrue,
        reason: 'Chunk 1 should be all 0xBB');
    expect(mock.chunkData[2]!.length, 512);
    expect(mock.chunkData[2]!.every((b) => b == 0xCC), isTrue,
        reason: 'Chunk 2 should be all 0xCC');
  });

  // ---------------------------------------------------------------------------
  // Progress & state callbacks
  // ---------------------------------------------------------------------------

  test('onProgress fires and onStateChange reports completed', () async {
    final sourceFile = await _createSparseFile(
        tempDir, 'progress.bin', FileUtils.chunkSize + 1);
    final mock = _MockTransferServer(2);
    await mock.start();
    addTearDown(mock.stop);

    final progressEvents = <TransferProgress>[];
    final stateEvents = <String>[];

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
      onProgress: (tid, fid, p) => progressEvents.add(p),
      onStateChange: (tid, status, {errorCode, errorMessage}) =>
          stateEvents.add(status),
    );
    addTearDown(service.dispose);

    await service.uploadFiles([sourceFile.path]);

    expect(progressEvents, isNotEmpty);
    expect(progressEvents.last.bytesTransferred,
        progressEvents.last.totalBytes,
        reason: 'Final progress should be 100%');
    expect(stateEvents, contains('completed'));
  });

  // ---------------------------------------------------------------------------
  // Cancellation
  // ---------------------------------------------------------------------------

  test('cancelTransfer stops upload mid-flight', () async {
    // Use a 20-chunk file so there is time to cancel.
    final size = FileUtils.chunkSize * 19 + 1;
    final sourceFile =
        await _createSparseFile(tempDir, 'cancel.bin', size);
    final mock = _MockTransferServer(20);
    await mock.start();
    addTearDown(mock.stop);

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    // Start upload but cancel almost immediately.
    final future = service.uploadFiles([sourceFile.path], offerId: 'cancel-1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.cancelTransfer('cancel-1');

    // Wait for the upload to settle (may return normally or throw).
    try {
      await future;
    } catch (_) {
      // Cancellation can surface as an exception — that is acceptable.
    }

    // The key assertion: NOT all 20 chunks should have been uploaded.
    expect(mock.chunkSizes.length, lessThan(20),
        reason: 'Cancellation should stop the upload before all chunks land');
  });

  test('pause stops scheduling new chunks until resume', () async {
    const size = FileUtils.chunkSize * 5 + 1;
    final sourceFile = await _createSparseFile(tempDir, 'pause.bin', size);
    final mock = _MockTransferServer(6)
      ..chunkDelay = const Duration(milliseconds: 60);
    await mock.start();
    addTearDown(mock.stop);

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    final upload = service.uploadFiles([sourceFile.path], offerId: 'pause-1');
    await mock.firstChunkReceived.future;
    service.pauseTransfer('pause-1');

    // The first batch (at most three chunks) is allowed to drain. No later
    // batch may start while the local pause gate is closed.
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final countWhilePaused = mock.chunkRequestCount;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(mock.chunkRequestCount, countWhilePaused);
    expect(countWhilePaused, lessThanOrEqualTo(3));

    service.resumeTransfer('pause-1');
    await upload;
    expect(mock.chunkRequestCount, 6);
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  test('upload throws on missing file', () async {
    final mock = _MockTransferServer(1);
    await mock.start();
    addTearDown(mock.stop);

    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.uploadFiles(['/nonexistent/path/file.bin']),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('SHA-256 mismatch from server marks the batch failed (M13)', () async {
    final sourceFile =
        await _createSparseFile(tempDir, 'mismatch.bin', 1024);

    // Server that returns a wrong hash on /complete.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/api/v1/transfers') {
        request.response.statusCode = HttpStatus.created;
        request.response.write(jsonEncode({
          'transferId': 't-mismatch',
          'files': [
            {
              'fileId': 'f-1',
              'name': 'mismatch.bin',
              'chunkSize': FileUtils.chunkSize,
              'totalChunks': 1,
            },
          ],
        }));
      } else if (request.method == 'PUT' && path.contains('/chunks/')) {
        await request.drain<void>();
        request.response.write(jsonEncode({'chunkIndex': 0, 'received': true}));
      } else if (request.method == 'POST' && path.endsWith('/complete')) {
        await request.drain<void>();
        request.response.write(jsonEncode({
          'fileId': 'f-1',
          'sha256': 'deadbeef' * 8, // wrong hash
        }));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final stateEvents = <Map<String, String?>>[];
    final service = TransferService(
      httpClient: FastDropHttpClient(
          baseUrl: 'http://${server.address.address}:${server.port}'),
      onStateChange: (tid, status, {errorCode, errorMessage}) =>
          stateEvents.add({
            'status': status,
            'errorCode': errorCode,
            'errorMessage': errorMessage,
          }),
    );
    addTearDown(service.dispose);

    // 部分失败语义（M13）：单个文件失败不再向上抛出，整批以 failed 收尾。
    await service.uploadFiles([sourceFile.path]);

    final failed = stateEvents.last;
    expect(failed['status'], 'failed');
    expect(failed['errorCode'], 'TRANSFER_FAILED');
    expect(failed['errorMessage'], '1/1 个文件失败');
  });

  // ---------------------------------------------------------------------------
  // Partial batch failure (M13) & session errors (L13)
  // ---------------------------------------------------------------------------

  test('one failing file does not abort the batch and reports 1/2', () async {
    final fileA = await _createSparseFile(tempDir, 'good.bin', 1024);
    final fileB = await _createSparseFile(tempDir, 'bad.bin', 2048);

    final chunkCounts = <String, int>{};
    final completes = <String>[];
    final shaByFileId = <String, String>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/api/v1/transfers') {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        final files =
            (body['files'] as List<dynamic>).cast<Map<String, dynamic>>();
        for (final f in files) {
          shaByFileId[f['name'] as String] = f['sha256'] as String;
        }
        request.response.statusCode = HttpStatus.created;
        request.response.write(jsonEncode({
          'transferId': 't-partial',
          'files': [
            for (final f in files)
              {
                'fileId': f['name'],
                'name': f['name'],
                'chunkSize': FileUtils.chunkSize,
                'totalChunks': 1,
              },
          ],
        }));
      } else if (request.method == 'PUT' && path.contains('/chunks/')) {
        final fileId = request.uri.pathSegments[5];
        chunkCounts[fileId] = (chunkCounts[fileId] ?? 0) + 1;
        await request.drain<void>();
        if (fileId == 'bad.bin') {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write(jsonEncode({
            'error': {'code': 'INVALID_REQUEST', 'message': 'nope'},
          }));
        } else {
          request.response.write(jsonEncode({'received': true}));
        }
      } else if (request.method == 'POST' && path.endsWith('/complete')) {
        await request.drain<void>();
        final fileId = request.uri.pathSegments[5];
        completes.add(fileId);
        request.response
            .write(jsonEncode({'fileId': fileId, 'sha256': shaByFileId[fileId]}));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final stateEvents = <Map<String, String?>>[];
    final service = TransferService(
      httpClient: FastDropHttpClient(
          baseUrl: 'http://${server.address.address}:${server.port}'),
      onStateChange: (tid, status, {errorCode, errorMessage}) =>
          stateEvents.add({
            'status': status,
            'errorCode': errorCode,
            'errorMessage': errorMessage,
          }),
    );
    addTearDown(service.dispose);

    await service.uploadFiles([fileA.path, fileB.path]);

    expect(stateEvents.first['status'], 'preparing',
        reason: '哈希阶段开始时上报 preparing');
    expect(stateEvents.last['status'], 'failed');
    expect(stateEvents.last['errorCode'], 'TRANSFER_FAILED');
    expect(stateEvents.last['errorMessage'], '1/2 个文件失败');
    expect(chunkCounts['good.bin'], 1);
    expect(chunkCounts['bad.bin'], 1,
        reason: '非重试错误不应触发退避重试');
    expect(completes, ['good.bin'],
        reason: '成功文件应照常 complete，失败文件不应走到 complete');
  });

  test('session-class chunk failure reports SESSION_EXPIRED (L13)', () async {
    final sourceFile = await _createSparseFile(tempDir, 'session.bin', 512);
    final mock = _MockTransferServer(1)
      ..chunkFailureStatus = HttpStatus.unauthorized
      ..chunkErrorCode = 'SESSION_INVALID';
    await mock.start();
    addTearDown(mock.stop);

    final stateEvents = <Map<String, String?>>[];
    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
      onStateChange: (tid, status, {errorCode, errorMessage}) =>
          stateEvents.add({
            'status': status,
            'errorCode': errorCode,
            'errorMessage': errorMessage,
          }),
    );
    addTearDown(service.dispose);

    await service.uploadFiles([sourceFile.path]);

    final failed = stateEvents.last;
    expect(failed['status'], 'failed');
    expect(failed['errorCode'], 'SESSION_EXPIRED',
        reason: '401/SESSION_* 应映射为 SESSION_EXPIRED 供 UI 引导重新配对');
    expect(failed['errorMessage'], '1/1 个文件失败');
    expect(mock.chunkRequestCount, 1,
        reason: '会话类错误不重试');
  });

  // ---------------------------------------------------------------------------
  // Download resume / failure retention / cancellation (H10, M15)
  // ---------------------------------------------------------------------------

  test('downloadFile resumes from an existing partial .part file', () async {
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => PathProviderPlatform.instance = originalPathProvider);

    final content = _patternBytes(FileUtils.chunkSize + 100);
    final mock = _MockDownloadServer(content);
    await mock.start();
    addTearDown(mock.stop);

    // 预置上次中断留下的完整第一块。
    final partPath = await FileUtils.partFilePath('dl-resume', 'file-1');
    await File(partPath).writeAsBytes(content.sublist(0, FileUtils.chunkSize));

    final states = <String>[];
    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
      onStateChange: (tid, status, {errorCode, errorMessage}) =>
          states.add(status),
    );
    addTearDown(service.dispose);

    final expectedSha = sha256.convert(content).toString();
    final finalPath = await service.downloadFile(
      transferId: 'dl-resume',
      fileId: 'file-1',
      fileName: 'resume.bin',
      totalBytes: content.length,
      expectedSha256: expectedSha,
    );

    expect(mock.ranges,
        ['bytes=${FileUtils.chunkSize}-${FileUtils.chunkSize + 99}'],
        reason: '续传只应请求缺失的第二个块');
    expect(states, ['completed']);
    expect(await File(finalPath).readAsBytes(), content);
    expect(File(partPath).existsSync(), isFalse,
        reason: '成功后 .part 应被搬离临时目录');
  });

  test('downloadFile keeps the .part file after a failure', () async {
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => PathProviderPlatform.instance = originalPathProvider);

    final content = _patternBytes(1024);
    final mock = _MockDownloadServer(content)..failureStatus = 404;
    await mock.start();
    addTearDown(mock.stop);

    final partPath = await FileUtils.partFilePath('dl-fail', 'file-1');
    final errorCodes = <String, String?>{};
    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
      onStateChange: (tid, status, {errorCode, errorMessage}) =>
          errorCodes[status] = errorCode,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.downloadFile(
        transferId: 'dl-fail',
        fileId: 'file-1',
        fileName: 'fail.bin',
        totalBytes: content.length,
        expectedSha256: sha256.convert(content).toString(),
      ),
      throwsA(isA<AppError>()),
    );

    expect(File(partPath).existsSync(), isTrue,
        reason: '失败必须保留 .part 供断点续传（H10c）');
    expect(errorCodes['failed'], 'INTERNAL_ERROR');
  });

  test('cancelTransfer aborts a download and removes the .part file',
      () async {
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(tempDir.path);
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => PathProviderPlatform.instance = originalPathProvider);

    final content = _patternBytes(FileUtils.chunkSize * 2);
    final mock = _MockDownloadServer(content)
      ..responseDelay = const Duration(milliseconds: 250);
    await mock.start();
    addTearDown(mock.stop);

    final partPath = await FileUtils.partFilePath('dl-cancel', 'file-1');
    final service = TransferService(
      httpClient: FastDropHttpClient(baseUrl: mock.baseUrl),
    );
    addTearDown(service.dispose);

    final download = service.downloadFile(
      transferId: 'dl-cancel',
      fileId: 'file-1',
      fileName: 'cancel.bin',
      totalBytes: content.length,
      expectedSha256: sha256.convert(content).toString(),
    );

    await mock.firstRangeRequest.future;
    await service.cancelTransfer('dl-cancel');
    await expectLater(download, throwsA(isA<Exception>()));

    expect(File(partPath).existsSync(), isFalse, reason: '取消后应清理 .part（M15）');
  });
}
