import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Stateless helpers for token generation and hashing, matching the Go
/// backend's `crypto/rand` + SHA-256 approach.
class TokenManager {
  TokenManager._();

  /// Generate [length] cryptographically secure random bytes.
  static Uint8List secureRandomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  /// Generate a 32-byte random token, Base64URL-encoded (no padding).
  ///
  /// This matches the Go backend's pair-token generation:
  /// 32 bytes from `crypto/rand`, Base64URL-encoded.
  static String generateToken() {
    final bytes = secureRandomBytes(32);
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Compute the SHA-256 hash of [input] and return the hex digest.
  ///
  /// Used for client-side hashing of tokens before persisting
  /// or comparing with backend-stored hashes.
  static String sha256Hash(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Compute the SHA-256 hash of raw [bytes].
  static String sha256HashBytes(Uint8List bytes) {
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
