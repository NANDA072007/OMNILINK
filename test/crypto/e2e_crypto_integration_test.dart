import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:omnilink/core/crypto/signed_prekey_manager.dart';
import 'package:omnilink/core/database/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Slice 1B.9 — End-to-End Cryptographic Integration & Security Tests', () {
    late CryptoService cryptoService;
    late DatabaseService dbService;
    late PacketService packetService;
    late FlutterSecureStorage secureStorage;

    // Alice keys
    late SimpleKeyPair aliceEd25519KeyPair;
    late String aliceNodeId;
    late SimpleKeyPair aliceStaticX25519KeyPair;
    late String aliceStaticX25519PubHex;

    // Bob keys
    late SimpleKeyPair bobEd25519KeyPair;
    late String bobNodeId;
    late SimpleKeyPair bobStaticX25519KeyPair;
    late String bobStaticX25519PubHex;
    late SignedPreKeyManager bobSpkManager;

    // Charlie (Adversary / Unintended Recipient) keys
    late SimpleKeyPair charlieStaticX25519KeyPair;
    late SignedPreKeyManager charlieSpkManager;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      databaseFactory = databaseFactoryFfi;
      dbService = DatabaseService();

      final db = await dbService.database;
      await db.delete('processed_packets');

      cryptoService = CryptoService();
      packetService = PacketService(
        cryptoService: cryptoService,
        dbService: dbService,
      );

      secureStorage = const FlutterSecureStorage();

      // Setup Alice
      aliceEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      aliceNodeId = await cryptoService.getEd25519PublicKeyHex(aliceEd25519KeyPair);
      aliceStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      aliceStaticX25519PubHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX25519KeyPair);

      // Setup Bob
      bobEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      bobNodeId = await cryptoService.getEd25519PublicKeyHex(bobEd25519KeyPair);
      bobStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      bobStaticX25519PubHex = await cryptoService.getX25519PublicKeyHex(bobStaticX25519KeyPair);
      bobSpkManager = SignedPreKeyManager(cryptoService, secureStorage);

      // Setup Charlie
      charlieStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      charlieSpkManager = SignedPreKeyManager(cryptoService, secureStorage);
    });

    test('1, 6, 7 & 17. Complete End-to-End Cryptographic Path (Alice -> Relay -> Bob)', () async {
      const plaintext = 'Secret End-to-End Encrypted Message from Alice to Bob';

      // Step 1: Alice creates E2E encrypted envelope for Bob
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticX25519PubHex,
        plaintextBody: plaintext,
      );

      expect(envelope.ephemeralPublicKey, isNotNull);
      expect(envelope.ephemeralPublicKey!.length, equals(64));
      expect(envelope.encryptedPayload, isNot(contains(plaintext)));

      // Step 2: Relay mutates TTL and hopCount
      final relayedEnvelope = envelope.copyWith(
        ttl: envelope.ttl - 1,
        hopCount: envelope.hopCount + 1,
      );

      // Step 3: Bob validates signature and checks persistent replay state
      final isClaimed = await packetService.validateAndClaimEnvelope(relayedEnvelope);
      expect(isClaimed, isTrue);

      // Step 4: Bob derives Dual-ECDH key and decrypts AEAD ciphertext
      final decryptedText = await packetService.decryptMessageEnvelope(
        envelope: relayedEnvelope,
        recipientStaticKeyPair: bobStaticX25519KeyPair,
        spkManager: bobSpkManager,
        senderStaticX25519PublicKeyHex: aliceStaticX25519PubHex,
      );

      expect(decryptedText, equals(plaintext));
    });

    test('8. Multi-Hop Relay (Alice -> Relay A -> Relay B -> Bob)', () async {
      const plaintext = 'Multi-Hop Relay Message';

      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticX25519PubHex,
        plaintextBody: plaintext,
      );

      // Relay A mutates hop 1
      final hop1 = envelope.copyWith(ttl: 6, hopCount: 1);
      // Relay B mutates hop 2
      final hop2 = hop1.copyWith(ttl: 5, hopCount: 2);

      expect(await packetService.validateAndClaimEnvelope(hop2), isTrue);

      final decrypted = await packetService.decryptMessageEnvelope(
        envelope: hop2,
        recipientStaticKeyPair: bobStaticX25519KeyPair,
        spkManager: bobSpkManager,
        senderStaticX25519PublicKeyHex: aliceStaticX25519PubHex,
      );

      expect(decrypted, equals(plaintext));
    });

    test('8 & 13. Wrong Recipient Rejection: Charlie cannot decrypt Alice -> Bob message', () async {
      const plaintext = 'Confidential Message for Bob Only';

      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticX25519PubHex,
        plaintextBody: plaintext,
      );

      // Charlie attempts decryption using Charlie's static keypair & SPK manager
      expect(
        () async => await packetService.decryptMessageEnvelope(
          envelope: envelope,
          recipientStaticKeyPair: charlieStaticX25519KeyPair,
          spkManager: charlieSpkManager,
          senderStaticX25519PublicKeyHex: aliceStaticX25519PubHex,
        ),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('AEAD_DECRYPTION_FAILED'))),
      );
    });

    test('10. DTN Delivery with Grace Signed Pre-Key (SPK)', () async {
      const plaintext = 'Grace Window DTN Message';

      // Bob generates initial SPK B1
      final bobSpk1 = await bobSpkManager.getOrInitializeActivePreKey();
      final bobSpk1PubHex = await cryptoService.getX25519PublicKeyHex(bobSpk1);

      // Alice encrypts for Bob using Bob SPK1
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobSpk1PubHex,
        plaintextBody: plaintext,
      );

      // Bob rotates to fresh active SPK B2, transitioning SPK B1 to GRACE state
      final bobSpk2 = await bobSpkManager.generateAndActivateNewPreKey();
      expect(await cryptoService.getX25519PublicKeyHex(bobSpk2), isNot(equals(bobSpk1PubHex)));

      // Delayed DTN message arrives! Bob decrypts envelope fallback to SPK B1 in grace inventory
      final decrypted = await packetService.decryptMessageEnvelope(
        envelope: envelope,
        recipientStaticKeyPair: bobStaticX25519KeyPair,
        spkManager: bobSpkManager,
        senderStaticX25519PublicKeyHex: aliceStaticX25519PubHex,
      );

      expect(decrypted, equals(plaintext));
    });

    test('20. Encryption Uniqueness: Identical plaintexts produce distinct ephemeral keys, nonces, and ciphertexts', () async {
      const plaintext = 'Identical Hello';

      final env1 = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticX25519PubHex,
        plaintextBody: plaintext,
      );

      final env2 = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticX25519PubHex,
        plaintextBody: plaintext,
      );

      expect(env1.ephemeralPublicKey, isNot(equals(env2.ephemeralPublicKey)), reason: 'Ephemeral public key MUST be unique per message');
      expect(env1.encryptedPayload, isNot(equals(env2.encryptedPayload)), reason: 'AEAD ciphertext MUST be unique per message');
      expect(env1.signature, isNot(equals(env2.signature)), reason: 'Envelope signature MUST be unique per message');

      // Both decrypt to identical original plaintext
      final dec1 = await packetService.decryptMessageEnvelope(
        envelope: env1,
        recipientStaticKeyPair: bobStaticX25519KeyPair,
        spkManager: bobSpkManager,
        senderStaticX25519PublicKeyHex: aliceStaticX25519PubHex,
      );
      final dec2 = await packetService.decryptMessageEnvelope(
        envelope: env2,
        recipientStaticKeyPair: bobStaticX25519KeyPair,
        spkManager: bobSpkManager,
        senderStaticX25519PublicKeyHex: aliceStaticX25519PubHex,
      );

      expect(dec1, equals(plaintext));
      expect(dec2, equals(plaintext));
    });

    test('19 & 21. Tampering immutable fields fails signature verification', () async {
      final validEnvelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticX25519PubHex,
        plaintextBody: 'Immutable Security Boundary Payload',
      );

      // Tamper ciphertext
      final tamperedPayload = validEnvelope.copyWith(encryptedPayload: 'tampered-base64-payload');
      expect(
        () async => await packetService.validateEnvelope(tamperedPayload),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('PAYLOAD_HASH_MISMATCH'))),
      );

      // Tamper ephemeral key
      final tamperedEph = validEnvelope.copyWith(ephemeralPublicKey: '0' * 64);
      expect(
        () async => await packetService.validateEnvelope(tamperedEph),
        throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'errorCode', equals('INVALID_SIGNATURE'))),
      );
    });
  });
}
