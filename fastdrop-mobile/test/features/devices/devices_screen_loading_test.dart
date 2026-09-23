import 'dart:async';

import 'package:fastdrop_mobile/core/providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/features/devices/devices_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestDeviceStore extends DeviceStore {
  _TestDeviceStore(this.onLoad);

  final Future<List<Device>> Function() onLoad;

  @override
  Future<List<Device>> loadDevices() => onLoad();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'fastdrop.server_enabled': false,
      'fastdrop.mdns_enabled': false,
    });
  });

  testWidgets('starts device loading after ConsumerState initialization',
      (tester) async {
    final pendingLoad = Completer<List<Device>>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceStoreProvider.overrideWithValue(
            _TestDeviceStore(() => pendingLoad.future),
          ),
        ],
        child: const MaterialApp(home: DevicesScreen()),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
