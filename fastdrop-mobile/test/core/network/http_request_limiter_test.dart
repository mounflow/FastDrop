import 'dart:async';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shared limiter never permits more than six concurrent requests',
      () async {
    final limiter = HttpRequestLimiter(6);
    final release = Completer<void>();
    var active = 0;
    var maximumObserved = 0;
    var started = 0;

    final futures = List.generate(18, (_) {
      return limiter.run(() async {
        started++;
        active++;
        if (active > maximumObserved) maximumObserved = active;
        await release.future;
        active--;
      });
    });

    await Future<void>.delayed(Duration.zero);
    expect(started, 6);
    expect(limiter.active, 6);

    release.complete();
    await Future.wait(futures);

    expect(maximumObserved, 6);
    expect(limiter.active, 0);
  });
}
