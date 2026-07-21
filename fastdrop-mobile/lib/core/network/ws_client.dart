import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Typedefs for callback-based message handling.
typedef OnMessageCallback = void Function(Map<String, dynamic> message);
typedef OnDisconnectedCallback = void Function();

/// FastDrop WebSocket client.
///
/// Handles auto-auth on connect, periodic heartbeats (15 s ping /
/// 3 missed pongs = disconnected), and a reconnect loop with a
/// 60-second grace period.
class FastDropWsClient {
  FastDropWsClient({
    this.onMessage,
    this.onDisconnected,
    this.onConnected,
  });

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  /// Base URL of the server. Will append `/ws/v1`.
  String? baseUrl;

  String? _sessionId;
  String? _accessToken;

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  static const Duration _pingInterval = Duration(seconds: 15);
  static const int _maxMissedPongs = 3;
  static const Duration _reconnectGracePeriod = Duration(seconds: 60);

  // ---------------------------------------------------------------------------
  // Callbacks
  // ---------------------------------------------------------------------------

  OnMessageCallback? onMessage;
  OnDisconnectedCallback? onDisconnected;
  _VoidCallback? onConnected;
  _VoidCallback? onAuthFailed;

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  int _missedPongs = 0;
  StreamSubscription<dynamic>? _subscription;
  bool _shouldReconnect = false;
  DateTime? _disconnectedAt;
  Timer? _reconnectTimer;
  bool _isConnected = false;
  bool _authPending = false;
  int _reconnectAttempts = 0;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  bool get isConnected => _isConnected;

  void setSession(String sessionId, String accessToken) {
    _sessionId = sessionId;
    _accessToken = accessToken;
  }

  Future<void> connect() async {
    if (baseUrl == null) {
      throw StateError('baseUrl must be set before connecting');
    }
    if (_sessionId == null || _accessToken == null) {
      throw StateError('Session credentials must be set before connecting');
    }

    _shouldReconnect = true;

    final uri = _buildUri();
    _channel = WebSocketChannel.connect(uri);

    await _channel!.ready;

    // Send auth message as the first frame (fallback when headers aren't
    // supported by the client).
    _authPending = true;
    _channel!.sink.add(jsonEncode({
      'version': 1,
      'type': 'auth',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'sessionId': _sessionId,
        'accessToken': _accessToken,
      },
    }));

    // Don't mark connected or fire onConnected until auth.result confirms.
    _missedPongs = 0;
    _reconnectAttempts = 0;

    _subscription = _channel!.stream.listen(
      _onData,
      onError: (error) => _handleDisconnect(),
      onDone: _handleDisconnect,
      cancelOnError: false,
    );

    _startHeartbeat();
  }

  void disconnect() {
    _shouldReconnect = false;
    _cleanup();
    _isConnected = false;
  }

  void send(Map<String, dynamic> message) {
    if (!_isConnected || _channel == null) return;
    _channel!.sink.add(jsonEncode(message));
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  Uri _buildUri() {
    // Replace http with ws (or https with wss) and append /ws/v1.
    // No credentials in the URL — auth is done via the first WS message.
    var url = baseUrl!;
    if (url.startsWith('https://')) {
      url = url.replaceFirst('https://', 'wss://');
    } else if (url.startsWith('http://')) {
      url = url.replaceFirst('http://', 'ws://');
    }
    if (!url.endsWith('/')) {
      url = '$url/';
    }
    url = '${url}ws/v1';
    return Uri.parse(url);
  }

  void _onData(dynamic data) {
    if (data is String) {
      try {
        final message = jsonDecode(data) as Map<String, dynamic>;
        final type = message['type'] as String?;

        if (type == 'heartbeat.pong') {
          _missedPongs = 0;
          return;
        }

        // Intercept auth.result — confirm or reject the connection.
        if (type == 'auth.result') {
          _authPending = false;
          final payload = message['payload'] as Map<String, dynamic>?;
          if (payload?['ok'] == true) {
            // Auth confirmed — now mark connected.
            _isConnected = true;
            onConnected?.call();
          } else {
            // Auth rejected — disconnect permanently (no reconnect).
            _shouldReconnect = false;
            onAuthFailed?.call();
            _handleDisconnect();
          }
          return;
        }

        onMessage?.call(message);
      } catch (_) {
        // Ignore malformed frames.
      }
    }
  }

  // -- Heartbeat --------------------------------------------------------------

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_pingInterval, (_) {
      if (!_isConnected) return;

      if (_missedPongs >= _maxMissedPongs) {
        _handleDisconnect();
        return;
      }

      send({
        'version': 1,
        'type': 'heartbeat.ping',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      _missedPongs++;
    });
  }

  // -- Reconnect --------------------------------------------------------------

  void _handleDisconnect() {
    if (_authPending) {
      // Connection closed before auth completed (e.g. server rejected
      // the session and dropped the connection). Treat as auth failure.
      _authPending = false;
      _shouldReconnect = false;
      _cleanup();
      onAuthFailed?.call();
      return;
    }

    if (!_isConnected) return;

    _cleanup();
    _isConnected = false;
    _disconnectedAt = DateTime.now();
    onDisconnected?.call();

    if (_shouldReconnect) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    final elapsed = DateTime.now().difference(_disconnectedAt!);
    if (elapsed > _reconnectGracePeriod) {
      // Grace period expired — stop trying.
      return;
    }

    // Exponential backoff with jitter (up to 10 s).
    _reconnectAttempts++;
    final backoffMs = min(10000, 500 * pow(2, _reconnectAttempts)).toInt();
    final jitterMs = Random().nextInt(1000);
    final delay = Duration(milliseconds: backoffMs + jitterMs);

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_shouldReconnect) return;
      _tryReconnect();
    });
  }

  Future<void> _tryReconnect() async {
    try {
      await connect();
    } catch (_) {
      if (_shouldReconnect) {
        _scheduleReconnect();
      }
    }
  }

  // -- Cleanup ----------------------------------------------------------------

  void _cleanup() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }
}

/// Local alias so that callbacks can be typed without importing `dart:ui`.
typedef _VoidCallback = void Function();
