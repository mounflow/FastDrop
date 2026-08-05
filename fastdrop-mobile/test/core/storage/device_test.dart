import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paired device persists receiver platform for acceptance routing', () {
    final device = Device(
      id: 'peer-1',
      name: 'Pixel',
      serverBaseUrl: 'http://192.168.1.8:9527',
      sessionId: 'session',
      accessToken: 'token',
      lastSeen: DateTime.utc(2026, 8, 3),
      platform: 'android',
    );

    final restored = Device.fromJson(device.toJson());
    expect(restored.platform, 'android');
    expect(restored.serverBaseUrl, device.serverBaseUrl);
  });

  test('legacy paired device defaults to unknown platform', () {
    final restored = Device.fromJson({
      'id': 'legacy',
      'name': 'Old PC',
      'serverBaseUrl': 'http://192.168.1.9:9527',
      'sessionId': 'session',
      'accessToken': 'token',
      'lastSeen': DateTime.utc(2026, 8, 3).toIso8601String(),
    });
    expect(restored.platform, 'unknown');
  });
}
