import 'dart:convert';
import 'dart:typed_data';

/// Represents a cryptographically signed key bundle binding a peer's Ed25519 identity key
/// to their independent static X25519 encryption key and rotated X25519 Signed Pre-Key (SPK).
class SignedKeyBundle {
  final String protocolVersion;
  final String identityPublicKeyHex;
  final String staticX25519PublicKeyHex;
  final String signedPreKeyPublicKeyHex;
  final int timestamp;
  final String signature;

  const SignedKeyBundle({
    this.protocolVersion = '0.1',
    required this.identityPublicKeyHex,
    required this.staticX25519PublicKeyHex,
    required this.signedPreKeyPublicKeyHex,
    required this.timestamp,
    required this.signature,
  });

  /// Constructs the canonical string representation used for signature creation/verification.
  /// Format: v=0.1|id=$identity|static=$static|spk=$spk|ts=$timestamp
  String toCanonicalString() {
    return 'v=$protocolVersion|id=$identityPublicKeyHex|static=$staticX25519PublicKeyHex|spk=$signedPreKeyPublicKeyHex|ts=$timestamp';
  }

  /// Encodes canonical string to UTF-8 bytes.
  Uint8List toCanonicalBytes() {
    return Uint8List.fromList(utf8.encode(toCanonicalString()));
  }

  Map<String, dynamic> toMap() {
    return {
      'protocol_version': protocolVersion,
      'identity_public_key': identityPublicKeyHex,
      'static_x25519_public_key': staticX25519PublicKeyHex,
      'signed_prekey_public_key': signedPreKeyPublicKeyHex,
      'timestamp': timestamp,
      'signature': signature,
    };
  }

  factory SignedKeyBundle.fromMap(Map<String, dynamic> map) {
    return SignedKeyBundle(
      protocolVersion: (map['protocol_version'] ?? '0.1') as String,
      identityPublicKeyHex: map['identity_public_key'] as String,
      staticX25519PublicKeyHex: map['static_x25519_public_key'] as String,
      signedPreKeyPublicKeyHex: map['signed_prekey_public_key'] as String,
      timestamp: map['timestamp'] as int,
      signature: map['signature'] as String,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory SignedKeyBundle.fromJson(String source) =>
      SignedKeyBundle.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
