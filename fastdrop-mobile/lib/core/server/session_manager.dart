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
          return _unauthorized('Missing Authorization or X-Session-Id header');
        }

        final token = authHeader.substring(7);
        if (!validate(sessionId, token)) {
          return _unauthorized('Invalid or expired session');
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
