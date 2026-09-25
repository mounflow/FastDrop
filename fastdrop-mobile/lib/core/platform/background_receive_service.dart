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

  /// 问题 9（小改档）：是否已在电池优化白名单内。判定不可用时按
  /// "已优化"处理，避免误引导用户。
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// 跳转系统的电池优化白名单设置页（用户手动加入，通用适配所有厂商）。
  static Future<void> openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openBatteryOptimizationSettings');
  }

  /// L15: 用系统查看器打开已接收的文件。
  static Future<void> openFile(String path) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openFile', {'path': path});
  }
}
