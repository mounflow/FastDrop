import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/features/transfer/chunk_uploader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('retries transient chunk failures and then succeeds', () async {
    var attempts = 0;
    final delays = <Duration>[];
    final client = FastDropHttpClient(
      baseUrl: 'http://localhost',
      client: MockClient((request) async {
        attempts++;
        if (attempts < 3) {
          return http.Response(
            jsonEncode({
              'error': {'code': 'INTERNAL_ERROR', 'message': 'temporary'},
            }),
            500,
          );
        }
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.dispose);

    await ChunkUploader.upload(
      client: client,
      transferId: 'transfer-1',
      fileId: 'file-1',
      chunkIndex: 0,
      data: Uint8List.fromList([1]),
      delay: (duration) async => delays.add(duration),
      random: Random(1),
    );

    expect(attempts, 3);
    expect(delays, hasLength(2));
    expect(delays[0].inMilliseconds, inInclusiveRange(500, 750));
    expect(delays[1].inMilliseconds, inInclusiveRange(1000, 1500));
  });

  test('maxRetries means five retries after the initial attempt', () async {
    var attempts = 0;
    final client = FastDropHttpClient(
      baseUrl: 'http://localhost',
      client: MockClient((request) async {
        attempts++;
        return http.Response(
          jsonEncode({
            'error': {'code': 'INTERNAL_ERROR', 'message': 'temporary'},
          }),
          500,
        );
      }),
    );
    addTearDown(client.dispose);

    await expectLater(
      ChunkUploader.upload(
        client: client,
        transferId: 'transfer-1',
        fileId: 'file-1',
        chunkIndex: 0,
        data: Uint8List.fromList([1]),
        delay: (_) async {},
        random: Random(1),
      ),
      throwsA(isA<ChunkUploadException>()),
    );

    expect(attempts, 6);
  });

  test('pause gate runs before every network attempt', () async {
    var attempts = 0;
    var gateCalls = 0;
    final client = FastDropHttpClient(
      baseUrl: 'http://localhost',
      client: MockClient((request) async {
        attempts++;
        return attempts == 1
            ? http.Response(
                jsonEncode({
                  'error': {
                    'code': 'INTERNAL_ERROR',
                    'message': 'temporary',
                  },
                }),
                500,
              )
            : http.Response('{}', 200);
      }),
    );
    addTearDown(client.dispose);

    await ChunkUploader.upload(
      client: client,
      transferId: 'transfer-1',
      fileId: 'file-1',
      chunkIndex: 0,
      data: Uint8List.fromList([1]),
      beforeAttempt: () async => gateCalls++,
      delay: (_) async {},
      random: Random(1),
    );

    expect(gateCalls, 2);
  });

  test('does not retry session or validation failures', () async {
    var attempts = 0;
    final client = FastDropHttpClient(
      baseUrl: 'http://localhost',
      client: MockClient((request) async {
        attempts++;
        return http.Response(
          jsonEncode({
            'error': {'code': 'SESSION_INVALID', 'message': 'expired'},
          }),
          401,
        );
      }),
    );
    addTearDown(client.dispose);

    await expectLater(
      ChunkUploader.upload(
        client: client,
        transferId: 'transfer-1',
        fileId: 'file-1',
        chunkIndex: 0,
        data: Uint8List.fromList([1]),
        delay: (_) async {},
      ),
      throwsA(isA<ChunkUploadException>()),
    );

    expect(attempts, 1);
  });
}
