import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fastdrop_mobile/core/network/http_client.dart';
import 'package:fastdrop_mobile/core/network/ws_client.dart';
import 'package:fastdrop_mobile/core/storage/session_store.dart';
import 'package:fastdrop_mobile/core/security/token.dart';

// ---------------------------------------------------------------------------
// Singletons
// ---------------------------------------------------------------------------

/// Shared [FastDropHttpClient] instance, reused across the app.
final httpClientProvider = Provider<FastDropHttpClient>((ref) {
  return FastDropHttpClient();
});

/// Shared [FastDropWsClient] instance, reused across the app.
final wsClientProvider = Provider<FastDropWsClient>((ref) {
  return FastDropWsClient();
});

/// Shared [SessionStore] for persisting session data.
final sessionStoreProvider = Provider<SessionStore>((ref) {
  return SessionStore();
});

// ---------------------------------------------------------------------------
// Device ID
// ---------------------------------------------------------------------------

/// Generates and persists a device ID so that the phone always uses the same
/// identifier across pairings.
class DeviceIdManager {
  DeviceIdManager._();

  static const _key = 'fastdrop.device_id';

  /// Returns the persisted device ID, generating one on first call.
  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_key);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final newId = TokenManager.generateToken();
    await prefs.setString(_key, newId);
    return newId;
  }
}
