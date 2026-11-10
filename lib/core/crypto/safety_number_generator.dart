import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;

/// Computes stable, human-comparable 60-digit numeric safety numbers
/// for Out-of-Band peer identity verification and MITM defense.
class SafetyNumberGenerator {
  /// Computes a 60-digit formatted safety number string (12 groups of 5 digits).
  static String generateSafetyNumber({
    required String localPublicKeyHex,
    required String remotePublicKeyHex,
  }) {
    final sortedKeys = [
      localPublicKeyHex.toLowerCase().trim(),
      remotePublicKeyHex.toLowerCase().trim(),
    ]..sort();

    final canonicalString = '${sortedKeys[0]}:${sortedKeys[1]}:omnilink-safety-v1';
    final bytes = utf8.encode(canonicalString);

    var digest = crypto.sha256.convert(bytes).bytes;
    for (int i = 0; i < 3; i++) {
      digest = crypto.sha256.convert(digest).bytes;
    }

    final byteData = ByteData.sublistView(Uint8List.fromList(digest));
    final groups = <String>[];

    for (int i = 0; i < 12; i++) {
      final offset = (i * 2) % (digest.length - 2);
      final value = byteData.getUint16(offset, Endian.big);
      final chunk = (value % 100000).toString().padLeft(5, '0');
      groups.add(chunk);
    }

    return groups.join(' ');
  }

  /// Computes a concise 16-character hex fingerprint of a public key.
  static String computeFingerprint(String publicKeyHex) {
    final bytes = utf8.encode(publicKeyHex.toLowerCase().trim());
    final digest = crypto.sha256.convert(bytes);
    final hex = digest.toString();
    return hex.substring(0, 16).toUpperCase();
  }
}
