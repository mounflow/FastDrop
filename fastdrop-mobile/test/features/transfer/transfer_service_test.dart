import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/utils/file_utils.dart';
import 'package:fastdrop_mobile/features/transfer/transfer_service.dart';
import 'package:fastdrop_mobile/shared/models/transfer.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('SHA-256 mismatch from server throws', () async {
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

    final service = TransferService(
      httpClient: FastDropHttpClient(
          baseUrl: 'http://${server.address.address}:${server.port}'),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.uploadFiles([sourceFile.path]),
      throwsA(isA<Exception>()),
    );
  });
}
