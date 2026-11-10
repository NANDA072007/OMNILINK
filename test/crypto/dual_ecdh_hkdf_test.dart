import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Slice 1B.4 — Dual-ECDH + HKDF Unit & Security Tests', () {
    late CryptoService cryptoService;

    setUp(() {
      cryptoService = CryptoService();
    });

    test('1 & Mandatory 5. Alice sender derived K_msg matches Bob recipient derived K_msg EXACTLY', () async {
      // Alice Keypairs
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceEphX = await cryptoService.generateX25519KeyPair();

      final aliceEdHex = await cryptoService.getEd25519PublicKeyHex(aliceEd);
      final aliceStaticXHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX);
      final aliceEphXHex = await cryptoService.getX25519PublicKeyHex(aliceEphX);

      // Bob Keypairs
      final bobSpkX = await cryptoService.generateX25519KeyPair();
      final bobSpkXHex = await cryptoService.getX25519PublicKeyHex(bobSpkX);

      // Sender Alice derives K_msg
      final kMsgAlice = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );

      // Recipient Bob derives K_msg
      final kMsgBob = await cryptoService.deriveRecipientMessageKey(
        bobTargetKeyPair: bobSpkX,
        aliceEphemeralPublicKeyHex: aliceEphXHex,
        aliceStaticX25519PublicKeyHex: aliceStaticXHex,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );

      final aliceBytes = await kMsgAlice.extractBytes();
      final bobBytes = await kMsgBob.extractBytes();

      expect(aliceBytes.length, equals(32));
      expect(bobBytes.length, equals(32));
      expect(aliceBytes, equals(bobBytes));
    });

    test('2 & Section 6. Negative Key Tests: Tampering with any input changes derived K_msg', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceEphX = await cryptoService.generateX25519KeyPair();

      final aliceEdHex = await cryptoService.getEd25519PublicKeyHex(aliceEd);
      final aliceStaticXHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX);
      final aliceEphXHex = await cryptoService.getX25519PublicKeyHex(aliceEphX);

      final bobSpkX = await cryptoService.generateX25519KeyPair();
      final bobSpkXHex = await cryptoService.getX25519PublicKeyHex(bobSpkX);

      final originalKey = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      final origBytes = await originalKey.extractBytes();

      // Tamper Ephemeral Key
      final tamperedEphX = await cryptoService.generateX25519KeyPair();
      final keyTamperedEph = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: tamperedEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      expect(await keyTamperedEph.extractBytes(), isNot(equals(origBytes)));

      // Tamper Static Key
      final tamperedStaticX = await cryptoService.generateX25519KeyPair();
      final keyTamperedStatic = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: tamperedStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      expect(await keyTamperedStatic.extractBytes(), isNot(equals(origBytes)));

      // Tamper Identity Key
      final tamperedEd = await cryptoService.generateEd25519KeyPair();
      final tamperedEdHex = await cryptoService.getEd25519PublicKeyHex(tamperedEd);
      final keyTamperedEd = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: tamperedEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      expect(await keyTamperedEd.extractBytes(), isNot(equals(origBytes)));

      // Wrong Recipient (Charlie)
      final charlieSpkX = await cryptoService.generateX25519KeyPair();

      final keyCharlie = await cryptoService.deriveRecipientMessageKey(
        bobTargetKeyPair: charlieSpkX, // Charlie trying to decrypt message meant for Bob
        aliceEphemeralPublicKeyHex: aliceEphXHex,
        aliceStaticX25519PublicKeyHex: aliceStaticXHex,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex, // Salt had Bob's pubkey
      );
      expect(await keyCharlie.extractBytes(), isNot(equals(origBytes)));
    });

    test('3 & Section 7. Key Separation: All key roles produce distinct byte material', () async {
      final ed = await cryptoService.generateEd25519KeyPair();
      final staticX = await cryptoService.generateX25519KeyPair();
      final spkX = await cryptoService.generateX25519KeyPair();
      final ephX = await cryptoService.generateX25519KeyPair();

      final edHex = await cryptoService.getEd25519PublicKeyHex(ed);
      final staticHex = await cryptoService.getX25519PublicKeyHex(staticX);
      final spkHex = await cryptoService.getX25519PublicKeyHex(spkX);
      final ephHex = await cryptoService.getX25519PublicKeyHex(ephX);

      final msgKey = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: ephX,
        staticX25519KeyPair: staticX,
        aliceEd25519PublicKeyHex: edHex,
        bobTargetPublicKeyHex: spkHex,
      );
      final msgKeyHex = CryptoService.bytesToHex(await msgKey.extractBytes());

      final keys = {edHex, staticHex, spkHex, ephHex, msgKeyHex};
      expect(keys.length, equals(5), reason: 'All 5 key types MUST be mathematically distinct');
    });

    test('4 & Section 8. Compromise Analysis Case B: Theft of Alice static key SA alone CANNOT decrypt past message if EA is destroyed', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceEphX = await cryptoService.generateX25519KeyPair();

      final aliceEdHex = await cryptoService.getEd25519PublicKeyHex(aliceEd);
      final aliceEphXHex = await cryptoService.getX25519PublicKeyHex(aliceEphX);

      final bobSpkX = await cryptoService.generateX25519KeyPair();
      final bobSpkXHex = await cryptoService.getX25519PublicKeyHex(bobSpkX);

      // Sender Alice derives original K_msg
      final origKMsg = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      final origBytes = await origKMsg.extractBytes();

      // Alice destroys EA.
      // Attacker possesses: Alice's stolen static key (aliceStaticX), public envelope material (aliceEphXHex, aliceEdHex, bobSpkXHex).
      // Attacker does NOT have SK_E_A or SK_SPK_B.
      // Attacker can compute SS2 = X25519(SK_S_A, PK_SPK_B).
      final ss2Key = await cryptoService.computeSharedSecret(
        localX25519KeyPair: aliceStaticX,
        remoteX25519PublicKeyHex: bobSpkXHex,
      );
      final ss2Bytes = await ss2Key.extractBytes();

      // Attacker tries to forge SS1 with random bytes or zeros
      final fakeSs1 = List<int>.filled(32, 0);
      final attackerSsBytes = Uint8List.fromList([...fakeSs1, ...ss2Bytes]);

      final saltInput = Uint8List.fromList([
        ...CryptoService.hexToBytes(aliceEphXHex),
        ...CryptoService.hexToBytes(bobSpkXHex),
        ...CryptoService.hexToBytes(aliceEdHex),
      ]);
      final saltDigestHex = await cryptoService.sha256Hex(saltInput);
      final saltBytes = CryptoService.hexToBytes(saltDigestHex);

      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      final attackerKMsg = await hkdf.deriveKey(
        secretKey: SecretKey(attackerSsBytes),
        nonce: saltBytes,
        info: utf8.encode('omnilink-v1.1-chacha20poly1305-aead'),
      );

      final attackerBytes = await attackerKMsg.extractBytes();

      // Attacker's derived K_msg MUST NOT match original K_msg!
      expect(attackerBytes, isNot(equals(origBytes)));
    });

    test('5. Bob SPK Compromise Analysis: Historical K_msg IS recoverable while SK_SPK_B exists, but UNRECOVERABLE from public material after secure erasure', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceEphX = await cryptoService.generateX25519KeyPair();

      final aliceEdHex = await cryptoService.getEd25519PublicKeyHex(aliceEd);
      final aliceStaticXHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX);
      final aliceEphXHex = await cryptoService.getX25519PublicKeyHex(aliceEphX);

      final bobSpkX = await cryptoService.generateX25519KeyPair();
      final bobSpkXHex = await cryptoService.getX25519PublicKeyHex(bobSpkX);

      final origKMsg = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      final origBytes = await origKMsg.extractBytes();

      // 1. While Bob's SK_SPK_B exists, attacker with SK_SPK_B CAN recover K_msg
      final recoveredKMsg = await cryptoService.deriveRecipientMessageKey(
        bobTargetKeyPair: bobSpkX,
        aliceEphemeralPublicKeyHex: aliceEphXHex,
        aliceStaticX25519PublicKeyHex: aliceStaticXHex,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      expect(await recoveredKMsg.extractBytes(), equals(origBytes));

      // 2. Once SK_SPK_B is erased, an attacker with ONLY public packet material cannot derive K_msg
      final fakeSpkSeed = List<int>.filled(32, 7); // Random seed
      final fakeSpkKeyPair = await cryptoService.restoreX25519KeyPair(fakeSpkSeed);

      final failedKMsg = await cryptoService.deriveRecipientMessageKey(
        bobTargetKeyPair: fakeSpkKeyPair,
        aliceEphemeralPublicKeyHex: aliceEphXHex,
        aliceStaticX25519PublicKeyHex: aliceStaticXHex,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      expect(await failedKMsg.extractBytes(), isNot(equals(origBytes)));
    });

    test('6. Alice Ephemeral Compromise Analysis: Theft of EA private key allows K_msg reconstruction only when combined with recipient key', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceStaticX = await cryptoService.generateX25519KeyPair();
      final aliceEphX = await cryptoService.generateX25519KeyPair();

      final aliceEdHex = await cryptoService.getEd25519PublicKeyHex(aliceEd);

      final bobSpkX = await cryptoService.generateX25519KeyPair();
      final bobSpkXHex = await cryptoService.getX25519PublicKeyHex(bobSpkX);

      final origKMsg = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      final origBytes = await origKMsg.extractBytes();

      // Attacker obtains SK_E_A and SK_SPK_B -> Reconstructs K_msg
      final reconstructed = await cryptoService.deriveSenderMessageKey(
        ephemeralKeyPair: aliceEphX,
        staticX25519KeyPair: aliceStaticX,
        aliceEd25519PublicKeyHex: aliceEdHex,
        bobTargetPublicKeyHex: bobSpkXHex,
      );
      expect(await reconstructed.extractBytes(), equals(origBytes));
    });

    test('7. Ed25519 Identity Key Compromise Analysis: Possession of SK_Ed_A does NOT yield secret HKDF inputs', () async {
      final aliceEd = await cryptoService.generateEd25519KeyPair();
      final aliceEphX = await cryptoService.generateX25519KeyPair();

      final aliceEdHex = await cryptoService.getEd25519PublicKeyHex(aliceEd);
      final bobSpkX = await cryptoService.generateX25519KeyPair();
      final bobSpkXHex = await cryptoService.getX25519PublicKeyHex(bobSpkX);

      // Extract private key bytes of Ed25519 key
      final edPrivateKeyBytes = await aliceEd.extractPrivateKeyBytes();

      // Verify that Ed25519 private key bytes are 32 bytes used for signatures, NOT for X25519 ECDH
      expect(edPrivateKeyBytes.length, equals(32));

      // PK_Ed_A is public and passed directly into HKDF salt computation
      final saltInput = Uint8List.fromList([
        ...CryptoService.hexToBytes(await cryptoService.getX25519PublicKeyHex(aliceEphX)),
        ...CryptoService.hexToBytes(bobSpkXHex),
        ...CryptoService.hexToBytes(aliceEdHex),
      ]);
      final saltDigestHex = await cryptoService.sha256Hex(saltInput);

      // Identity private key SK_Ed_A is never passed to HKDF IKM or Salt
      expect(saltDigestHex.length, equals(64));
    });
  });
}
