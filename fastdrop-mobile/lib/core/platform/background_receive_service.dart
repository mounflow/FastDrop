import 'dart:io';

import 'package:flutter/services.dart';

class BackgroundReceiveService {
  static const _channel = MethodChannel('fastdrop/platform');

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('startKeepAlive');
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopKeepAlive');
  }
}
