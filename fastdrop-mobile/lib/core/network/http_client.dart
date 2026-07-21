import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fastdrop_mobile/core/errors/app_error.dart';

/// Wraps [http.Client] with FastDrop session-header injection and error
/// handling that understands the FastDrop error envelope.
class FastDropHttpClient {
  FastDropHttpClient({
    http.Client? client,
    this.baseUrl,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  String? _sessionId;
  String? _accessToken;
  String? baseUrl;

  /// Default timeout for all HTTP requests.
  final Duration timeout;

  // ---------------------------------------------------------------------------
  // Session management
  // ---------------------------------------------------------------------------

  /// Set or update the session credentials injected into every request.
  void setSession(String sessionId, String accessToken) {
    _sessionId = sessionId;
    _accessToken = accessToken;
  }

  /// Clear stored session credentials.
  void clearSession() {
    _sessionId = null;
    _accessToken = null;
  }

  bool get hasSession => _sessionId != null && _accessToken != null;

  // ---------------------------------------------------------------------------
  // HTTP helpers
  // ---------------------------------------------------------------------------

  Uri _resolve(String path) {
    if (baseUrl != null) {
      return Uri.parse('$baseUrl$path');
    }
    return Uri.parse(path);
  }

  Map<String, String> _headers([Map<String, String>? extra]) {
    final headers = <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json',
    };
    if (_sessionId != null) {
      headers['X-Session-Id'] = _sessionId!;
    }
    if (_accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    if (extra != null) {
      headers.addAll(extra);
    }
    return headers;
  }

  /// Parse the FastDrop error envelope `{error: {code, message}}`.
  Never _throwApiError(int statusCode, String body, {String requestId = ''}) {
    String code = 'UNKNOWN';
    String message = body;

    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      if (decoded.containsKey('error')) {
        final err = decoded['error'] as Map<String, dynamic>;
        code = (err['code'] as String?) ?? code;
        message = (err['message'] as String?) ?? message;
      }
    } catch (_) {
      // If the body is not valid JSON, use it verbatim.
    }

    throw AppError(
      code: code,
      message: message,
      statusCode: statusCode,
      requestId: requestId,
    );
  }

  Future<http.Response> _handle(http.Response response) async {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    _throwApiError(
      response.statusCode,
      response.body,
      requestId: _requestIdFromResponse(response),
    );
  }

  String _requestIdFromResponse(http.Response response) {
    // The backend may return requestId in a header or in the body.
    try {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      if (decoded.containsKey('requestId')) {
        return decoded['requestId'].toString();
      }
    } catch (_) {}
    return '';
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<http.Response> get(
    String path, {
    Map<String, String>? queryParams,
    Map<String, String>? headers,
  }) async {
    var uri = _resolve(path);
    if (queryParams != null && queryParams.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParams);
    }
    final response = await _client.get(uri, headers: _headers(headers)).timeout(timeout);
    return _handle(response);
  }

  Future<http.Response> post(
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final uri = _resolve(path);
    final response = await _client.post(
      uri,
      headers: _headers(headers),
      body: body != null ? jsonEncode(body) : null,
    ).timeout(timeout);
    return _handle(response);
  }

  Future<http.Response> put(
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final uri = _resolve(path);
    final response = await _client.put(
      uri,
      headers: _headers(headers),
      body: body != null ? jsonEncode(body) : null,
    ).timeout(timeout);
    return _handle(response);
  }

  Future<http.Response> delete(
    String path, {
    Map<String, String>? headers,
  }) async {
    final uri = _resolve(path);
    final response = await _client.delete(uri, headers: _headers(headers)).timeout(timeout);
    return _handle(response);
  }

  Future<http.Response> head(
    String path, {
    Map<String, String>? headers,
  }) async {
    final uri = _resolve(path);
    final response = await _client.head(uri, headers: _headers(headers)).timeout(timeout);
    return _handle(response);
  }

  /// Upload raw bytes (e.g. a chunk) with the given [contentType].
  Future<http.Response> putBytes(
    String path,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    Map<String, String>? headers,
  }) async {
    final uri = _resolve(path);
    final allHeaders = _headers(headers);
    allHeaders[HttpHeaders.contentTypeHeader] = contentType;
    final response = await _client.put(uri, headers: allHeaders, body: bytes).timeout(timeout);
    return _handle(response);
  }

  void dispose() {
    _client.close();
  }
}
