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
      message: (error?['message'] as String?) ?? '未知错误',
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

/// 错误码 → 面向用户的中文说明。
///
/// 覆盖 spec §21 的封闭集合，外加手机端 / PC 端**实际会发出**的码
/// （`PAIR_TOKEN_MAX_ATTEMPTS`、`PAIR_REQUEST_*`、`SESSION_NOT_FOUND`、
/// `SESSION_DISCONNECTED`、`TRANSFER_FAILED`、`TRANSFER_NOT_ACTIVE`、
/// `UNAUTHORIZED`、`FORBIDDEN`、`NOT_FOUND`、`UNKNOWN`）。
///
/// 常量字符串本身是跨端协议的一部分，**不要改**；这里只做显示层映射
/// （`transfer_screen` 的错误行、历史记录的错误码/错误信息列）。
///
/// 映射不到时**原样返回 [code]**：错误码本身是排查线索，既不能丢信息，
/// 也不能显示成空白或笼统的"未知错误"。
String humanizeErrorCode(String code) => _errorCodeMessages[code] ?? code;

const Map<String, String> _errorCodeMessages = {
  // 通用
  'INVALID_REQUEST': '请求参数无效',
  'UNSUPPORTED_PROTOCOL_VERSION': '协议版本不受支持',
  'INTERNAL_ERROR': '内部错误',
  'UNKNOWN': '未知错误',
  'NOT_FOUND': '请求的资源不存在',
  'UNAUTHORIZED': '未授权',
  'FORBIDDEN': '没有操作权限',
  'TOO_MANY_REQUESTS': '请求过于频繁，请稍后重试',
  'PERMISSION_DENIED': '权限不足',

  // 配对
  'PAIR_TOKEN_INVALID': '配对二维码无效',
  'PAIR_TOKEN_EXPIRED': '配对二维码已过期',
  'PAIR_TOKEN_ALREADY_USED': '配对二维码已被使用',
  'PAIR_TOKEN_MAX_ATTEMPTS': '配对尝试次数过多，请重新生成二维码',
  'PAIR_REQUEST_REJECTED': '配对请求已被拒绝',
  'PAIR_REQUEST_EXPIRED': '配对请求已超时',

  // 会话
  'SESSION_INVALID': '会话无效，请重新配对',
  'SESSION_EXPIRED': '会话已过期，请重新配对',
  'SESSION_REVOKED': '会话已被对方撤销，请重新配对',
  'SESSION_NOT_FOUND': '会话不存在，请重新配对',
  'SESSION_DISCONNECTED': '与对方的连接已断开',

  // 文件
  'FILE_NOT_FOUND': '文件不存在',
  'FILE_NAME_INVALID': '文件名不合法',
  'FILE_SIZE_MISMATCH': '文件大小不一致',
  'FILE_HASH_MISMATCH': '文件校验失败（SHA-256 不一致）',
  'CHUNK_INDEX_INVALID': '分块序号无效',
  'CHUNK_HASH_MISMATCH': '分块校验失败（SHA-256 不一致）',
  'INSUFFICIENT_STORAGE': '接收端存储空间不足',

  // 传输
  'TRANSFER_NOT_FOUND': '传输任务不存在',
  'TRANSFER_CANCELLED': '传输已取消',
  'TRANSFER_ALREADY_COMPLETED': '传输已经完成',
  'TRANSFER_NOT_ACTIVE': '当前传输状态不允许该操作',
  'TRANSFER_FAILED': '传输失败',
};
