import 'package:fastdrop_mobile/core/network/local_network_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('network info formats Wi-Fi name and local address', () {
    final info = LocalNetworkInfo.fromMap({
      'type': 'wifi',
      'name': 'FastDrop Lab',
      'localAddresses': ['192.168.137.20'],
      'permissionRequired': false,
    });

    expect(info.typeLabel, 'Wi-Fi');
    expect(info.displayLabel, 'FastDrop Lab · 192.168.137.20');
  });

  test('network info explains optional Wi-Fi name permission', () {
    final info = LocalNetworkInfo.fromMap({
      'type': 'wifi',
      'localAddresses': ['192.168.1.8'],
      'permissionRequired': true,
    });

    expect(info.displayLabel, 'Wi-Fi · 192.168.1.8 · 点击显示名称');
  });
}
