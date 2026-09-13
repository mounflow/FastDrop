import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

/// Raised when an HTTP request body exceeds its protocol limit.
class RequestBodyTooLargeException implements Exception {
  const RequestBodyTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() => 'Request body exceeds $maxBytes bytes';
}

/// Reads at most [maxBytes] from [request].
///
/// The content length is checked first, then the streamed byte count is
/// enforced as well because clients are not required to send Content-Length.
Future<Uint8List> readBodyLimited(
  Request request, {
  required int maxBytes,
}) async {
  final declaredLength = int.tryParse(request.headers['content-length'] ?? '');
  if (declaredLength != null && declaredLength > maxBytes) {
    throw RequestBodyTooLargeException(maxBytes);
  }

  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in request.read()) {
    total += chunk.length;
    if (total > maxBytes) {
      throw RequestBodyTooLargeException(maxBytes);
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Reads a size-limited JSON object from [request].
Future<Map<String, dynamic>> readJsonObjectLimited(
  Request request, {
  required int maxBytes,
}) async {
  final bytes = await readBodyLimited(request, maxBytes: maxBytes);
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('JSON body must be an object');
  }
  return decoded;
}
