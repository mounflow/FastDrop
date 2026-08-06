import 'dart:convert';
import 'dart:io';

import 'package:fastdrop_mobile/core/server/pairing_handler.dart';
import 'package:fastdrop_mobile/core/server/session_manager.dart';
import 'package:fastdrop_mobile/core/server/transfer_receiver.dart';
import 'package:fastdrop_mobile/core/server/ws_server.dart';
import 'package:fastdrop_mobile/shared/models/device_info.dart';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

/// The embedded FastDrop server that runs on the phone/desktop so it can
/// **receive** files from other devices.
///
/// Binds `0.0.0.0:9527` and exposes the same REST + WS API surface as the
/// Go backend, backed by in-memory state (no SQLite).
class FastDropServer {
  FastDropServer({
    required DeviceInfo localDevice,
    bool requirePairConfirmation = false,
    PairRequestCallback? onPairRequest,
    TransferRequestCallback? onTransferRequest,
    PeerConnectedCallback? onPeerConnected,
    PeerDisconnectedCallback? onPeerDisconnected,
  }) : _localDevice = localDevice {
    sessionManager = SessionManager();
    pairingHandler = PairingHandler(
      sessionManager: sessionManager,
      localDevice: localDevice,
      requireConfirmation: requirePairConfirmation,
      onPairRequest: onPairRequest,
    );
    transferReceiver = TransferReceiver(
      sessionManager: sessionManager,
      onTransferRequest: onTransferRequest,
    );
    wsServer = WsServer(
      sessionManager: sessionManager,
      transferReceiver: transferReceiver,
      onPeerConnected: onPeerConnected,
      onPeerDisconnected: onPeerDisconnected,
    );
  }

  final DeviceInfo _localDevice;

  late final SessionManager sessionManager;
  late final PairingHandler pairingHandler;
  late final TransferReceiver transferReceiver;
  late final WsServer wsServer;

  HttpServer? _httpServer;
  bool _running = false;

  bool get isRunning => _running;
  int get port => 9527;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Start the embedded server on `0.0.0.0:9527`.
  Future<void> start() async {
    if (_running) return;

    // Wire transfer progress → WS broadcast.
    wsServer.wireTransferProgress();

    // Wire pairing resolutions → WS notifications.
    pairingHandler.onRequestResolved = (requestId, status) {
      wsServer.broadcast('pair_$status', {'requestId': requestId});
    };

    // Wire transfer requests → WS notifications.
    final origOnTransferRequest = transferReceiver.onTransferRequest;
    transferReceiver.onTransferRequest = (transfer) {
      // The authenticated peer created this transfer and already owns its
      // metadata. The local receive-confirmation UI is driven directly by
      // onTransferRequest; echoing file.offer over WS would make the sender
      // display its own upload as an incoming file.
      origOnTransferRequest?.call(transfer);
    };

    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware())
        .addMiddleware(sessionManager.authMiddleware)
        .addHandler(_buildRouter().call);

    _httpServer = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      port,
    );

    _running = true;
    debugPrint('[FastDropServer] Started on 0.0.0.0:$port '
        '(device: ${_localDevice.deviceName})');
  }

  /// Gracefully stop the server.
  Future<void> stop() async {
    if (!_running) return;

    debugPrint('[FastDropServer] Stopping...');

    // 1. Close all WebSocket connections.
    wsServer.closeAll();

    // 2. Invalidate all sessions (matches Go restart behaviour).
    sessionManager.invalidateAll();

    // 3. Close the HTTP server.
    await _httpServer?.close(force: true);
    _httpServer = null;

    _running = false;
    debugPrint('[FastDropServer] Stopped');
  }

  // ---------------------------------------------------------------------------
  // Router
  // ---------------------------------------------------------------------------

  Router _buildRouter() {
    final root = Router();

    // Health endpoint (public).
    root.get('/api/v1/health', (Request request) {
      return Response.ok(
        jsonEncode({
          'status': 'ok',
          'deviceId': _localDevice.deviceId,
          'deviceName': _localDevice.deviceName,
          'platform': _localDevice.platform,
          'appVersion': _localDevice.appVersion ?? '1.0.0',
          'protocol': 1,
        }),
        headers: {'content-type': 'application/json'},
      );
    });

    // Pairing routes (public).
    root.mount('/', pairingHandler.router.call);

    // Transfer routes (authenticated).
    root.mount('/', transferReceiver.router.call);

    // WebSocket endpoint (auth handled post-connect).
    root.all('/ws/v1', wsServer.handler);

    // Catch-all 404.
    root.all('/<ignored|.*>', (Request request) {
      return Response.notFound(
        jsonEncode({
          'error': {
            'code': 'NOT_FOUND',
            'message': 'Endpoint not found: /${request.url.path}',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    });

    return root;
  }

  // ---------------------------------------------------------------------------
  // CORS middleware
  // ---------------------------------------------------------------------------

  /// Permissive CORS for LAN-only use. No `Access-Control-Allow-Origin: *`
  /// on authenticated endpoints — we echo the request origin instead.
  static Middleware _corsMiddleware() {
    return (Handler innerHandler) {
      return (Request request) async {
        // Handle preflight.
        if (request.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders(request));
        }

        final response = await innerHandler(request);
        return response.change(headers: {
          ...response.headers,
          ..._corsHeaders(request),
        });
      };
    };
  }

  static Map<String, String> _corsHeaders(Request request) {
    final origin = request.headers['origin'] ?? '';
    return {
      'access-control-allow-origin': origin.isNotEmpty ? origin : 'null',
      'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'access-control-allow-headers':
          'Content-Type, Authorization, X-Session-Id',
      'access-control-max-age': '3600',
    };
  }
}
