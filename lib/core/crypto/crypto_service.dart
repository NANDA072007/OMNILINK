import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

import 'crypto_tasks.dart';
import 'crypto_worker_pool.dart';
import '../models/signed_key_bundle.dart';

/// Core Cryptographic Service implementing standard audited algorithms:
/// - Ed25519 (RFC 8032) for device master identity & digital signatures.
/// - X25519 (RFC 7748) for Diffie-Hellman ephemeral key exchange (PFS).
/// - ChaCha20-Poly1305 (RFC 8439) AEAD for authenticated payload encryption.
/// - SHA-256 (FIPS 180-4) for digests & payload fingerprinting.
/// - HMAC-SHA256 (RFC 2104) for Short Authentication String (SAS) derivation.
///
/// Offloads heavy cryptographic operations to a persistent [CryptoWorkerPool]
/// with fallback to short-lived background Dart Isolates via [Isolate.run].
class CryptoService {
  final Ed25519 _ed25519 = Ed25519();
  final X25519 _x25519 = X25519();

  /// Persistent worker isolate pool shared instance
  final CryptoWorkerPool _workerPool;

  CryptoService({CryptoWorkerPool? workerPool})
      : _workerPool = workerPool ?? CryptoWorkerPool();

  CryptoWorkerPool get workerPool => _workerPool;

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

  /// Signs a byte array message using the local device's Ed25519 private key in worker isolate pool.
  Future<String> signMessage(Uint8List message, SimpleKeyPair keyPair) async {
    final seed = Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    try {
      return await _workerPool.execute<String>(
        taskType: CryptoTaskType.sign,
        params: {'message': message, 'seed': seed},
      );
    } catch (_) {
      return await Isolate.run(() => _signMessageSync(message, seed));
    }
  }

  static Future<String> _signMessageSync(Uint8List message, Uint8List seed) async {
    final ed25519 = Ed25519();
    final keyPair = await ed25519.newKeyPairFromSeed(seed);
    final signature = await ed25519.sign(message, keyPair: keyPair);
    return _bytesToHex(signature.bytes);
  }

  /// Verifies an Ed25519 signature over a byte array message in worker isolate pool.
  Future<bool> verifySignature({
    required Uint8List message,
    required String signatureHex,
    required String publicKeyHex,
  }) async {
    try {
      return await _workerPool.execute<bool>(
        taskType: CryptoTaskType.verify,
        params: {
          'message': message,
          'signatureHex': signatureHex,
          'publicKeyHex': publicKeyHex,
        },
      );
    } catch (_) {
      return await Isolate.run(
        () => _verifySignatureSync(message, signatureHex, publicKeyHex),
      );
    }
  }

  static Future<bool> _verifySignatureSync(
    Uint8List message,
    String signatureHex,
    String publicKeyHex,
  ) async {
    try {
      final ed25519 = Ed25519();
      final signatureBytes = _hexToBytes(signatureHex);
      final publicKeyBytes = _hexToBytes(publicKeyHex);

      final signature = Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      );

      return await ed25519.verify(message, signature: signature);
    } catch (e) {
      return false;
    }
  }

  /// Creates a signed key bundle binding identity key to static and pre-key X25519 keys.
  Future<SignedKeyBundle> createSignedKeyBundle({
    required SimpleKeyPair masterEd25519KeyPair,
    required String staticX25519PublicKeyHex,
    required String signedPreKeyPublicKeyHex,
    int? timestamp,
  }) async {
    final identityPublicKeyHex =
        await getEd25519PublicKeyHex(masterEd25519KeyPair);
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch;

    final unsignedBundle = SignedKeyBundle(
      identityPublicKeyHex: identityPublicKeyHex,
      staticX25519PublicKeyHex: staticX25519PublicKeyHex,
      signedPreKeyPublicKeyHex: signedPreKeyPublicKeyHex,
      timestamp: ts,
      signature: '',
    );

    final signatureHex = await signMessage(
      unsignedBundle.toCanonicalBytes(),
      masterEd25519KeyPair,
    );

    return SignedKeyBundle(
      identityPublicKeyHex: identityPublicKeyHex,
      staticX25519PublicKeyHex: staticX25519PublicKeyHex,
      signedPreKeyPublicKeyHex: signedPreKeyPublicKeyHex,
      timestamp: ts,
      signature: signatureHex,
    );
  }

  /// Verifies the cryptographic binding of a SignedKeyBundle using the bundle's Ed25519 identity key.
  Future<bool> verifySignedKeyBundle(SignedKeyBundle bundle) async {
    // Validate hex string lengths (Ed25519/X25519 public keys are 32 bytes -> 64 hex chars)
    if (bundle.identityPublicKeyHex.length != 64 ||
        bundle.staticX25519PublicKeyHex.length != 64 ||
        bundle.signedPreKeyPublicKeyHex.length != 64) {
      return false;
    }

    if (bundle.signature.isEmpty || bundle.signature.length != 128) {
      return false;
    }

    final canonicalBytes = bundle.toCanonicalBytes();
    return await verifySignature(
      message: canonicalBytes,
      signatureHex: bundle.signature,
      publicKeyHex: bundle.identityPublicKeyHex,
    );
  }

  // --------------------------------------------------------------------------
  // X25519 EPHEMERAL KEY EXCHANGE (ECDH)
  // --------------------------------------------------------------------------

  /// Exports X25519 keypair seed (32 bytes) for secure storage.
  Future<List<int>> extractX25519Seed(SimpleKeyPair keyPair) async {
    final bytes = await keyPair.extractPrivateKeyBytes();
    return bytes;
  }

  /// Restores an X25519 keypair from a 32-byte private key seed.
  Future<SimpleKeyPair> restoreX25519KeyPair(List<int> seed) async {
    return await _x25519.newKeyPairFromSeed(seed);
  }

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

  /// Computes Dual-ECDH shared secret and derives 32-byte message key for Sender Alice.
  Future<SecretKey> deriveSenderMessageKey({
    required SimpleKeyPair ephemeralKeyPair,
    required SimpleKeyPair staticX25519KeyPair,
    required String aliceEd25519PublicKeyHex,
    required String bobTargetPublicKeyHex,
  }) async {
    // 1. SS1 = X25519(SK_E_A, PK_target)
    final ss1Key = await computeSharedSecret(
      localX25519KeyPair: ephemeralKeyPair,
      remoteX25519PublicKeyHex: bobTargetPublicKeyHex,
    );
    final ss1Bytes = await ss1Key.extractBytes();

    // 2. SS2 = X25519(SK_S_A, PK_target)
    final ss2Key = await computeSharedSecret(
      localX25519KeyPair: staticX25519KeyPair,
      remoteX25519PublicKeyHex: bobTargetPublicKeyHex,
    );
    final ss2Bytes = await ss2Key.extractBytes();

    // 3. SS = SS1 || SS2 (64 bytes)
    final ssBytes = Uint8List.fromList([...ss1Bytes, ...ss2Bytes]);

    // 4. Salt = SHA256(PK_E_A || PK_target || PK_Ed_A)
    final ephPubHex = await getX25519PublicKeyHex(ephemeralKeyPair);
    final ephPubBytes = _hexToBytes(ephPubHex);
    final targetPubBytes = _hexToBytes(bobTargetPublicKeyHex);
    final edPubBytes = _hexToBytes(aliceEd25519PublicKeyHex);

    final saltInput = Uint8List.fromList([...ephPubBytes, ...targetPubBytes, ...edPubBytes]);
    final saltDigestHex = await sha256Hex(saltInput);
    final saltBytes = _hexToBytes(saltDigestHex);

    // 5. HKDF-SHA256
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final infoBytes = utf8.encode('omnilink-v1.1-chacha20poly1305-aead');

    return await hkdf.deriveKey(
      secretKey: SecretKey(ssBytes),
      nonce: saltBytes,
      info: infoBytes,
    );
  }

  /// Computes Dual-ECDH shared secret and derives 32-byte message key for Recipient Bob.
  Future<SecretKey> deriveRecipientMessageKey({
    required SimpleKeyPair bobTargetKeyPair,
    required String aliceEphemeralPublicKeyHex,
    required String aliceStaticX25519PublicKeyHex,
    required String aliceEd25519PublicKeyHex,
    required String bobTargetPublicKeyHex,
  }) async {
    // 1. SS1 = X25519(SK_target, PK_E_A)
    final ss1Key = await computeSharedSecret(
      localX25519KeyPair: bobTargetKeyPair,
      remoteX25519PublicKeyHex: aliceEphemeralPublicKeyHex,
    );
    final ss1Bytes = await ss1Key.extractBytes();

    // 2. SS2 = X25519(SK_target, PK_S_A)
    final ss2Key = await computeSharedSecret(
      localX25519KeyPair: bobTargetKeyPair,
      remoteX25519PublicKeyHex: aliceStaticX25519PublicKeyHex,
    );
    final ss2Bytes = await ss2Key.extractBytes();

    // 3. SS = SS1 || SS2 (64 bytes)
    final ssBytes = Uint8List.fromList([...ss1Bytes, ...ss2Bytes]);

    // 4. Salt = SHA256(PK_E_A || PK_target || PK_Ed_A)
    final ephPubBytes = _hexToBytes(aliceEphemeralPublicKeyHex);
    final targetPubBytes = _hexToBytes(bobTargetPublicKeyHex);
    final edPubBytes = _hexToBytes(aliceEd25519PublicKeyHex);

    final saltInput = Uint8List.fromList([...ephPubBytes, ...targetPubBytes, ...edPubBytes]);
    final saltDigestHex = await sha256Hex(saltInput);
    final saltBytes = _hexToBytes(saltDigestHex);

    // 5. HKDF-SHA256
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final infoBytes = utf8.encode('omnilink-v1.1-chacha20poly1305-aead');

    return await hkdf.deriveKey(
      secretKey: SecretKey(ssBytes),
      nonce: saltBytes,
      info: infoBytes,
    );
  }

  // --------------------------------------------------------------------------
  // CHACHA20-POLY1305 AEAD PAYLOAD ENCRYPTION & DECRYPTION
  // --------------------------------------------------------------------------

  /// Encrypts plaintext bytes using ChaCha20-Poly1305 AEAD with K_msg and optional AAD.
  Future<String> encryptPayload({
    required Uint8List plaintext,
    required SecretKey secretKey,
    List<int>? nonce,
    Uint8List? aad,
  }) async {
    final secretKeyBytes = Uint8List.fromList(await secretKey.extractBytes());
    try {
      return await _workerPool.execute<String>(
        taskType: CryptoTaskType.encrypt,
        params: {
          'plaintext': plaintext,
          'secretKeyBytes': secretKeyBytes,
          if (nonce != null) 'nonce': nonce,
          if (aad != null) 'aad': aad,
        },
      );
    } catch (_) {
      return await Isolate.run(
        () => _encryptPayloadSync(plaintext, secretKeyBytes, nonce: nonce, aad: aad),
      );
    }
  }

  static Future<String> _encryptPayloadSync(
    Uint8List plaintext,
    Uint8List secretKeyBytes, {
    List<int>? nonce,
    Uint8List? aad,
  }) async {
    final chacha20Poly1305 = Chacha20.poly1305Aead();
    final secretBox = await chacha20Poly1305.encrypt(
      plaintext,
      secretKey: SecretKey(secretKeyBytes),
      nonce: nonce,
      aad: aad ?? const [],
    );

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

  /// Decrypts a Base64-encoded ChaCha20-Poly1305 payload with K_msg and optional AAD.
  Future<Uint8List> decryptPayload({
    required String base64Payload,
    required SecretKey secretKey,
    Uint8List? aad,
  }) async {
    final secretKeyBytes = Uint8List.fromList(await secretKey.extractBytes());
    try {
      return await _workerPool.execute<Uint8List>(
        taskType: CryptoTaskType.decrypt,
        params: {
          'base64Payload': base64Payload,
          'secretKeyBytes': secretKeyBytes,
          if (aad != null) 'aad': aad,
        },
      );
    } catch (e) {
      if (e is CryptoTaskException) {
        rethrow;
      }
      return await Isolate.run(
        () => _decryptPayloadSync(base64Payload, secretKeyBytes, aad: aad),
      );
    }
  }

  static Future<Uint8List> _decryptPayloadSync(
    String base64Payload,
    Uint8List secretKeyBytes, {
    Uint8List? aad,
  }) async {
    final chacha20Poly1305 = Chacha20.poly1305Aead();
    final combined = base64Decode(base64Payload);

    const nonceLength = 12; // ChaCha20-Poly1305 96-bit nonce
    const macLength = 16;   // Poly1305 128-bit MAC tag

    if (combined.length < nonceLength + macLength) {
      throw const FormatException('INVALID_PAYLOAD: Encrypted payload bytes too short.');
    }

    final nonce = combined.sublist(0, nonceLength);
    final macBytes = combined.sublist(nonceLength, nonceLength + macLength);
    final cipherText = combined.sublist(nonceLength + macLength);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final decryptedBytes = await chacha20Poly1305.decrypt(
      secretBox,
      secretKey: SecretKey(secretKeyBytes),
      aad: aad ?? const [],
    );

    return Uint8List.fromList(decryptedBytes);
  }

  // --------------------------------------------------------------------------
  // DIGEST HASHING & SAS DERIVATION
  // --------------------------------------------------------------------------

  /// Computes hex-encoded SHA-256 hash digest of a byte array in worker isolate pool.
  Future<String> sha256Hex(Uint8List input) async {
    try {
      return await _workerPool.execute<String>(
        taskType: CryptoTaskType.sha256Hex,
        params: {'input': input},
      );
    } catch (_) {
      return await Isolate.run(() => _sha256HexSync(input));
    }
  }

  static Future<String> _sha256HexSync(Uint8List input) async {
    final sha256 = Sha256();
    final digest = await sha256.hash(input);
    return _bytesToHex(digest.bytes);
  }

  /// Computes 6-digit decimal Short Authentication String (SAS) for Out-of-Band pairing verification.
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

    final byteData = ByteData.sublistView(Uint8List.fromList(macBytes));
    final value64 = byteData.getUint64(0, Endian.big);

    final code = (value64 % 1000000).toString().padLeft(6, '0');
    return '${code.substring(0, 3)}-${code.substring(3, 6)}';
  }

  // --------------------------------------------------------------------------
  // HEX CONVERSION UTILITIES
  // --------------------------------------------------------------------------

  static String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List hexToBytes(String hex) {
    hex = hex.replaceAll(' ', '');
    if (hex.length % 2 != 0) {
      throw const FormatException('Invalid hex string length.');
    }
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  static String _bytesToHex(List<int> bytes) => bytesToHex(bytes);
  static Uint8List _hexToBytes(String hex) => hexToBytes(hex);

  /// Shuts down the persistent isolate worker pool.
  void dispose() {
    _workerPool.dispose();
  }
}
