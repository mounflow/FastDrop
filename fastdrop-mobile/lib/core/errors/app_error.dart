/// A typed application error that maps to the FastDrop error envelope
/// `{error: {code, message, requestId, details}}`.
class AppError implements Exception {
  const AppError({
    required this.code,
    required this.message,
    this.statusCode,
    this.requestId,
    this.details,
  });

  /// FastDrop error code (e.g. `PAIR_TOKEN_EXPIRED`, `SESSION_NOT_FOUND`).
  final String code;

  /// Human-readable error message.
  final String message;

  /// HTTP status code, if this error originated from an HTTP response.
  final int? statusCode;

  /// Correlation ID from the backend.
  final String? requestId;

  /// Optional extra data.
  final Map<String, dynamic>? details;

  /// Deserialize from the FastDrop JSON error envelope.
  factory AppError.fromJson(Map<String, dynamic> json, {int? statusCode}) {
    final error = json['error'] as Map<String, dynamic>?;
    return AppError(
      code: (error?['code'] as String?) ?? 'UNKNOWN',
      message: (error?['message'] as String?) ?? 'Unknown error',
      statusCode: statusCode,
      requestId: (error?['requestId'] as String?) ?? json['requestId']?.toString(),
      details: (error?['details'] as Map<String, dynamic>?),
    );
  }

  @override
  String toString() {
    final buf = StringBuffer('AppError($code)');
    if (statusCode != null) buf.write(' [HTTP $statusCode]');
    buf.write(': $message');
    if (requestId != null) buf.write(' (requestId: $requestId)');
    return buf.toString();
  }

  Map<String, dynamic> toJson() {
    return {
      'error': {
        'code': code,
        'message': message,
        if (requestId != null) 'requestId': requestId,
        if (details != null) 'details': details,
      },
    };
  }
}

/// Known FastDrop error codes from the spec (§21).
class ErrorCodes {
  ErrorCodes._();

  // Pair token errors
  static const pairTokenExpired = 'PAIR_TOKEN_EXPIRED';
  static const pairTokenInvalid = 'PAIR_TOKEN_INVALID';
  static const pairTokenMaxAttempts = 'PAIR_TOKEN_MAX_ATTEMPTS';
  static const pairTokenAlreadyUsed = 'PAIR_TOKEN_ALREADY_USED';

  // Session errors
  static const sessionNotFound = 'SESSION_NOT_FOUND';
  static const sessionExpired = 'SESSION_EXPIRED';
  static const sessionInvalid = 'SESSION_INVALID';

  // Transfer errors
  static const fileHashMismatch = 'FILE_HASH_MISMATCH';
  static const insufficientStorage = 'INSUFFICIENT_STORAGE';
  static const fileNotFound = 'FILE_NOT_FOUND';
  static const transferCancelled = 'TRANSFER_CANCELLED';
  static const transferFailed = 'TRANSFER_FAILED';

  // Auth
  static const unauthorized = 'UNAUTHORIZED';
  static const forbidden = 'FORBIDDEN';

  // General
  static const invalidRequest = 'INVALID_REQUEST';
  static const internalError = 'INTERNAL_ERROR';
}
