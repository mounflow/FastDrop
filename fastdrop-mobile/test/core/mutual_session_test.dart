import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';

import 'package:fastdrop_mobile/core/server/ws_server.dart';
import 'package:fastdrop_mobile/core/storage/ignored_device_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('peerBaseUrlFromRequest（入站地址 = 回连地址来源）', () {
    test('从入站连接信息推导 http://<ip>:9527', () {
      final request = Request(
        'GET',
        Uri.parse('http://192.168.1.11:9527/ws/v1'),
        context: {
          'shelf.io.connection_info': _ConnInfo('192.168.1.11'),
        },
      );
      expect(peerBaseUrlFromRequest(request), 'http://192.168.1.11:9527');
    });

    test('IPv6 字面量加方括号', () {
      final request = Request(
        'GET',
        Uri.parse('http://[fe80::1]:9527/ws/v1'),
        context: {
          'shelf.io.connection_info': _ConnInfo('fe80::1'),
        },
      );
      expect(peerBaseUrlFromRequest(request), 'http://[fe80::1]:9527');
    });

    test('缺少连接信息时返回 null（回退到已存记录 / mDNS 发现）', () {
      final request = Request('GET', Uri.parse('http://host/ws/v1'));
      expect(peerBaseUrlFromRequest(request), isNull);
    });
  });

  group('IgnoredDeviceStore（用户删除过的设备）', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('初始为空', () async {
      expect(await IgnoredDeviceStore().load(), isEmpty);
    });

    test('删除设备后加入名单，按 id 或名称均可命中', () async {
      final store = IgnoredDeviceStore();
      await store.add(deviceId: 'http://192.168.1.11:9527', name: 'FastDrop-PC');

      final entries = await store.load();
      expect(entries, hasLength(1));
      expect(
        entries.any((e) => e.deviceId == 'http://192.168.1.11:9527'),
        isTrue,
      );
      // 按名称也命中：对端换 id 后仍能拦截（与 Go 端语义一致）。
      expect(entries.any((e) => e.name == 'FastDrop-PC'), isTrue);
    });

    test('同名重复加入不会产生重复条目', () async {
      final store = IgnoredDeviceStore();
      await store.add(deviceId: 'id-1', name: 'PC');
      await store.add(deviceId: 'id-2', name: 'PC');
      expect(await store.load(), hasLength(1));
    });

    test('用户主动重新配对 → 移除忽略标记（非永久黑名单）', () async {
      final store = IgnoredDeviceStore();
      await store.add(deviceId: 'id-1', name: 'PC');
      await store.remove(deviceId: 'id-1');
      expect(await store.load(), isEmpty);
    });

    test('按名称移除（对端 id 变更后主动配对恢复）', () async {
      final store = IgnoredDeviceStore();
      await store.add(deviceId: 'old-id', name: 'PC');
      await store.remove(deviceId: 'new-id', name: 'PC');
      expect(await store.load(), isEmpty);
    });

    test('忽略名单与传输记录互不影响（存储键隔离）', () async {
      final store = IgnoredDeviceStore();
      await store.add(deviceId: 'id-1', name: 'PC');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('fastdrop.ignored_devices.v1'), isNotNull);
      // 删除设备绝不写入/清除传输记录键。
      expect(prefs.getString('fastdrop.transfer_history.v1'), isNull);
    });
  });
}

/// 最小 HttpConnectionInfo 替身：shelf context 只读取 remoteAddress。
class _ConnInfo implements HttpConnectionInfo {
  _ConnInfo(this._address);

  final String _address;

  @override
  InternetAddress get remoteAddress => InternetAddress(_address);

  @override
  int get remotePort => 50000;

  @override
  InternetAddress get localAddress => InternetAddress('0.0.0.0');

  @override
  int get localPort => 9527;
}
