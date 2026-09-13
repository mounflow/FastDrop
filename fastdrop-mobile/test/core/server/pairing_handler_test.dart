import 'dart:convert';

import 'package:fastdrop_mobile/core/server/pairing_handler.dart';
import 'package:fastdrop_mobile/core/server/session_manager.dart';
import 'package:fastdrop_mobile/shared/models/device_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';

void main() {
  const localDevice = DeviceInfo(
    deviceId: 'local-id',
    deviceName: 'FastDrop-LOCAL1',
    platform: 'android',
    appVersion: '1.0.0',
  );
  const remoteDevice = DeviceInfo(
    deviceId: 'remote-id',
    deviceName: 'FastDrop-REMOTE',
    platform: 'windows',
    appVersion: '1.0.0',
  );

  test('pair discover auto-accepts by default', () async {
    var confirmationCount = 0;
    final handler = PairingHandler(
      sessionManager: SessionManager(),
      localDevice: localDevice,
      onPairRequest: (_) => confirmationCount++,
    );

    final response = await handler.handlePairDiscover(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/pair/discover'),
        body: jsonEncode({'device': remoteDevice.toJson()}),
      ),
    );
    final created =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(created['status'], 'accepted');
    expect(confirmationCount, 0);

    final poll = handler.handlePollRequest(
      Request('GET', Uri.parse('http://localhost/')),
      created['requestId'] as String,
    );
    final accepted =
        jsonDecode(await poll.readAsString()) as Map<String, dynamic>;
    expect(accepted['status'], 'accepted');
    expect(accepted['session'], isA<Map<String, dynamic>>());
  });

  test('pair discover waits when confirmation is enabled', () async {
    var confirmationCount = 0;
    final handler = PairingHandler(
      sessionManager: SessionManager(),
      localDevice: localDevice,
      requireConfirmation: true,
      onPairRequest: (_) => confirmationCount++,
    );

    final response = await handler.handlePairDiscover(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/pair/discover'),
        body: jsonEncode({'device': remoteDevice.toJson()}),
      ),
    );
    final created =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(created['status'], 'waiting_confirmation');
    expect(confirmationCount, 1);
  });

  test('pair request rejects bodies larger than 64 KB', () async {
    final handler = PairingHandler(
      sessionManager: SessionManager(),
      localDevice: localDevice,
    );

    final response = await handler.handlePairDiscover(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/pair/discover'),
        body: List<int>.filled(64 * 1024 + 1, 1),
      ),
    );
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(response.statusCode, 413);
    expect((body['error'] as Map<String, dynamic>)['code'], 'INVALID_REQUEST');
  });
}
