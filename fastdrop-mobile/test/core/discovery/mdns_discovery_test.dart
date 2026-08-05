import 'package:fastdrop_mobile/core/discovery/mdns_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mDNS address validation', () {
    test('accepts private LAN addresses and rejects fake or public IPs', () {
      expect(MdnsDiscovery.isUsableLANIPv4('192.168.137.1'), isTrue);
      expect(MdnsDiscovery.isUsableLANIPv4('10.0.0.8'), isTrue);
      expect(MdnsDiscovery.isUsableLANIPv4('172.19.0.8'), isTrue);
      expect(MdnsDiscovery.isUsableLANIPv4('198.18.3.4'), isFalse);
      expect(MdnsDiscovery.isUsableLANIPv4('198.19.255.254'), isFalse);
      expect(MdnsDiscovery.isUsableLANIPv4('8.8.8.8'), isFalse);
      expect(MdnsDiscovery.isUsableLANIPv4('not-an-ip'), isFalse);
    });

    test('verified identity is canonical and rejects self or incomplete data',
        () {
      final payload = {
        'status': 'ok',
        'deviceId': 'desktop-1',
        'deviceName': 'Office PC',
        'platform': 'windows',
        'protocol': 1,
      };
      final device = MdnsDiscovery.deviceFromVerifiedIdentity(
        payload,
        ip: '192.168.137.1',
        port: 9527,
        localDeviceId: 'phone-1',
      );
      expect(device, isNotNull);
      expect(device!.deviceId, 'desktop-1');
      expect(device.deviceName, 'Office PC');
      expect(device.baseUrl, 'http://192.168.137.1:9527');

      expect(
        MdnsDiscovery.deviceFromVerifiedIdentity(
          payload,
          ip: '192.168.137.1',
          port: 9527,
          localDeviceId: 'desktop-1',
        ),
        isNull,
      );
      expect(
        MdnsDiscovery.deviceFromVerifiedIdentity(
          {'status': 'ok', 'deviceName': 'Unknown'},
          ip: '192.168.137.20',
          port: 9527,
        ),
        isNull,
      );
      expect(
        MdnsDiscovery.deviceFromVerifiedIdentity(
          payload,
          ip: '198.18.3.4',
          port: 9527,
        ),
        isNull,
      );
    });
  });

  test('broadcast instance name is stable and unique per device id', () {
    final first = MdnsDiscovery.broadcastInstanceName(
      'FastDrop Device',
      'phone-one-123456',
    );
    final second = MdnsDiscovery.broadcastInstanceName(
      'FastDrop Device',
      'phone-two-654321',
    );
    expect(first, isNot(second));
    expect(
        first,
        MdnsDiscovery.broadcastInstanceName(
          'FastDrop Device',
          'phone-one-123456',
        ));
  });

  test('anonymous device name is not duplicated in broadcast instance', () {
    expect(
      MdnsDiscovery.broadcastInstanceName(
          'FastDrop-PHONEO', 'phone-one-123456'),
      'FastDrop-PHONEO',
    );
  });
}
