import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Core Cryptographic Service implementing standard audited algorithms:
/// - Ed25519 (RFC 8032) for device master identity & digital signatures.
/// - X25519 (RFC 7748) for Diffie-Hellman ephemeral key exchange (PFS).
/// - ChaCha20-Poly1305 (RFC 8439) AEAD for authenticated payload encryption.
/// - SHA-256 (FIPS 180-4) for digests & payload fingerprinting.
/// - HMAC-SHA256 (RFC 2104) for Short Authentication String (SAS) derivation.
///
/// Strictly abides by the "NO CUSTOM CRYPTOGRAPHY" rule (docs/06_identity_and_security.md).
class CryptoService {
  final Ed25519 _ed25519 = Ed25519();
  final X25519 _x25519 = X25519();
  final Cipher _chacha20Poly1305 = Chacha20.poly1305Aead();
  final Sha256 _sha256 = Sha256();

  // --------------------------------------------------------------------------
  // ED25519 MASTER IDENTITY & DIGITAL SIGNATURES
  // --------------------------------------------------------------------------

  /// Generates a new master Ed25519 keypair for local device identity.
  Future<SimpleKeyPair> generateEd25519KeyPair() async {
    return await _ed25519.newKeyPair();
  }

  /// Exports Ed25519 keypair seed (32 bytes) for secure storage.
  Future<List<int>> extractEd25519Seed(SimpleKeyPair keyPair) async {
    final bytes = await keyPair.extractPrivateKeyBytes();
    return bytes;
  }

  /// Restores an Ed25519 keypair from a 32-byte private key seed.
  Future<SimpleKeyPair> restoreEd25519KeyPair(List<int> seed) async {
    return await _ed25519.newKeyPairFromSeed(seed);
  }

  /// Extracts the hex-encoded 64-character Ed25519 public key string (Node ID).
  Future<String> getEd25519PublicKeyHex(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return _bytesToHex(publicKey.bytes);
  }

  /// Signs a byte array message using the local device's Ed25519 private key.
  Future<String> signMessage(Uint8List message, SimpleKeyPair keyPair) async {
    final signature = await _ed25519.sign(
      message,
      keyPair: keyPair,
    );
    return _bytesToHex(signature.bytes);
  }

  /// Verifies an Ed25519 signature over a byte array message using the sender's public key hex.
  Future<bool> verifySignature({
    required Uint8List message,
    required String signatureHex,
    required String publicKeyHex,
  }) async {
    try {
      final signatureBytes = _hexToBytes(signatureHex);
      final publicKeyBytes = _hexToBytes(publicKeyHex);

      final signature = Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      );

      return await _ed25519.verify(
        message,
        signature: signature,
      );
    } catch (e) {
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // X25519 EPHEMERAL KEY EXCHANGE (ECDH)
  // --------------------------------------------------------------------------

  /// Generates an ephemeral X25519 keypair for session key negotiation.
  Future<SimpleKeyPair> generateX25519KeyPair() async {
    return await _x25519.newKeyPair();
  }

  /// Extracts the hex-encoded X25519 public key string.
  Future<String> getX25519PublicKeyHex(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return _bytesToHex(publicKey.bytes);
  }

  /// Performs Diffie-Hellman key exchange (X25519) to compute shared symmetric secret key.
  Future<SecretKey> computeSharedSecret({
    required SimpleKeyPair localX25519KeyPair,
    required String remoteX25519PublicKeyHex,
  }) async {
    final remotePublicKeyBytes = _hexToBytes(remoteX25519PublicKeyHex);
    final remotePublicKey = SimplePublicKey(
      remotePublicKeyBytes,
      type: KeyPairType.x25519,
    );

    return await _x25519.sharedSecretKey(
      keyPair: localX25519KeyPair,
      remotePublicKey: remotePublicKey,
    );
  }

  // --------------------------------------------------------------------------
  // CHACHA20-POLY1305 AEAD PAYLOAD ENCRYPTION & DECRYPTION
  // --------------------------------------------------------------------------

  /// Encrypts plaintext bytes using ChaCha20-Poly1305 AEAD with the derived shared secret.
  /// Returns Base64-encoded payload containing: Nonce (12B) + Ciphertext + MAC Tag (16B).
  Future<String> encryptPayload({
    required Uint8List plaintext,
    required SecretKey secretKey,
  }) async {
    final secretBox = await _chacha20Poly1305.encrypt(
      plaintext,
      secretKey: secretKey,
    );

    // Concatenate nonce (12B) + mac (16B) + ciphertext
    final combined = Uint8List(
      secretBox.nonce.length + secretBox.mac.bytes.length + secretBox.cipherText.length,
    );
    int offset = 0;

    combined.setAll(offset, secretBox.nonce);
    offset += secretBox.nonce.length;

    combined.setAll(offset, secretBox.mac.bytes);
    offset += secretBox.mac.bytes.length;

    combined.setAll(offset, secretBox.cipherText);

    return base64Encode(combined);
  }

  /// Decrypts a Base64-encoded ChaCha20-Poly1305 payload using the derived shared secret.
  /// Throws Exception if MAC tag verification fails or payload is tampered.
  Future<Uint8List> decryptPayload({
    required String base64Payload,
    required SecretKey secretKey,
  }) async {
    final combined = base64Decode(base64Payload);

    const nonceLength = 12; // ChaCha20-Poly1305 96-bit nonce
    const macLength = 16;   // Poly1305 128-bit MAC tag

    if (combined.length < nonceLength + macLength) {
      throw FormatException('INVALID_PAYLOAD: Encrypted payload bytes too short.');
    }

    final nonce = combined.sublist(0, nonceLength);
    final macBytes = combined.sublist(nonceLength, nonceLength + macLength);
    final cipherText = combined.sublist(nonceLength + macLength);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final decryptedBytes = await _chacha20Poly1305.decrypt(
      secretBox,
      secretKey: secretKey,
    );

    return Uint8List.fromList(decryptedBytes);
  }

  // --------------------------------------------------------------------------
  // DIGEST HASHING & SAS DERIVATION
  // --------------------------------------------------------------------------

  /// Computes hex-encoded SHA-256 hash digest of a byte array.
  Future<String> sha256Hex(Uint8List input) async {
    final digest = await _sha256.hash(input);
    return _bytesToHex(digest.bytes);
  }

  /// Computes 6-digit decimal Short Authentication String (SAS) for Out-of-Band pairing verification.
  /// Derivation Formula (spec/security.md):
  ///   SAS = First 6 decimal digits of (BigEndianUint64(HMAC-SHA256(shared_secret + nonces)) mod 1,000,000)
  Future<String> deriveSasCode({
    required SecretKey sharedSecret,
    required String localNonce,
    required String remoteNonce,
    required String sessionId,
  }) async {
    final secretKeyBytes = await sharedSecret.extractBytes();
    final hmac = Hmac.sha256();

    final inputData = utf8.encode('$localNonce$remoteNonce$sessionId' 'omnilink-sas-v1');
    final mac = await hmac.calculateMac(
      inputData,
      secretKey: SecretKey(secretKeyBytes),
    );

    final macBytes = mac.bytes;

    // Read first 8 bytes as BigEndian unsigned integer
    final byteData = ByteData.sublistView(Uint8List.fromList(macBytes));
    final value64 = byteData.getUint64(0, Endian.big);

    final code = (value64 % 1000000).toString().padLeft(6, '0');
    return '${code.substring(0, 3)}-${code.substring(3, 6)}'; // Formatted as XXX-XXX
  }

  // --------------------------------------------------------------------------
  // HEX CONVERSION UTILITIES
  // --------------------------------------------------------------------------

  static String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _hexToBytes(String hex) {
    hex = hex.replaceAll(' ', '');
    if (hex.length % 2 != 0) {
      throw FormatException('Invalid hex string length.');
    }
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
