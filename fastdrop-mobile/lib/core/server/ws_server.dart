import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:fastdrop_mobile/core/server/session_manager.dart';
import 'package:fastdrop_mobile/core/server/transfer_receiver.dart';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A connected WebSocket client.
class _WsConnection {
  _WsConnection(this.channel, this.sessionId);

  final WebSocketChannel channel;
  final String sessionId;
  Timer? heartbeatTimer;
  int missedPongs = 0;
  bool authenticated = false;
}

/// WebSocket hub for the embedded FastDrop server.
///
/// Implements the auth-first-message protocol, heartbeat (15s ping,
/// 3 missed pongs = disconnect), and event broadcasting matching
/// the Go backend's message-type catalog (§8).
class WsServer {
  WsServer({
    required SessionManager sessionManager,
    TransferReceiver? transferReceiver,
  })  : _sessionManager = sessionManager,
        _transferReceiver = transferReceiver;

  final SessionManager _sessionManager;
  final TransferReceiver? _transferReceiver;

  final HashMap<String, _WsConnection> _connections = HashMap();

  static const _heartbeatInterval = Duration(seconds: 15);
  static const _maxMissedPongs = 3;

  /// Wire up progress events from the transfer receiver to WS broadcast.
  void wireTransferProgress() {
    _transferReceiver?.onProgress = (event) {
      broadcast('transfer_progress', event.toJson());
    };
  }

  // ---------------------------------------------------------------------------
  // Shelf handler
  // ---------------------------------------------------------------------------

  /// Returns a shelf Handler for the `/ws/v1` WebSocket endpoint.
  Handler get handler {
    return webSocketHandler((WebSocketChannel webSocket, String? subprotocol) {
      _handleConnection(webSocket);
    });
  }

  void _handleConnection(WebSocketChannel webSocket) {
    debugPrint('[WsServer] New WebSocket connection');

    // Create a temporary connection (not yet authenticated).
    final connId = DateTime.now().microsecondsSinceEpoch.toString();
    final conn = _WsConnection(webSocket, connId);

    // Auth timeout: if not authenticated within 10s, disconnect.
    final authTimeout = Timer(const Duration(seconds: 10), () {
      if (!conn.authenticated) {
        debugPrint('[WsServer] Auth timeout, closing connection');
        webSocket.sink.close(4001, 'Authentication timeout');
      }
    });

    webSocket.stream.listen(
      (data) => _handleMessage(conn, data, authTimeout),
      onDone: () => _handleDisconnect(conn),
      onError: (error) {
        debugPrint('[WsServer] WS error: $error');
        _handleDisconnect(conn);
      },
    );
  }

  void _handleMessage(
    _WsConnection conn,
    dynamic data,
    Timer authTimeout,
  ) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      _send(conn, {'type': 'error', 'payload': {'message': 'Invalid JSON'}});
      return;
    }

    final type = msg['type'] as String?;

    // Before authentication, only accept auth messages.
    if (!conn.authenticated) {
      if (type == 'auth') {
        _handleAuth(conn, msg, authTimeout);
      } else {
        _send(conn, {
          'type': 'error',
          'payload': {'message': 'Not authenticated. Send auth first.'},
        });
      }
      return;
    }

    // Authenticated message handling.
    switch (type) {
      case 'ping':
        conn.missedPongs = 0;
        _send(conn, {'type': 'pong'});
        break;

      case 'pong':
        conn.missedPongs = 0;
        break;

      case 'transfer_cancel':
        final payload = msg['payload'] as Map<String, dynamic>?;
        final transferId = payload?['transferId'] as String?;
        if (transferId != null) {
          _transferReceiver?.cancelTransfer(transferId);
          broadcast('transfer_cancelled', {'transferId': transferId});
        }
        break;

      default:
        debugPrint('[WsServer] Unknown message type: $type');
    }
  }

  void _handleAuth(
    _WsConnection conn,
    Map<String, dynamic> msg,
    Timer authTimeout,
  ) {
    final payload = msg['payload'] as Map<String, dynamic>?;
    final sessionId = payload?['sessionId'] as String?;
    final accessToken = payload?['accessToken'] as String?;

    if (sessionId == null || accessToken == null) {
      _send(conn, {
        'type': 'auth_result',
        'payload': {'success': false, 'message': 'Missing sessionId or accessToken'},
      });
      return;
    }

    if (!_sessionManager.validate(sessionId, accessToken)) {
      _send(conn, {
        'type': 'auth_result',
        'payload': {'success': false, 'message': 'Invalid session'},
      });
      return;
    }

    // Authenticated!
    authTimeout.cancel();
    conn.authenticated = true;

    // Re-register under the real sessionId.
    final oldId = conn.sessionId;
    _connections.remove(oldId);

    // Close any existing connection for this session.
    _connections[sessionId]?.channel.sink.close(4002, 'Replaced by new connection');

    final newConn = _WsConnection(conn.channel, sessionId)..authenticated = true;
    _connections[sessionId] = newConn;

    // Start heartbeat for this connection.
    _startHeartbeat(newConn);

    _send(newConn, {
      'type': 'auth_result',
      'payload': {'success': true},
    });

    debugPrint('[WsServer] Session authenticated: ${sessionId.substring(0, 8)}...');
  }

  void _startHeartbeat(_WsConnection conn) {
    conn.heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      conn.missedPongs++;
      if (conn.missedPongs >= _maxMissedPongs) {
        debugPrint('[WsServer] Heartbeat timeout for ${conn.sessionId}');
        conn.channel.sink.close(4003, 'Heartbeat timeout');
        _handleDisconnect(conn);
        return;
      }
      _send(conn, {'type': 'ping'});
    });
  }

  void _handleDisconnect(_WsConnection conn) {
    conn.heartbeatTimer?.cancel();
    _connections.remove(conn.sessionId);
    debugPrint('[WsServer] Disconnected: ${conn.sessionId}');
  }

  // ---------------------------------------------------------------------------
  // Broadcasting
  // ---------------------------------------------------------------------------

  /// Broadcast a message to all authenticated connections.
  void broadcast(String type, Map<String, dynamic> payload) {
    final msg = jsonEncode({'type': type, 'payload': payload});
    for (final conn in _connections.values) {
      if (conn.authenticated) {
        try {
          conn.channel.sink.add(msg);
        } catch (e) {
          debugPrint('[WsServer] Broadcast send error: $e');
        }
      }
    }
  }

  /// Send a message to a specific session.
  void sendToSession(String sessionId, String type, Map<String, dynamic> payload) {
    final conn = _connections[sessionId];
    if (conn != null && conn.authenticated) {
      _send(conn, {'type': type, 'payload': payload});
    }
  }

  /// Notify all connections about a transfer offer.
  void notifyTransferOffer(String transferId, Map<String, dynamic> transferJson) {
    broadcast('transfer_offer', {
      'transferId': transferId,
      ...transferJson,
    });
  }

  /// Notify about transfer acceptance/rejection.
  void notifyTransferResolution(String transferId, String status) {
    broadcast('transfer_$status', {'transferId': transferId});
  }

  /// Notify about transfer completion.
  void notifyTransferCompleted(String transferId) {
    broadcast('transfer_completed', {'transferId': transferId});
  }

  /// Notify about transfer failure.
  void notifyTransferFailed(String transferId, String reason) {
    broadcast('transfer_failed', {
      'transferId': transferId,
      'reason': reason,
    });
  }

  /// Close all connections (server shutdown).
  void closeAll() {
    for (final conn in _connections.values) {
      conn.heartbeatTimer?.cancel();
      conn.channel.sink.close(1001, 'Server shutting down');
    }
    _connections.clear();
  }

  void _send(_WsConnection conn, Map<String, dynamic> msg) {
    try {
      conn.channel.sink.add(jsonEncode(msg));
    } catch (e) {
      debugPrint('[WsServer] Send error: $e');
    }
  }
}
