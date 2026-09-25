import 'dart:convert';
import 'dart:io';

import 'package:fastdrop_mobile/core/server/session_manager.dart';
import 'package:fastdrop_mobile/core/server/transfer_receiver.dart';
import 'package:fastdrop_mobile/core/utils/file_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  test('M:N transfer listings and file routes stay session-isolated', () async {
    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );

    Future<Map<String, dynamic>> create(String sessionId, String name) async {
      final response = await receiver.handleCreateTransfer(Request(
        'POST',
        Uri.parse('http://localhost/api/v1/transfers'),
        context: {'fastdrop.sessionId': sessionId},
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'offerId': 'offer-$sessionId',
          'direction': 'client_to_server',
          'files': [
            {
              'clientFileId': 'file-$sessionId',
              'name': name,
              'size': 1,
            },
          ],
        }),
      ));
      expect(response.statusCode, 201);
      return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    }

    final first = await create('session-a', 'a.txt');
    await create('session-b', 'b.txt');

    final listResponse = receiver.handleListTransfers(Request(
      'GET',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
    ));
    final listed =
        jsonDecode(await listResponse.readAsString()) as Map<String, dynamic>;
    final transfers = listed['transfers'] as List<dynamic>;
    expect(transfers, hasLength(1));
    expect(
        (transfers.single as Map<String, dynamic>)['id'], first['transferId']);

    final file =
        (first['files'] as List<dynamic>).single as Map<String, dynamic>;
    final denied = await receiver.handleChunkUpload(
      Request(
        'PUT',
        Uri.parse('http://localhost/chunk'),
        context: {'fastdrop.sessionId': 'session-b'},
        body: [1],
      ),
      first['transferId'] as String,
      file['fileId'] as String,
      '0',
    );
    expect(denied.statusCode, 403);
  });

  test('two files can each upload three chunks concurrently', () async {
    final originalPathProvider = PathProviderPlatform.instance;
    final temp = await Directory.systemTemp.createTemp('fastdrop-receiver-');
    PathProviderPlatform.instance = _TestPathProvider(temp.path);
    addTearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );
    final created = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'offerId': 'two-files',
        'direction': 'client_to_server',
        'files': [
          {
            'clientFileId': 'a',
            'name': 'a.bin',
            'size': FileUtils.chunkSize * 3,
          },
          {
            'clientFileId': 'b',
            'name': 'b.bin',
            'size': FileUtils.chunkSize * 3,
          },
        ],
      }),
    ));
    expect(created.statusCode, 201);
    final result =
        jsonDecode(await created.readAsString()) as Map<String, dynamic>;
    final transferId = result['transferId'] as String;
    final files =
        (result['files'] as List<dynamic>).cast<Map<String, dynamic>>();
    await receiver.acceptTransfer(transferId);

    final uploads = <Future<Response>>[];
    for (final file in files) {
      for (var index = 0; index < 3; index++) {
        uploads.add(receiver.handleChunkUpload(
          Request(
            'PUT',
            Uri.parse('http://localhost/chunk'),
            context: {'fastdrop.sessionId': 'session-a'},
            body: [index + 1],
          ),
          transferId,
          file['fileId'] as String,
          '$index',
        ));
      }
    }

    final responses = await Future.wait(uploads);
    expect(responses.map((response) => response.statusCode), everyElement(200));
  });

  test('create transfer rejects a JSON body larger than 1 MB', () async {
    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );
    final response = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      body: List<int>.filled(1024 * 1024 + 1, 1),
    ));

    expect(response.statusCode, 413);
  });

  test('create transfer rejects offers larger than available storage',
      () async {
    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => 5,
    );
    final response = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        // Unknown directions must normalize to client_to_server and must not
        // be usable to bypass the inbound disk-space check.
        'direction': 'unexpected',
        'files': [
          {
            'clientFileId': 'too-large',
            'name': 'large.bin',
            'size': 6,
          },
        ],
      }),
    ));
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final error = body['error'] as Map<String, dynamic>;

    expect(response.statusCode, 507);
    expect(error['code'], 'INSUFFICIENT_STORAGE');
    expect(
      error['details'],
      {'requiredBytes': 6, 'availableBytes': 5},
    );
  });

  test('chunk upload rejects bodies larger than chunk size plus slack',
      () async {
    final originalPathProvider = PathProviderPlatform.instance;
    final temp = await Directory.systemTemp.createTemp('fastdrop-limit-');
    PathProviderPlatform.instance = _TestPathProvider(temp.path);
    addTearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );
    final created = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      body: jsonEncode({
        'direction': 'client_to_server',
        'files': [
          {
            'clientFileId': 'a',
            'name': 'a.bin',
            'size': 1,
          },
        ],
      }),
    ));
    final result =
        jsonDecode(await created.readAsString()) as Map<String, dynamic>;
    final transferId = result['transferId'] as String;
    final file =
        (result['files'] as List<dynamic>).single as Map<String, dynamic>;
    await receiver.acceptTransfer(transferId);

    final response = await receiver.handleChunkUpload(
      Request(
        'PUT',
        Uri.parse('http://localhost/chunk'),
        context: {'fastdrop.sessionId': 'session-a'},
        body: List<int>.filled(FileUtils.chunkSize + 1025, 1),
      ),
      transferId,
      file['fileId'] as String,
      '0',
    );

    expect(response.statusCode, 413);
  });

  test('pause and resume are stateful and session-isolated', () async {
    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );
    final created = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      body: jsonEncode({
        'direction': 'client_to_server',
        'files': [
          {
            'clientFileId': 'a',
            'name': 'a.bin',
            'size': 1,
          },
        ],
      }),
    ));
    final result =
        jsonDecode(await created.readAsString()) as Map<String, dynamic>;
    final transferId = result['transferId'] as String;
    receiver.getTransfer(transferId)!.status = 'transferring';

    expect(receiver.pauseTransfer(transferId, 'session-b'), isFalse);
    expect(receiver.pauseTransfer(transferId, 'session-a'), isTrue);
    expect(receiver.getTransfer(transferId)?.status, 'paused');
    expect(receiver.resumeTransfer(transferId, 'session-b'), isFalse);
    expect(receiver.resumeTransfer(transferId, 'session-a'), isTrue);
    expect(receiver.getTransfer(transferId)?.status, 'transferring');
  });

  test('complete of one file keeps the batch transferring until all done (H8)',
      () async {
    SharedPreferences.setMockInitialValues({});
    final originalPathProvider = PathProviderPlatform.instance;
    final temp = await Directory.systemTemp.createTemp('fastdrop-h8-');
    PathProviderPlatform.instance = _TestPathProvider(temp.path);
    addTearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );
    final created = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'direction': 'client_to_server',
        'files': [
          {'clientFileId': 'a', 'name': 'a.bin', 'size': 1},
          {'clientFileId': 'b', 'name': 'b.bin', 'size': 1},
        ],
      }),
    ));
    final result =
        jsonDecode(await created.readAsString()) as Map<String, dynamic>;
    final transferId = result['transferId'] as String;
    final files =
        (result['files'] as List<dynamic>).cast<Map<String, dynamic>>();
    await receiver.acceptTransfer(transferId);

    Future<Response> uploadChunk(String fileId) {
      return receiver.handleChunkUpload(
        Request(
          'PUT',
          Uri.parse('http://localhost/chunk'),
          context: {'fastdrop.sessionId': 'session-a'},
          body: [1],
        ),
        transferId,
        fileId,
        '0',
      );
    }

    for (final file in files) {
      final response = await uploadChunk(file['fileId'] as String);
      expect(response.statusCode, 200);
    }

    // 第一个文件 complete 后，批次必须仍是 transferring（H8：verifying 只
    // 作用于文件级），第二个文件随后 complete 才结束整批。
    final firstComplete = await receiver.handleFileComplete(
      Request(
        'POST',
        Uri.parse('http://localhost/complete'),
        context: {'fastdrop.sessionId': 'session-a'},
      ),
      transferId,
      files.first['fileId'] as String,
    );
    expect(firstComplete.statusCode, 200);
    expect(receiver.getTransfer(transferId)!.status, 'transferring');
    expect(receiver.getTransfer(transferId)!.files.first.status, 'completed');

    final secondComplete = await receiver.handleFileComplete(
      Request(
        'POST',
        Uri.parse('http://localhost/complete'),
        context: {'fastdrop.sessionId': 'session-a'},
      ),
      transferId,
      files.last['fileId'] as String,
    );
    expect(secondComplete.statusCode, 200);
    expect(receiver.getTransfer(transferId)!.status, 'completed');
  });

  test('chunk uploads are rejected only for terminal transfer states', () async {
    SharedPreferences.setMockInitialValues({});
    final originalPathProvider = PathProviderPlatform.instance;
    final temp = await Directory.systemTemp.createTemp('fastdrop-term-');
    PathProviderPlatform.instance = _TestPathProvider(temp.path);
    addTearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );
    final created = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'direction': 'client_to_server',
        'files': [
          {'clientFileId': 'a', 'name': 'a.bin', 'size': 1},
        ],
      }),
    ));
    final result =
        jsonDecode(await created.readAsString()) as Map<String, dynamic>;
    final transferId = result['transferId'] as String;
    final fileId =
        ((result['files'] as List<dynamic>).single
            as Map<String, dynamic>)['fileId'] as String;

    Future<int> uploadStatus() async {
      final response = await receiver.handleChunkUpload(
        Request(
          'PUT',
          Uri.parse('http://localhost/chunk'),
          context: {'fastdrop.sessionId': 'session-a'},
          body: [1],
        ),
        transferId,
        fileId,
        '0',
      );
      return response.statusCode;
    }

    // 非 accepting 状态下 partPath 尚未创建 → 明确 409 而非 500。
    expect(await uploadStatus(), 409);
    await receiver.acceptTransfer(transferId);

    // 终态之外一律放行（含 paused 与文件级 verifying 场景）。
    for (final status in const ['transferring', 'paused', 'verifying']) {
      receiver.getTransfer(transferId)!.status = status;
      expect(await uploadStatus(), 200, reason: 'status=$status 应放行');
    }
    for (final status in const ['completed', 'failed', 'cancelled', 'rejected']) {
      receiver.getTransfer(transferId)!.status = status;
      expect(await uploadStatus(), 409, reason: 'status=$status 应拒绝');
    }
  });

  test('downloads are refused once the transfer is cancelled or failed',
      () async {
    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );
    final created = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'direction': 'server_to_client',
        'files': [
          {'clientFileId': 'a', 'name': 'a.bin', 'size': 1},
        ],
      }),
    ));
    final result =
        jsonDecode(await created.readAsString()) as Map<String, dynamic>;
    final transferId = result['transferId'] as String;
    final fileId =
        ((result['files'] as List<dynamic>).single
            as Map<String, dynamic>)['fileId'] as String;

    Future<Response> download() {
      return receiver.handleFileDownload(
        Request(
          'GET',
          Uri.parse('http://localhost/content'),
          context: {'fastdrop.sessionId': 'session-a'},
        ),
        transferId,
        fileId,
      );
    }

    receiver.getTransfer(transferId)!.status = 'cancelled';
    expect((await download()).statusCode, 410);
    receiver.getTransfer(transferId)!.status = 'failed';
    expect((await download()).statusCode, 409);
  });

  test('cancelTransfer enforces session ownership', () async {
    final receiver = TransferReceiver(
      sessionManager: SessionManager(),
      availableSpaceProvider: () async => -1,
    );
    final created = await receiver.handleCreateTransfer(Request(
      'POST',
      Uri.parse('http://localhost/api/v1/transfers'),
      context: {'fastdrop.sessionId': 'session-a'},
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'direction': 'client_to_server',
        'files': [
          {'clientFileId': 'a', 'name': 'a.bin', 'size': 1},
        ],
      }),
    ));
    final transferId =
        (jsonDecode(await created.readAsString())
            as Map<String, dynamic>)['transferId'] as String;

    // 跨会话取消：拒绝且状态不变。
    expect(receiver.cancelTransfer(transferId, sessionId: 'session-b'), isFalse);
    expect(receiver.getTransfer(transferId)!.status, 'waiting_accept');

    // 属主取消：成功。
    expect(receiver.cancelTransfer(transferId, sessionId: 'session-a'), isTrue);
    expect(receiver.getTransfer(transferId)!.status, 'cancelled');
  });
}
