import 'package:fastdrop_mobile/core/discovery/device_discovery.dart';
import 'package:fastdrop_mobile/core/discovery/manual_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiscoveredDevice', () {
    test('equality keyed by deviceId', () {
      final a = DiscoveredDevice(
        deviceId: 'pc1',
        deviceName: 'PC1',
        baseUrl: 'http://1.2.3.4:9527',
        protocolVersion: 1,
        platform: 'windows',
        pairingRequired: true,
      );
      final b = DiscoveredDevice(
        deviceId: 'pc1',
        deviceName: 'Different Name',
        baseUrl: 'http://5.6.7.8:9527',
        protocolVersion: 2,
        platform: 'linux',
        pairingRequired: false,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('toString includes name and baseUrl', () {
      final d = DiscoveredDevice(
        deviceId: 'pc1',
        deviceName: 'Office',
        baseUrl: 'http://10.0.0.1:9527',
        protocolVersion: 1,
        platform: 'windows',
        pairingRequired: false,
      );
      final s = d.toString();
      expect(s, contains('Office'));
      expect(s, contains('10.0.0.1'));
    });
  });

  group('ManualDiscovery', () {
    test('parses bare IP into http://IP:9527', () async {
      final d = ManualDiscovery(hostPortInput: '192.168.1.19');
      final devices = await d.start().first;
      expect(devices.length, 1);
      expect(devices.first.baseUrl, 'http://192.168.1.19:9527');
      await d.stop();
    });

    test('parses IP:port unchanged', () async {
      final d = ManualDiscovery(hostPortInput: '192.168.1.19:9999');
      final devices = await d.start().first;
      expect(devices.first.baseUrl, 'http://192.168.1.19:9999');
      await d.stop();
    });

    test('passes through http:// prefix unchanged', () async {
      final d = ManualDiscovery(hostPortInput: 'http://10.0.0.5:9527');
      final devices = await d.start().first;
      expect(devices.first.baseUrl, 'http://10.0.0.5:9527');
      await d.stop();
    });

    test('emits empty list for blank input', () async {
      final d = ManualDiscovery(hostPortInput: '   ');
      final devices = await d.start().first;
      expect(devices, isEmpty);
      await d.stop();
    });

    test('isRunning reflects lifecycle', () async {
      final d = ManualDiscovery(hostPortInput: '1.2.3.4');
      expect(d.isRunning, false);
      await d.start().first;
      expect(d.isRunning, true);
      await d.stop();
      expect(d.isRunning, false);
    });
  });
}
