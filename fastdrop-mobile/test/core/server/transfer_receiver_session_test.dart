import 'dart:convert';
import 'dart:io';

import 'package:fastdrop_mobile/core/server/session_manager.dart';
import 'package:fastdrop_mobile/core/server/transfer_receiver.dart';
import 'package:fastdrop_mobile/core/utils/file_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shelf/shelf.dart';

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  test('M:N transfer listings and file routes stay session-isolated', () async {
    final receiver = TransferReceiver(sessionManager: SessionManager());

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

    final receiver = TransferReceiver(sessionManager: SessionManager());
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
}
