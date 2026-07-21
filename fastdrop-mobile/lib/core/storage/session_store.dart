import 'package:shared_preferences/shared_preferences.dart';

/// Persists the current session to [SharedPreferences] so the app can
/// survive restarts and reconnect within the session TTL (12 hours).
class SessionStore {
  SessionStore();

  static const _keySessionId = 'fastdrop.session_id';
  static const _keyAccessToken = 'fastdrop.access_token';
  static const _keyServerBaseUrl = 'fastdrop.server_base_url';
  static const _keyServerName = 'fastdrop.server_name';
  static const _keyDeviceName = 'fastdrop.device_name';
  static const _keyExpiresAt = 'fastdrop.expires_at';

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  Future<void> saveSession({
    required String sessionId,
    required String accessToken,
    required String serverBaseUrl,
    String? serverName,
    String? deviceName,
    DateTime? expiresAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySessionId, sessionId);
    await prefs.setString(_keyAccessToken, accessToken);
    await prefs.setString(_keyServerBaseUrl, serverBaseUrl);
    if (serverName != null) {
      await prefs.setString(_keyServerName, serverName);
    } else {
      await prefs.remove(_keyServerName);
    }
    if (deviceName != null) {
      await prefs.setString(_keyDeviceName, deviceName);
    } else {
      await prefs.remove(_keyDeviceName);
    }
    if (expiresAt != null) {
      await prefs.setString(_keyExpiresAt, expiresAt.toIso8601String());
    } else {
      await prefs.remove(_keyExpiresAt);
    }
  }

  // ---------------------------------------------------------------------------
  // Load
  // ---------------------------------------------------------------------------

  Future<SessionData?> loadSession() async {
    final prefs = await SharedPreferences.getInstance();

    final sessionId = prefs.getString(_keySessionId);
    final accessToken = prefs.getString(_keyAccessToken);
    final serverBaseUrl = prefs.getString(_keyServerBaseUrl);

    if (sessionId == null || accessToken == null || serverBaseUrl == null) {
      return null;
    }

    final expiresAtStr = prefs.getString(_keyExpiresAt);
    DateTime? expiresAt;
    if (expiresAtStr != null) {
      expiresAt = DateTime.tryParse(expiresAtStr);
    }

    // Check expiry.
    if (expiresAt != null && expiresAt.isBefore(DateTime.now())) {
      await clearSession();
      return null;
    }

    return SessionData(
      sessionId: sessionId,
      accessToken: accessToken,
      serverBaseUrl: serverBaseUrl,
      serverName: prefs.getString(_keyServerName),
      deviceName: prefs.getString(_keyDeviceName),
      expiresAt: expiresAt,
    );
  }

  // ---------------------------------------------------------------------------
  // Clear
  // ---------------------------------------------------------------------------

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySessionId);
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyServerBaseUrl);
    await prefs.remove(_keyServerName);
    await prefs.remove(_keyDeviceName);
    await prefs.remove(_keyExpiresAt);
  }
}

/// Simple value object holding session state loaded from storage.
class SessionData {
  const SessionData({
    required this.sessionId,
    required this.accessToken,
    required this.serverBaseUrl,
    this.serverName,
    this.deviceName,
    this.expiresAt,
  });

  final String sessionId;
  final String accessToken;
  final String serverBaseUrl;
  final String? serverName;
  final String? deviceName;
  final DateTime? expiresAt;

  bool get isExpired {
    if (expiresAt == null) return false;
    return expiresAt!.isBefore(DateTime.now());
  }

  /// Returns true if the session exists and has not expired.
  bool get isSessionValid => !isExpired;
}
