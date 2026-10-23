import 'dart:collection';

import 'package:fastdrop_mobile/core/security/token.dart';
import 'package:shelf/shelf.dart';

/// In-memory server-side session store.
///
/// Mirrors the Go backend's session behaviour: 12-hour TTL, token hashing,
/// full invalidation on server restart.
class ServerSession {
  ServerSession({
    required this.sessionId,
    required this.tokenHash,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.expiresAt,
  });

  final String sessionId;

  /// SHA-256 hash of the access token (never store plaintext).
  final String tokenHash;

  final String deviceId;
  final String deviceName;
  final String platform;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Manages server-side sessions for the embedded FastDrop server.
class SessionManager {
  static const sessionTtl = Duration(hours: 12);

  final HashMap<String, ServerSession> _sessions = HashMap();

  /// Create a new session for a paired device.
  ///
  /// Returns `(sessionId, accessToken)` — the token is returned once in
  /// plaintext (for the pair-accept response) but only its hash is stored.
  ({String sessionId, String accessToken}) createSession({
    required String deviceId,
    required String deviceName,
    required String platform,
  }) {
    final sessionId = TokenManager.generateToken();
    final accessToken = TokenManager.generateToken();
    final tokenHash = TokenManager.sha256Hash(accessToken);

    _sessions[sessionId] = ServerSession(
      sessionId: sessionId,
      tokenHash: tokenHash,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
      expiresAt: DateTime.now().add(sessionTtl),
    );

    return (sessionId: sessionId, accessToken: accessToken);
  }

  /// Validate a session by id + plaintext token.
  bool validate(String sessionId, String accessToken) {
    final session = _sessions[sessionId];
    if (session == null) return false;
    if (session.isExpired) {
      _sessions.remove(sessionId);
      return false;
    }
    return session.tokenHash == TokenManager.sha256Hash(accessToken);
  }

  /// Look up a session by id (must still be valid).
  ServerSession? get(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) return null;
    if (session.isExpired) {
      _sessions.remove(sessionId);
      return null;
    }
    return session;
  }

  /// Invalidate all sessions (called on server restart, matching Go
  /// behaviour).
  void invalidateAll() => _sessions.clear();

  /// 吊销某个设备在本机的全部会话（返回被吊销的会话 id 列表）。
  ///
  /// 用于"删除设备 = 双向真正断开"：只清本地设备记录是不够的，必须让对端
  /// 立即失去访问权（其分块请求会拿到 401 SESSION_REVOKED）。
  List<String> revokeByDeviceId(String deviceId) {
    final revoked = <String>[];
    _sessions.removeWhere((sessionId, session) {
      if (session.deviceId != deviceId) return false;
      revoked.add(sessionId);
      return true;
    });
    return revoked;
  }

  /// 该设备当前是否在本机持有有效会话。
  bool hasSessionForDevice(String deviceId) => _sessions.values
      .any((s) => s.deviceId == deviceId && !s.isExpired);

  /// Remove expired sessions.
  void purgeExpired() {
    _sessions.removeWhere((_, s) => s.isExpired);
  }

  // ---------------------------------------------------------------------------
  // Shelf auth middleware
  // ---------------------------------------------------------------------------

  /// Paths that do not require authentication.
  static const _publicPrefixes = [
    '/api/v1/health',
    '/api/v1/pair/',
  ];

  /// Shelf middleware that enforces `Authorization: Bearer` +
  /// `X-Session-Id` on protected routes.
  Middleware get authMiddleware {
    return (Handler innerHandler) {
      return (Request request) async {
        final path = '/${request.url.path}';

        // Allow public endpoints through.
        for (final prefix in _publicPrefixes) {
          if (path.startsWith(prefix)) {
            return innerHandler(request);
          }
        }

        // WebSocket upgrade — auth is handled post-connect via first message.
        if (path.startsWith('/ws/')) {
          return innerHandler(request);
        }

        final authHeader = request.headers['authorization'] ?? '';
        final sessionId = request.headers['x-session-id'] ?? '';

        if (!authHeader.startsWith('Bearer ') || sessionId.isEmpty) {
          return _unauthorized('缺少 Authorization 或 X-Session-Id 请求头');
        }

        final token = authHeader.substring(7);
        if (!validate(sessionId, token)) {
          return _unauthorized('会话无效或已过期');
        }

        // Stash the session id for downstream handlers.
        final updated = request.change(context: {
          ...request.context,
          'fastdrop.sessionId': sessionId,
        });
        return innerHandler(updated);
      };
    };
  }

  static Response _unauthorized(String message) {
    return Response(
      401,
      body: '{"error":{"code":"UNAUTHORIZED","message":"$message"}}',
      headers: {'content-type': 'application/json'},
    );
  }
}
