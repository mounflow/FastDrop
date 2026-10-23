import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:fastdrop_mobile/core/server/session_manager.dart';
import 'package:fastdrop_mobile/core/server/transfer_receiver.dart';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 固定的服务端口（spec 约定）：入站连接的对端地址由其 IP + 本端口推导。
const int fastDropServerPort = 9527;

/// 从入站 shelf 请求推导对端的基址（`http://<ip>:9527`）。
///
/// 用于"一次连接即建立双向通道"：被连方从**入站连接本身**取得对端地址，
/// 从而可直接回连，不必依赖 mDNS 发现（mDNS 仍是常规发现路径）。
String? peerBaseUrlFromRequest(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return null;
  final address = info.remoteAddress;
  if (address.address.isEmpty) return null;
  final host = address.address.contains(':')
      ? '[${address.address}]' // IPv6 字面量
      : address.address;
  return 'http://$host:$fastDropServerPort';
}

/// A connected WebSocket client.
class _WsConnection {
  _WsConnection(this.channel, this.sessionId, {this.peerBaseUrl});

  final WebSocketChannel channel;
  String sessionId;
  Timer? heartbeatTimer;
  int missedPongs = 0;
  bool authenticated = false;

  /// 认证后填充：该连接所属设备（用于按设备断开其全部连接）。
  String deviceId = '';

  /// 该连接的来源基址（`http://<ip>:9527`），用于反向回连。
  final String? peerBaseUrl;
}

/// Public, token-free view of a device connected to the embedded server.
class AuthenticatedPeer {
  const AuthenticatedPeer({
    required this.sessionId,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    this.remoteBaseUrl,
  });

  final String sessionId;
  final String deviceId;
  final String deviceName;
  final String platform;

  /// 该对端连接进来的来源基址（`http://<ip>:9527`）。用于"被连方主动
  /// 回连"——地址由入站连接直接观测得到，比 mDNS 缓存更可靠。
  final String? remoteBaseUrl;
}

typedef PeerConnectedCallback = void Function(AuthenticatedPeer peer);
typedef PeerDisconnectedCallback = void Function(String sessionId);

/// 一条收到的文本消息（text.send，spec §8.2）。
class ServerTextMessage {
  const ServerTextMessage({
    required this.sessionId,
    required this.deviceId,
    required this.deviceName,
    required this.textId,
    required this.text,
  });

  final String sessionId;
  final String deviceId;
  final String deviceName;
  final String textId;
  final String text;
}

typedef TextReceivedCallback = void Function(ServerTextMessage message);

/// WebSocket hub for the embedded FastDrop server.
///
/// Implements the auth-first-message protocol, heartbeat (15s ping,
/// 3 missed pongs = disconnect), and event broadcasting matching
/// the Go backend's message-type catalog (§8).
class WsServer {
  WsServer({
    required SessionManager sessionManager,
    TransferReceiver? transferReceiver,
    this.onPeerConnected,
    this.onPeerDisconnected,
    this.onTextReceived,
  })  : _sessionManager = sessionManager,
        _transferReceiver = transferReceiver;

  final SessionManager _sessionManager;
  final TransferReceiver? _transferReceiver;
  final PeerConnectedCallback? onPeerConnected;
  final PeerDisconnectedCallback? onPeerDisconnected;

  /// 收到 text.send 时的回调（UI 层弹出文本对话框）。
  final TextReceivedCallback? onTextReceived;

  /// text.send 文本上限（UTF-8 字节数，与 Go 端 TextMaxBytes 一致）。
  static const textMaxBytes = 64 * 1024;

  final HashMap<String, _WsConnection> _connections = HashMap();

  static const _heartbeatInterval = Duration(seconds: 15);
  static const _maxMissedPongs = 3;

  /// Wire up progress events from the transfer receiver to WS broadcast.
  void wireTransferProgress() {
    final receiver = _transferReceiver;
    if (receiver == null) return;
    receiver.onProgress = (event) {
      final sessionId = receiver.getTransfer(event.transferId)?.sessionId;
      if (sessionId != null) {
        sendToSession(sessionId, 'transfer.progress', event.toJson());
      }
    };
  }

  // ---------------------------------------------------------------------------
  // Shelf handler
  // ---------------------------------------------------------------------------

  /// Returns a shelf Handler for the `/ws/v1` WebSocket endpoint.
  ///
  /// 包一层普通 Handler 是为了先读到 `shelf.io.connection_info`（对端地址）
  /// ——`webSocketHandler` 的回调只拿到 channel，拿不到原始 Request。
  /// 每次请求现建一个 webSocketHandler，让闭包持有该请求的地址（升级是
  /// 异步完成的，用实例字段会有竞态）。
  Handler get handler {
    return (Request request) {
      final peerBaseUrl = peerBaseUrlFromRequest(request);
      return webSocketHandler(
        (WebSocketChannel webSocket, String? subprotocol) {
          _handleConnection(webSocket, peerBaseUrl);
        },
      )(request);
    };
  }

  void _handleConnection(WebSocketChannel webSocket, String? peerBaseUrl) {
    debugPrint(
        '[WsServer] New WebSocket connection (from ${peerBaseUrl ?? '?'})');

    // Create a temporary connection (not yet authenticated).
    final connId = DateTime.now().microsecondsSinceEpoch.toString();
    final conn = _WsConnection(webSocket, connId, peerBaseUrl: peerBaseUrl);

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
      _send(conn, {
        'type': 'error',
        'payload': {'message': 'Invalid JSON'}
      });
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
      case 'heartbeat.ping':
        conn.missedPongs = 0;
        _send(conn, {'type': 'heartbeat.pong'});
        break;

      case 'heartbeat.pong':
        conn.missedPongs = 0;
        break;

      case 'transfer.cancel':
        final payload = msg['payload'] as Map<String, dynamic>?;
        final transferId = payload?['transferId'] as String?;
        if (transferId != null) {
          // 属主校验：会话只能取消自己的传输（对齐 pause/resume 与 Go 端行为），
          // 不匹配时向该会话回错误；回执用 sendToSession 定向发送而非广播。
          final cancelled = _transferReceiver?.cancelTransfer(
                transferId,
                sessionId: conn.sessionId,
              ) ??
              false;
          if (!cancelled) {
            _send(conn, {
              'type': 'error',
              'payload': {
                'code': 'SESSION_INVALID',
                'message': 'Transfer cannot be cancelled by this session',
              },
            });
            break;
          }
          sendToSession(
            conn.sessionId,
            'transfer.cancelled',
            {'transferId': transferId},
          );
        }
        break;

      case 'transfer.pause':
        final payload = msg['payload'] as Map<String, dynamic>?;
        final transferId = payload?['transferId'] as String?;
        if (transferId == null ||
            !(_transferReceiver?.pauseTransfer(
                  transferId,
                  conn.sessionId,
                ) ??
                false)) {
          _send(conn, {
            'type': 'error',
            'payload': {
              'code': 'INVALID_REQUEST',
              'message': 'Transfer cannot be paused',
            },
          });
          break;
        }
        sendToSession(
          conn.sessionId,
          'transfer.paused',
          {'transferId': transferId},
        );
        break;

      case 'transfer.resume':
        final payload = msg['payload'] as Map<String, dynamic>?;
        final transferId = payload?['transferId'] as String?;
        if (transferId == null ||
            !(_transferReceiver?.resumeTransfer(
                  transferId,
                  conn.sessionId,
                ) ??
                false)) {
          _send(conn, {
            'type': 'error',
            'payload': {
              'code': 'INVALID_REQUEST',
              'message': 'Transfer cannot be resumed',
            },
          });
          break;
        }
        sendToSession(
          conn.sessionId,
          'transfer.resume',
          {'transferId': transferId},
        );
        break;

      case 'text.send': {
        // 文本快传：已认证会话内直传短文本（不落盘）。只记长度，不记内容。
        final payload = msg['payload'] as Map<String, dynamic>?;
        final textId = payload?['textId'] as String? ?? '';
        final text = payload?['text'] as String? ?? '';
        final byteLen = utf8.encode(text).length;
        if (textId.isEmpty || text.isEmpty || byteLen > textMaxBytes) {
          _send(conn, {
            'type': 'error',
            'payload': {
              'code': 'INVALID_REQUEST',
              'message': 'Invalid text.send payload',
            },
          });
          break;
        }
        _send(conn, {'type': 'text.ack', 'payload': {'textId': textId}});
        final session = _sessionManager.get(conn.sessionId);
        onTextReceived?.call(ServerTextMessage(
          sessionId: conn.sessionId,
          deviceId: session?.deviceId ?? conn.deviceId,
          deviceName: session?.deviceName ?? '',
          textId: textId,
          text: text,
        ));
        break;
      }

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
        'type': 'auth.result',
        'payload': {'ok': false, 'message': 'Missing sessionId or accessToken'},
      });
      return;
    }

    if (!_sessionManager.validate(sessionId, accessToken)) {
      _send(conn, {
        'type': 'auth.result',
        'payload': {'ok': false, 'message': 'Invalid session'},
      });
      return;
    }

    final session = _sessionManager.get(sessionId);
    if (session == null) {
      _send(conn, {
        'type': 'auth.result',
        'payload': {'ok': false, 'message': 'Invalid session'},
      });
      return;
    }

    // Authenticated. Keep the original connection object because the stream
    // listener closes over it; replacing it would make heartbeat pongs update
    // a stale object while the watchdog increments a different one.
    authTimeout.cancel();
    conn.authenticated = true;

    // Re-register under the real sessionId.
    final oldId = conn.sessionId;
    _connections.remove(oldId);

    // Close any existing connection for this session.
    _connections[sessionId]
        ?.channel
        .sink
        .close(4002, 'Replaced by new connection');

    conn.sessionId = sessionId;
    conn.deviceId = session.deviceId;
    _connections[sessionId] = conn;

    // Start heartbeat for this connection.
    _startHeartbeat(conn);

    _send(conn, {
      'type': 'auth.result',
      'payload': {'ok': true},
    });

    onPeerConnected?.call(AuthenticatedPeer(
      sessionId: session.sessionId,
      deviceId: session.deviceId,
      deviceName: session.deviceName,
      platform: session.platform,
      remoteBaseUrl: conn.peerBaseUrl,
    ));

    debugPrint(
        '[WsServer] Session authenticated: ${sessionId.substring(0, 8)}...');
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
      _send(conn, {'type': 'heartbeat.ping'});
    });
  }

  void _handleDisconnect(_WsConnection conn) {
    conn.heartbeatTimer?.cancel();
    if (!identical(_connections[conn.sessionId], conn)) return;
    _connections.remove(conn.sessionId);
    if (conn.authenticated) {
      onPeerDisconnected?.call(conn.sessionId);
    }
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
  void sendToSession(
      String sessionId, String type, Map<String, dynamic> payload) {
    final conn = _connections[sessionId];
    if (conn != null && conn.authenticated) {
      _send(conn, {'type': type, 'payload': payload});
    }
  }

  /// 断开某设备在本机的全部 WebSocket 连接（删除设备时调用）。
  ///
  /// 先推 `session.revoked`（spec §8 消息类型）让对端立即收摊，再主动关闭
  /// 连接——"删除 = 双向真正断开"的 WS 侧动作。
  void disconnectDeviceSessions(String deviceId,
      {String reason = 'session revoked by peer'}) {
    for (final entry in _connections.entries.toList()) {
      final conn = entry.value;
      if (conn.deviceId != deviceId) continue;
      try {
        _send(conn, {
          'type': 'session.revoked',
          'payload': {'reason': reason},
        });
      } catch (_) {}
      try {
        conn.channel.sink.close(4004, reason);
      } catch (_) {}
      _handleDisconnect(conn);
    }
  }

  /// Notify all connections about a transfer offer.
  void notifyTransferOffer(
      String transferId, Map<String, dynamic> transferJson) {
    final sessionId = _transferReceiver?.getTransfer(transferId)?.sessionId;
    if (sessionId == null) return;
    sendToSession(sessionId, 'file.offer', {
      'transferId': transferId,
      ...transferJson,
    });
  }

  /// Notify about transfer acceptance/rejection.
  void notifyTransferResolution(String transferId, String status) {
    final sessionId = _transferReceiver?.getTransfer(transferId)?.sessionId;
    if (sessionId == null) return;
    sendToSession(sessionId, 'transfer.$status', {'transferId': transferId});
  }

  /// Notify about transfer completion.
  void notifyTransferCompleted(String transferId) {
    final sessionId = _transferReceiver?.getTransfer(transferId)?.sessionId;
    if (sessionId == null) return;
    sendToSession(sessionId, 'transfer.completed', {'transferId': transferId});
  }

  /// Notify about transfer failure.
  void notifyTransferFailed(String transferId, String reason) {
    final sessionId = _transferReceiver?.getTransfer(transferId)?.sessionId;
    if (sessionId == null) return;
    sendToSession(sessionId, 'transfer.failed', {
      'transferId': transferId,
      'reason': reason,
    });
  }

  /// Close all connections (server shutdown).
  void closeAll() {
    final connections = _connections.values.toList(growable: false);
    _connections.clear();
    for (final conn in connections) {
      conn.heartbeatTimer?.cancel();
      conn.channel.sink.close(1001, 'Server shutting down');
      if (conn.authenticated) {
        onPeerDisconnected?.call(conn.sessionId);
      }
    }
  }

  void _send(_WsConnection conn, Map<String, dynamic> msg) {
    try {
      conn.channel.sink.add(jsonEncode(msg));
    } catch (e) {
      debugPrint('[WsServer] Send error: $e');
    }
  }
}
