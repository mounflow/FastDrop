import 'package:fastdrop_mobile/shared/models/device_info.dart';

/// Models for the pairing handshake between phone and PC.
///
/// The flow: phone scans QR -> sends pair request -> polls status ->
/// receives session + server info on acceptance.
///
/// All JSON keys match the Go backend spec exactly.

// ---------------------------------------------------------------------------
// POST /api/v1/pair/request - Request body
// ---------------------------------------------------------------------------

/// Request body sent by the phone to initiate pairing.
///
/// ```json
/// {
///   "pairId": "...",
///   "token": "...",
///   "device": { "deviceId": "...", "deviceName": "...", "platform": "android", "appVersion": "0.1.0" }
/// }
/// ```
class PairRequestBody {
  const PairRequestBody({
    required this.pairId,
    required this.token,
    required this.device,
  });

  final String pairId;
  final String token;
  final DeviceInfo device;

  Map<String, dynamic> toJson() => {
        'pairId': pairId,
        'token': token,
        'device': device.toJson(),
      };
}

// ---------------------------------------------------------------------------
// POST /api/v1/pair/request - Response
// ---------------------------------------------------------------------------

/// Initial response after submitting a pair request.
///
/// ```json
/// { "requestId": "...", "status": "waiting_confirmation", "expiresIn": 30 }
/// ```
class PairRequestResponse {
  const PairRequestResponse({
    required this.requestId,
    required this.status,
    required this.expiresIn,
  });

  /// Unique request identifier used for status polling.
  final String requestId;

  /// Current status: `waiting_confirmation`, `accepted`, `rejected`, `expired`.
  final String status;

  /// Seconds until the pair request expires.
  final int expiresIn;

  factory PairRequestResponse.fromJson(Map<String, dynamic> json) {
    return PairRequestResponse(
      requestId: json['requestId'] as String,
      status: json['status'] as String,
      expiresIn: json['expiresIn'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'status': status,
        'expiresIn': expiresIn,
      };
}

// ---------------------------------------------------------------------------
// GET /api/v1/pair/requests/{requestId} - Accepted response
// ---------------------------------------------------------------------------

/// Session info returned when pairing is accepted.
///
/// ```json
/// { "sessionId": "...", "accessToken": "...", "expiresIn": 43200, "websocketUrl": "ws://..." }
/// ```
class SessionInfo {
  const SessionInfo({
    required this.sessionId,
    required this.accessToken,
    required this.expiresIn,
    this.websocketUrl,
  });

  final String sessionId;
  final String accessToken;

  /// Session TTL in seconds (12 hours = 43200).
  final int expiresIn;

  /// WebSocket URL provided by the server (optional, derived from baseUrl if absent).
  final String? websocketUrl;

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      sessionId: json['sessionId'] as String,
      accessToken: json['accessToken'] as String,
      expiresIn: json['expiresIn'] as int,
      websocketUrl: json['websocketUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'accessToken': accessToken,
        'expiresIn': expiresIn,
        if (websocketUrl != null) 'websocketUrl': websocketUrl,
      };
}

// ---------------------------------------------------------------------------
// Server info (returned in accepted pair response)
// ---------------------------------------------------------------------------

/// Information about the paired server.
///
/// ```json
/// { "deviceId": "...", "deviceName": "Fang-PC", "platform": "windows" }
/// ```
class ServerInfo {
  const ServerInfo({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    this.appVersion,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String? appVersion;

  factory ServerInfo.fromJson(Map<String, dynamic> json) {
    return ServerInfo(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      platform: json['platform'] as String,
      appVersion: json['appVersion'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': platform,
        if (appVersion != null) 'appVersion': appVersion,
      };
}

// ---------------------------------------------------------------------------
// GET /api/v1/pair/requests/{requestId} - Full accepted response
// ---------------------------------------------------------------------------

/// Full response when the pair request is accepted.
///
/// ```json
/// { "status": "accepted", "session": {...}, "server": {...} }
/// ```
class PairAccepted {
  const PairAccepted({
    required this.status,
    required this.session,
    required this.server,
  });

  final String status;
  final SessionInfo session;
  final ServerInfo server;

  factory PairAccepted.fromJson(Map<String, dynamic> json) {
    return PairAccepted(
      status: json['status'] as String,
      session: SessionInfo.fromJson(json['session'] as Map<String, dynamic>),
      server: ServerInfo.fromJson(json['server'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() => {
        'status': status,
        'session': session.toJson(),
        'server': server.toJson(),
      };
}

// ---------------------------------------------------------------------------
// Poll response union — wraps all possible statuses
// ---------------------------------------------------------------------------

/// Represents the response from polling GET /api/v1/pair/requests/{requestId}.
///
/// Can be one of: accepted, rejected, expired, or still waiting_confirmation.
class PairPollResponse {
  final String status;
  final SessionInfo? session;
  final ServerInfo? server;
  final String? reason;

  const PairPollResponse({
    required this.status,
    this.session,
    this.server,
    this.reason,
  });

  bool get isAccepted => status == 'accepted';
  bool get isRejected => status == 'rejected';
  bool get isExpired => status == 'expired';
  bool get isWaiting => status == 'waiting_confirmation';

  factory PairPollResponse.fromJson(Map<String, dynamic> json) {
    return PairPollResponse(
      status: json['status'] as String,
      session: json['session'] != null
          ? SessionInfo.fromJson(json['session'] as Map<String, dynamic>)
          : null,
      server: json['server'] != null
          ? ServerInfo.fromJson(json['server'] as Map<String, dynamic>)
          : null,
      reason: json['reason'] as String?,
    );
  }
}
