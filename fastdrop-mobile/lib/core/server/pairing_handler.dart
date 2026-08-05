import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:fastdrop_mobile/core/security/token.dart';
import 'package:fastdrop_mobile/core/server/session_manager.dart';
import 'package:fastdrop_mobile/shared/models/device_info.dart';
import 'package:fastdrop_mobile/shared/models/pair_request.dart';
import 'package:fastdrop_mobile/shared/models/qr_payload.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// Server-side pair request state.
class ServerPairRequest {
  ServerPairRequest({
    required this.requestId,
    required this.device,
    required this.createdAt,
    this.viaDiscover = false,
  });

  final String requestId;
  final DeviceInfo device;
  final DateTime createdAt;
  final bool viaDiscover;

  /// `waiting_confirmation` | `accepted` | `rejected` | `expired`
  String status = 'waiting_confirmation';

  /// Populated on accept.
  SessionInfo? sessionInfo;
  ServerInfo? serverInfo;

  static const confirmTimeout = Duration(seconds: 30);

  bool get isExpired =>
      status == 'waiting_confirmation' &&
      DateTime.now().isAfter(createdAt.add(confirmTimeout));

  Map<String, dynamic> toJson() {
    return {
      'requestId': requestId,
      'deviceName': device.deviceName,
      'platform': device.platform,
      'status': status,
      'viaDiscover': viaDiscover,
    };
  }
}

/// Callback invoked when a new pair request arrives, so the UI layer can
/// show a confirmation dialog.
typedef PairRequestCallback = void Function(ServerPairRequest request);

/// Handles the server side of the pairing handshake.
///
/// Generates QR payloads, validates pair tokens, manages confirm/reject
/// flow with 30-second timeout, and creates sessions on acceptance.
class PairingHandler {
  PairingHandler({
    required SessionManager sessionManager,
    required DeviceInfo localDevice,
    bool requireConfirmation = false,
    this.onPairRequest,
  })  : _sessionManager = sessionManager,
        _localDevice = localDevice,
        _requireConfirmation = requireConfirmation;

  final SessionManager _sessionManager;
  final DeviceInfo _localDevice;
  bool _requireConfirmation;

  bool get requireConfirmation => _requireConfirmation;

  set requireConfirmation(bool value) {
    _requireConfirmation = value;
    if (!value) {
      for (final request in _requests.values.toList()) {
        acceptRequest(request.requestId);
      }
    }
  }

  /// Called when a new pair request needs user confirmation.
  PairRequestCallback? onPairRequest;

  // -- QR token state ---------------------------------------------------------

  String? _currentPairId;
  String? _currentTokenHash;
  DateTime? _tokenExpiresAt;
  bool _tokenUsed = false;
  int _tokenFailCount = 0;
  static const _tokenTtl = Duration(seconds: 60);
  static const _maxFailures = 5;

  // -- Pending pair requests ---------------------------------------------------

  final HashMap<String, ServerPairRequest> _requests = HashMap();

  /// Callback for when a request is accepted/rejected so WS can notify.
  void Function(String requestId, String status)? onRequestResolved;

  // ---------------------------------------------------------------------------
  // QR payload generation
  // ---------------------------------------------------------------------------

  /// Generate a fresh QR payload for another device to scan.
  Future<QrPayload> generateQrPayload() async {
    _currentPairId = TokenManager.generateToken();
    final rawToken = TokenManager.generateToken();
    _currentTokenHash = TokenManager.sha256Hash(rawToken);
    _tokenExpiresAt = DateTime.now().add(_tokenTtl);
    _tokenUsed = false;
    _tokenFailCount = 0;

    final ip = await _getLocalIp();
    final expiresAtSec = _tokenExpiresAt!.millisecondsSinceEpoch ~/ 1000;

    return QrPayload(
      version: 1,
      protocol: 'fastdrop',
      host: ip,
      port: 9527,
      pairId: _currentPairId!,
      token: rawToken,
      expiresAt: expiresAtSec,
      serverName: _localDevice.deviceName,
    );
  }

  /// The current QR payload JSON (for GET /api/v1/pair/qr).
  Map<String, dynamic>? currentQrJson;

  static Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  // ---------------------------------------------------------------------------
  // Pair token validation
  // ---------------------------------------------------------------------------

  /// Validate the pair token from a QR-based pair request.
  /// Returns null on success, or an error code string on failure.
  String? _validatePairToken(String pairId, String token) {
    if (_currentPairId == null || _currentPairId != pairId) {
      return 'PAIR_TOKEN_INVALID';
    }
    if (_tokenExpiresAt == null || DateTime.now().isAfter(_tokenExpiresAt!)) {
      return 'PAIR_TOKEN_EXPIRED';
    }
    if (_tokenUsed) {
      return 'PAIR_TOKEN_ALREADY_USED';
    }
    if (_tokenFailCount >= _maxFailures) {
      return 'PAIR_TOKEN_MAX_ATTEMPTS';
    }
    if (TokenManager.sha256Hash(token) != _currentTokenHash) {
      _tokenFailCount++;
      if (_tokenFailCount >= _maxFailures) {
        // Invalidate the token entirely.
        _currentPairId = null;
        _currentTokenHash = null;
      }
      return 'PAIR_TOKEN_INVALID';
    }
    // Success — mark as used (single-use).
    _tokenUsed = true;
    return null;
  }

  // ---------------------------------------------------------------------------
  // Request lifecycle
  // ---------------------------------------------------------------------------

  /// Create a pair request (from QR or discover flow).
  ServerPairRequest _createRequest(DeviceInfo device,
      {bool viaDiscover = false}) {
    final requestId = TokenManager.generateToken();
    final request = ServerPairRequest(
      requestId: requestId,
      device: device,
      createdAt: DateTime.now(),
      viaDiscover: viaDiscover,
    );
    _requests[requestId] = request;

    if (_requireConfirmation) {
      onPairRequest?.call(request);
    } else {
      acceptRequest(requestId);
    }

    // Auto-expire after 30s.
    Timer(ServerPairRequest.confirmTimeout, () {
      final r = _requests[requestId];
      if (r != null && r.status == 'waiting_confirmation') {
        r.status = 'expired';
        onRequestResolved?.call(requestId, 'expired');
      }
    });

    return request;
  }

  /// Accept a pending pair request — creates a session.
  void acceptRequest(String requestId) {
    final request = _requests[requestId];
    if (request == null || request.status != 'waiting_confirmation') return;

    final session = _sessionManager.createSession(
      deviceId: request.device.deviceId,
      deviceName: request.device.deviceName,
      platform: request.device.platform,
    );

    request.status = 'accepted';
    request.sessionInfo = SessionInfo(
      sessionId: session.sessionId,
      accessToken: session.accessToken,
      expiresIn: SessionManager.sessionTtl.inSeconds,
    );
    request.serverInfo = ServerInfo(
      deviceId: _localDevice.deviceId,
      deviceName: _localDevice.deviceName,
      platform: _localDevice.platform,
      appVersion: _localDevice.appVersion,
    );

    onRequestResolved?.call(requestId, 'accepted');
  }

  /// Reject a pending pair request.
  void rejectRequest(String requestId) {
    final request = _requests[requestId];
    if (request == null || request.status != 'waiting_confirmation') return;
    request.status = 'rejected';
    onRequestResolved?.call(requestId, 'rejected');
  }

  // ---------------------------------------------------------------------------
  // Route handlers
  // ---------------------------------------------------------------------------

  /// GET /api/v1/pair/qr — return the current QR payload.
  Future<Response> handleGetQr(Request request) async {
    final payload = await generateQrPayload();
    currentQrJson = payload.toJson();
    return _json(200, payload.toJson());
  }

  /// POST /api/v1/pair/request — QR-based pair request.
  Future<Response> handlePairRequest(Request request) async {
    final body = await _readJson(request);
    if (body == null) {
      return _error(400, 'INVALID_REQUEST', 'Invalid JSON body');
    }

    final pairId = body['pairId'] as String?;
    final token = body['token'] as String?;
    final deviceJson = body['device'] as Map<String, dynamic>?;

    if (pairId == null || token == null || deviceJson == null) {
      return _error(400, 'INVALID_REQUEST', 'Missing pairId, token, or device');
    }

    // Validate pair token.
    final tokenError = _validatePairToken(pairId, token);
    if (tokenError != null) {
      return _error(403, tokenError, 'Pair token validation failed');
    }

    final device = DeviceInfo.fromJson(deviceJson);
    final pairRequest = _createRequest(device);

    return _json(
        201,
        PairRequestResponse(
          requestId: pairRequest.requestId,
          status: pairRequest.status,
          expiresIn: ServerPairRequest.confirmTimeout.inSeconds,
        ).toJson());
  }

  /// POST /api/v1/pair/discover — mDNS-based pair request (no token needed).
  Future<Response> handlePairDiscover(Request request) async {
    final body = await _readJson(request);
    if (body == null) {
      return _error(400, 'INVALID_REQUEST', 'Invalid JSON body');
    }

    final deviceJson = body['device'] as Map<String, dynamic>?;
    if (deviceJson == null) {
      return _error(400, 'INVALID_REQUEST', 'Missing device');
    }

    final device = DeviceInfo.fromJson(deviceJson);
    final pairRequest = _createRequest(device, viaDiscover: true);

    return _json(
        201,
        PairRequestResponse(
          requestId: pairRequest.requestId,
          status: pairRequest.status,
          expiresIn: ServerPairRequest.confirmTimeout.inSeconds,
        ).toJson());
  }

  /// GET /api/v1/pair/requests/<requestId> — poll pair request status.
  Response handlePollRequest(Request request, String requestId) {
    final pairRequest = _requests[requestId];
    if (pairRequest == null) {
      return _error(404, 'PAIR_TOKEN_INVALID', 'Pair request not found');
    }

    // Check for auto-expiry.
    if (pairRequest.isExpired) {
      pairRequest.status = 'expired';
    }

    if (pairRequest.status == 'accepted') {
      return _json(
          200,
          PairAccepted(
            status: 'accepted',
            session: pairRequest.sessionInfo!,
            server: pairRequest.serverInfo!,
          ).toJson());
    }

    return _json(200, {
      'status': pairRequest.status,
      if (pairRequest.status == 'rejected')
        'reason': 'User rejected the pairing request',
      if (pairRequest.status == 'expired')
        'reason': 'Pairing request timed out',
    });
  }

  /// Build the shelf Router for pair endpoints.
  Router get router {
    final r = Router();
    r.get('/api/v1/pair/qr', handleGetQr);
    r.post('/api/v1/pair/request', handlePairRequest);
    r.post('/api/v1/pair/discover', handlePairDiscover);
    r.get('/api/v1/pair/requests/<requestId>', handlePollRequest);
    return r;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static Future<Map<String, dynamic>?> _readJson(Request request) async {
    try {
      final raw = await request.readAsString();
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Response _json(int status, Map<String, dynamic> body) {
    return Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
  }

  static Response _error(int status, String code, String message) {
    return Response(
      status,
      body: jsonEncode({
        'error': {'code': code, 'message': message},
      }),
      headers: {'content-type': 'application/json'},
    );
  }
}
