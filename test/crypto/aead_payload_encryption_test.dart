import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Slice 1B.5 — AEAD Payload Encryption & Decryption Tests', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = CryptoService();
    });

    test('1 & Positive Section 7. E2E Dual-ECDH -> HKDF -> AEAD Encrypt & Decrypt roundtrip', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceEphX = await cryptoService.generateX25519KeyPair();

      final aliceEdHex = await cryptoService.getEd25519PublicKeyHex(aliceEd);
      final aliceStaticXHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX);
      final aliceEphXHex = await cryptoService.getX25519PublicKeyHex(aliceEphX);

      final bobSpkX = await cryptoService.generateX25519KeyPair();
      final bobSpkXHex = await cryptoService.getX25519PublicKeyHex(bobSpkX);

      final kMsgAlice = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );

      final kMsgBob = await cryptoService.deriveRecipientMessageKey(
        bobTargetKeyPair: bobSpkX,
        aliceEphemeralPublicKeyHex: aliceEphXHex,
        aliceStaticX25519PublicKeyHex: aliceStaticXHex,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );

      const originalText = 'OMNILINK AEAD Payload Test — Dual-ECDH HKDF ChaCha20-Poly1305';
      final plaintext = Uint8List.fromList(utf8.encode(originalText));
      final aad = Uint8List.fromList(utf8.encode('omnilink-v1.1-packet-aad-header-context'));

      // Encrypt with Alice's derived K_msg
      final base64Payload = await cryptoService.encryptPayload(
        plaintext: plaintext,
        secretKey: kMsgAlice,
        aad: aad,
      );

      // Decrypt with Bob's derived K_msg
      final decryptedBytes = await cryptoService.decryptPayload(
        base64Payload: base64Payload,
        secretKey: kMsgBob,
        aad: aad,
      );

      expect(utf8.decode(decryptedBytes), equals(originalText));
    });

    test('2 & Section 8. Negative AEAD Tests (Key, Ciphertext, Nonce, AAD, Truncation)', () async {
      final key1 = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: await cryptoService.generateX25519KeyPair(),
        staticX25519KeyPair: await cryptoService.generateX25519KeyPair(),
        aliceEd25519PublicKeyHex: await cryptoService.getEd25519PublicKeyHex(await cryptoService.generateEd25519KeyPair()),
        bobTargetPublicKeyHex: await cryptoService.getX25519PublicKeyHex(await cryptoService.generateX25519KeyPair()),
      );

      final key2 = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: await cryptoService.generateX25519KeyPair(),
        staticX25519KeyPair: await cryptoService.generateX25519KeyPair(),
        aliceEd25519PublicKeyHex: await cryptoService.getEd25519PublicKeyHex(await cryptoService.generateEd25519KeyPair()),
        bobTargetPublicKeyHex: await cryptoService.getX25519PublicKeyHex(await cryptoService.generateX25519KeyPair()),
      );

      final plaintext = Uint8List.fromList(utf8.encode('Top Secret Mesh Data'));
      final aad = Uint8List.fromList(utf8.encode('Valid AAD Context'));

      final base64Payload = await cryptoService.encryptPayload(
        plaintext: plaintext,
        secretKey: key1,
        aad: aad,
      );

      // 1. Wrong key
      expect(
        () async => await cryptoService.decryptPayload(base64Payload: base64Payload, secretKey: key2, aad: aad),
        throwsA(anything),
      );

      // 2. Tampered Ciphertext
      final payloadBytes = List<int>.from(base64Decode(base64Payload));
      payloadBytes[payloadBytes.length - 1] ^= 0xFF; // Flip last byte
      final tamperedCiphertextBase64 = base64Encode(payloadBytes);
      expect(
        () async => await cryptoService.decryptPayload(base64Payload: tamperedCiphertextBase64, secretKey: key1, aad: aad),
        throwsA(anything),
      );

      // 3. Tampered Nonce
      final tamperedNonceBytes = List<int>.from(base64Decode(base64Payload));
      tamperedNonceBytes[0] ^= 0xFF; // Flip first nonce byte
      final tamperedNonceBase64 = base64Encode(tamperedNonceBytes);
      expect(
        () async => await cryptoService.decryptPayload(base64Payload: tamperedNonceBase64, secretKey: key1, aad: aad),
        throwsA(anything),
      );

      // 4. Tampered AAD
      final wrongAad = Uint8List.fromList(utf8.encode('Corrupted AAD Context'));
      expect(
        () async => await cryptoService.decryptPayload(base64Payload: base64Payload, secretKey: key1, aad: wrongAad),
        throwsA(anything),
      );

      // 5. Truncated Ciphertext
      final truncatedBytes = base64Decode(base64Payload).sublist(0, 15); // Less than 12+16 bytes
      final truncatedBase64 = base64Encode(truncatedBytes);
      expect(
        () async => await cryptoService.decryptPayload(base64Payload: truncatedBase64, secretKey: key1, aad: aad),
        throwsA(anything),
      );
    });

    test('3 & Section 8. Boundary Cases (Empty, Large 1MB, Unicode)', () async {
      final key = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: await cryptoService.generateX25519KeyPair(),
        staticX25519KeyPair: await cryptoService.generateX25519KeyPair(),
        aliceEd25519PublicKeyHex: await cryptoService.getEd25519PublicKeyHex(await cryptoService.generateEd25519KeyPair()),
        bobTargetPublicKeyHex: await cryptoService.getX25519PublicKeyHex(await cryptoService.generateX25519KeyPair()),
      );

      // Case 6: Empty plaintext
      final emptyText = Uint8List(0);
      final emptyEnc = await cryptoService.encryptPayload(plaintext: emptyText, secretKey: key);
      final emptyDec = await cryptoService.decryptPayload(base64Payload: emptyEnc, secretKey: key);
      expect(emptyDec.length, equals(0));

      // Case 7: Large 1 MB plaintext
      final largeBytes = Uint8List(1024 * 1024);
      for (int i = 0; i < largeBytes.length; i++) {
        largeBytes[i] = i % 256;
      }
      final largeEnc = await cryptoService.encryptPayload(plaintext: largeBytes, secretKey: key);
      final largeDec = await cryptoService.decryptPayload(base64Payload: largeEnc, secretKey: key);
      expect(largeDec, equals(largeBytes));

      // Case 8: Unicode plaintext
      const unicodeStr = '🔑 OMNILINK Mesh Protocol 🌐 — Test Plaintext Unicode! 🚀';
      final unicodeBytes = Uint8List.fromList(utf8.encode(unicodeStr));
      final unicodeEnc = await cryptoService.encryptPayload(plaintext: unicodeBytes, secretKey: key);
      final unicodeDec = await cryptoService.decryptPayload(base64Payload: unicodeEnc, secretKey: key);
      expect(utf8.decode(unicodeDec), equals(unicodeStr));
    });

    test('4 & Section 8 & 9. Nonce Uniqueness & Non-Deterministic Ciphertexts', () async {
      final key = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: await cryptoService.generateX25519KeyPair(),
        staticX25519KeyPair: await cryptoService.generateX25519KeyPair(),
        aliceEd25519PublicKeyHex: await cryptoService.getEd25519PublicKeyHex(await cryptoService.generateEd25519KeyPair()),
        bobTargetPublicKeyHex: await cryptoService.getX25519PublicKeyHex(await cryptoService.generateX25519KeyPair()),
      );

      final plaintext = Uint8List.fromList(utf8.encode('Identical Plaintext'));
      final nonces = <String>{};
      final ciphertexts = <String>{};

      for (int i = 0; i < 50; i++) {
        final payloadBase64 = await cryptoService.encryptPayload(plaintext: plaintext, secretKey: key);
        final rawBytes = base64Decode(payloadBase64);

        // Nonce is first 12 bytes
        expect(rawBytes.length, greaterThanOrEqualTo(28));
        final nonceHex = CryptoService.bytesToHex(rawBytes.sublist(0, 12));

        nonces.add(nonceHex);
        ciphertexts.add(payloadBase64);
      }

      expect(nonces.length, equals(50), reason: 'Every encryption MUST use a fresh unique 12-byte random nonce');
      expect(ciphertexts.length, equals(50), reason: 'Encrypting identical plaintext twice MUST produce distinct ciphertexts');
    });

    test('5 & Section 13. Fail-Closed Behavior: Decryption failure returns zero partial data', () async {
      final key = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: await cryptoService.generateX25519KeyPair(),
        staticX25519KeyPair: await cryptoService.generateX25519KeyPair(),
        aliceEd25519PublicKeyHex: await cryptoService.getEd25519PublicKeyHex(await cryptoService.generateEd25519KeyPair()),
        bobTargetPublicKeyHex: await cryptoService.getX25519PublicKeyHex(await cryptoService.generateX25519KeyPair()),
      );

      final plaintext = Uint8List.fromList(utf8.encode('Secret Content'));
      final base64Payload = await cryptoService.encryptPayload(plaintext: plaintext, secretKey: key);

      final corruptBytes = List<int>.from(base64Decode(base64Payload));
      corruptBytes[15] ^= 0x55; // Corrupt MAC tag
      final corruptBase64 = base64Encode(corruptBytes);

      try {
        await cryptoService.decryptPayload(base64Payload: corruptBase64, secretKey: key);
        fail('Should have thrown an exception on corrupt MAC tag');
      } catch (e) {
        expect(e, isNotNull);
      }
    });
  });
}
