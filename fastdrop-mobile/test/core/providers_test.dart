import 'package:fastdrop_mobile/core/providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('anonymous device name contains no phone model or hostname', () {
    expect(
      DeviceIdManager.anonymousDeviceName('abc123-private-random-id'),
      'FastDrop-ABC123',
    );
  });
}
