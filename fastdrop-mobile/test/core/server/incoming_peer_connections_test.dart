import 'package:fastdrop_mobile/core/server/pairing_providers.dart';
import 'package:fastdrop_mobile/core/server/ws_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('incoming peers are added, replaced by device, and removed by session',
      () {
    final notifier = IncomingPeerConnectionsNotifier();

    const first = AuthenticatedPeer(
      sessionId: 'session-1',
      deviceId: 'device-1',
      deviceName: 'Phone 1',
      platform: 'android',
    );
    const replacement = AuthenticatedPeer(
      sessionId: 'session-2',
      deviceId: 'device-1',
      deviceName: 'Phone 1',
      platform: 'android',
    );

    notifier.connected(first);
    expect(notifier.state.keys, ['session-1']);

    notifier.connected(replacement);
    expect(notifier.state.keys, ['session-2']);

    notifier.disconnected('session-1');
    expect(notifier.state.keys, ['session-2']);

    notifier.disconnected('session-2');
    expect(notifier.state, isEmpty);
  });
}
