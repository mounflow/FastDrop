import 'package:fastdrop_mobile/app/theme.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/features/conversation/conversation_screen.dart';
import 'package:fastdrop_mobile/features/devices/multi_device_connection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestMultiDeviceConnectionNotifier extends MultiDeviceConnectionNotifier {
  _TestMultiDeviceConnectionNotifier(
    super.ref,
    MultiDeviceConnectionState initialState,
  ) {
    state = initialState;
  }
}

Device _device() => Device(
      id: 'http://192.168.1.10:9527',
      name: 'Office PC',
      serverBaseUrl: 'http://192.168.1.10:9527',
      sessionId: 'session',
      accessToken: 'token',
      lastSeen: DateTime.utc(2026, 8, 5),
      platform: 'windows',
    );

Future<void> _pumpConversation(
  WidgetTester tester,
  MultiConnectionStatus status,
) async {
  SharedPreferences.setMockInitialValues({});
  final device = _device();
  final connectionState = MultiDeviceConnectionState(
    selectedDeviceId: device.id,
    peers: {
      device.id: PeerConnectionView(device: device, status: status),
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        multiDeviceConnectionProvider.overrideWith(
          (ref) => _TestMultiDeviceConnectionNotifier(ref, connectionState),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: ConversationScreen(device: device),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('AppBar 显示设备名与状态', (tester) async {
    await _pumpConversation(tester, MultiConnectionStatus.connected);

    expect(find.text('Office PC'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
  });

  testWidgets('没有历史时显示空态而不是空白', (tester) async {
    await _pumpConversation(tester, MultiConnectionStatus.idle);

    expect(find.text('还没有传输记录'), findsOneWidget);
  });

  testWidgets('离线时输入区禁用并说明原因', (tester) async {
    await _pumpConversation(tester, MultiConnectionStatus.idle);

    expect(find.text('离线'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    // 局域网直传没有中转：离线必须直接禁用，而不是做个看起来能发的假队列。
    expect(find.text('设备不在线，无法发送'), findsOneWidget);

    final sendButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send_rounded),
    );
    expect(sendButton.onPressed, isNull);
  });

  testWidgets('在线时输入区可用且发送按钮激活', (tester) async {
    await _pumpConversation(tester, MultiConnectionStatus.connected);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);

    final sendButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send_rounded),
    );
    expect(sendButton.onPressed, isNotNull);
  });
}
