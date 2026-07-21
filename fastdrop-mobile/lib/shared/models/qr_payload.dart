import 'dart:convert';

/// The QR code payload scanned by the phone to discover and pair with the PC.
///
/// Matches the Go backend's QR JSON envelope (§7 of the spec). Must never
/// contain permanent passwords, session tokens, file paths, or PII.
class QrPayload {
  const QrPayload({
    required this.version,
    required this.protocol,
    required this.host,
    required this.port,
    required this.pairId,
    required this.token,
    required this.expiresAt,
    this.serverName,
    this.altHosts = const [],
  });

  /// Protocol version (current: 1).
  final int version;

  /// Always `"fastdrop"`.
  final String protocol;

  /// Server IP address (IPv4 dotted-decimal).
  final String host;

  /// Alternate server IPs (e.g. when PC is also a mobile hotspot).
  /// The phone tries `host` first, then each altHost until one works.
  final List<String> altHosts;

  /// Server port (default: 9527).
  final int port;

  /// Opaque pair-id for the pairing handshake.
  final String pairId;

  /// 32-byte random token, Base64URL-encoded.
  final String token;

  /// Unix timestamp (seconds) when the token expires.
  final int expiresAt;

  /// Human-readable PC name (optional).
  final String? serverName;

  /// Return a copy with the primary host replaced (used after probing
  /// reveals that an altHost is the reachable address).
  QrPayload copyWith({String? workingHost}) {
    return QrPayload(
      version: version,
      protocol: protocol,
      host: workingHost ?? host,
      port: port,
      pairId: pairId,
      token: token,
      expiresAt: expiresAt,
      serverName: serverName,
      altHosts: altHosts,
    );
  }

  /// Construct the base URL for API calls (e.g. `http://192.168.1.5:9527`).
  String get baseUrl => 'http://$host:$port';

  /// All candidate base URLs (primary first, then altHosts).
  /// Used by the phone to probe reachability when the primary fails.
  List<String> get candidateBaseUrls => [
    baseUrl,
    for (final ip in altHosts) 'http://$ip:$port',
  ];

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  factory QrPayload.fromJson(Map<String, dynamic> json) {
    return QrPayload(
      version: json['version'] as int,
      protocol: json['protocol'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      pairId: json['pairId'] as String,
      token: json['token'] as String,
      expiresAt: json['expiresAt'] as int,
      serverName: json['serverName'] as String?,
      altHosts: (json['altHosts'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'protocol': protocol,
      'host': host,
      'port': port,
      'pairId': pairId,
      'token': token,
      'expiresAt': expiresAt,
      if (serverName != null) 'serverName': serverName,
      'altHosts': altHosts,
    };
  }

  /// Parse a QR code scan result string into a [QrPayload].
  ///
  /// Returns `null` if the string is not valid JSON or does not contain
  /// the required fields.
  static QrPayload? tryParse(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return QrPayload.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  bool get isExpired {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expMs = expiresAt * 1000;
    return nowMs > expMs;
  }
}
