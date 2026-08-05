import 'package:fastdrop_mobile/core/discovery/device_discovery.dart';
import 'package:fastdrop_mobile/core/discovery/discovery_providers.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/features/devices/multi_device_connection.dart';
import 'package:fastdrop_mobile/features/devices/nearby_devices_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestNearbyDevicesNotifier extends NearbyDevicesNotifier {
  _TestNearbyDevicesNotifier(super.ref, List<DiscoveredDevice> devices) {
    state = devices;
  }
}

class _TestMultiDeviceConnectionNotifier extends MultiDeviceConnectionNotifier {
  _TestMultiDeviceConnectionNotifier(
    super.ref,
    MultiDeviceConnectionState initialState,
  ) {
    state = initialState;
  }
}

void main() {
  testWidgets('connected device stays visible and cannot be connected twice',
      (tester) async {
    final paired = Device(
      id: 'http://192.168.1.10:9527',
      name: 'Office PC',
      serverBaseUrl: 'http://192.168.1.10:9527',
      sessionId: 'session',
      accessToken: 'token',
      lastSeen: DateTime.utc(2026, 8, 5),
      platform: 'windows',
    );
    final discovered = DiscoveredDevice(
      deviceId: 'office-pc',
      deviceName: 'Office PC',
      baseUrl: paired.serverBaseUrl,
      protocolVersion: 1,
      platform: 'windows',
      pairingRequired: true,
    );
    final connectionState = MultiDeviceConnectionState(
      selectedDeviceId: paired.id,
      peers: {
        paired.id: PeerConnectionView(
          device: paired,
          status: MultiConnectionStatus.connected,
        ),
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nearbyDevicesProvider.overrideWith(
            (ref) => _TestNearbyDevicesNotifier(ref, [discovered]),
          ),
          pairedDevicesProvider.overrideWith((ref) async => [paired]),
          multiDeviceConnectionProvider.overrideWith(
            (ref) => _TestMultiDeviceConnectionNotifier(ref, connectionState),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: NearbyDevicesSheet())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Office PC'), findsOneWidget);
    expect(find.byIcon(Icons.computer), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
  });

  testWidgets('android discovery result uses a phone icon', (tester) async {
    final discovered = DiscoveredDevice(
      deviceId: 'phone-id',
      deviceName: 'FastDrop-ABC123',
      baseUrl: 'http://192.168.1.20:9527',
      protocolVersion: 1,
      platform: 'android',
      pairingRequired: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nearbyDevicesProvider.overrideWith(
            (ref) => _TestNearbyDevicesNotifier(ref, [discovered]),
          ),
          pairedDevicesProvider.overrideWith((ref) async => []),
        ],
        child: const MaterialApp(home: Scaffold(body: NearbyDevicesSheet())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.phone_android), findsOneWidget);
    expect(find.text('FastDrop-ABC123'), findsOneWidget);
  });
}
