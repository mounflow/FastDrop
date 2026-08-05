import 'package:fastdrop_mobile/features/transfer/transfer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('route arguments do not modify providers during build or dispose',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(arguments: {
          'filePaths': ['C:\\not-used.txt'],
          'targetDeviceIds': ['offline-device'],
        }),
        builder: (_) => const TransferScreen(),
      ),
    );

    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
