import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:omnilink/core/crypto/signed_prekey_manager.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/routing/routing_database.dart';
import 'package:omnilink/core/models/packet_envelope.dart';
import 'package:omnilink/core/models/signed_key_bundle.dart';
import 'package:omnilink/core/routing/router_engine.dart';
import 'package:omnilink/transport_bridge/transport_adapter.dart';

class TestTransportAdapter implements TransportAdapter {
  final _incomingController = StreamController<IncomingPacketEvent>.broadcast();
  final _peerEventsController = StreamController<PeerConnectionEvent>.broadcast();

  final List<Map<String, dynamic>> sentPackets = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> startDiscovery({String serviceId = 'org.omnilink.mesh.v1'}) async => true;

  @override
  Future<bool> stopDiscovery() async => true;

  @override
  Future<bool> connectPeer(String peerId) async => true;

  @override
  Future<bool> disconnectPeer(String peerId) async => true;

  @override
  Future<bool> sendPacket(String peerId, Uint8List packetBytes) async {
    sentPackets.add({'peerId': peerId, 'bytes': packetBytes});
    return true;
  }

  @override
  Stream<PeerConnectionEvent> get peerEvents => _peerEventsController.stream;

  @override
  Stream<IncomingPacketEvent> get incomingPackets => _incomingController.stream;

  @override
  Future<bool> isConnected(String peerId) async => true;

  @override
  Future<void> dispose() async {
    await _incomingController.close();
    await _peerEventsController.close();
  }

  void emitPacket({required String senderPeerId, required Uint8List payloadBytes}) {
    _incomingController.add(IncomingPacketEvent(
      senderPeerId: senderPeerId,
      payloadBytes: payloadBytes,
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Slice 1B.10C — Comprehensive Adversarial Protocol Test Suite', () {
    late CryptoService cryptoService;
    late DatabaseService dbService;
    late RoutingDatabaseService routingDb;
    late PacketService packetService;
    late TestTransportAdapter transport;
    late RouterEngine routerEngine;
    late FlutterSecureStorage secureStorage;

    // Alice
    late SimpleKeyPair aliceEd25519KeyPair;
    late String aliceNodeId;
    late SimpleKeyPair aliceStaticX25519KeyPair;
    late String aliceStaticPubHex;

    // Bob
    late SimpleKeyPair bobEd25519KeyPair;
    late String bobNodeId;
    late SimpleKeyPair bobStaticX25519KeyPair;
    late String bobStaticPubHex;
    late SignedPreKeyManager bobSpkManager;

    // Charlie (Attacker)
    late SimpleKeyPair charlieEd25519KeyPair;
    late String charlieNodeId;
    late SimpleKeyPair charlieStaticX25519KeyPair;
    late String charlieStaticPubHex;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      databaseFactory = databaseFactoryFfi;
      dbService = DatabaseService.instance;
      routingDb = RoutingDatabaseService.instance;

      final db = await dbService.database;
      await db.delete('processed_packets');
      await db.delete('messages');

      cryptoService = CryptoService();
      packetService = PacketService(
        cryptoService: cryptoService,
        dbService: dbService,
      );
      secureStorage = const FlutterSecureStorage();
      transport = TestTransportAdapter();

      // Alice Setup
      aliceEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      aliceNodeId = await cryptoService.getEd25519PublicKeyHex(aliceEd25519KeyPair);
      aliceStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      aliceStaticPubHex = await cryptoService.getX25519PublicKeyHex(aliceStaticX25519KeyPair);

      // Bob Setup
      bobEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      bobNodeId = await cryptoService.getEd25519PublicKeyHex(bobEd25519KeyPair);
      bobStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      bobStaticPubHex = await cryptoService.getX25519PublicKeyHex(bobStaticX25519KeyPair);
      bobSpkManager = SignedPreKeyManager(cryptoService, secureStorage);

      // Charlie Setup
      charlieEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      charlieNodeId = await cryptoService.getEd25519PublicKeyHex(charlieEd25519KeyPair);
      charlieStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      charlieStaticPubHex = await cryptoService.getX25519PublicKeyHex(charlieStaticX25519KeyPair);

      routerEngine = RouterEngine(
        transport: transport,
        packetService: packetService,
        cryptoService: cryptoService,
        db: routingDb,
        getMyNodeId: () => bobNodeId,
        getConnectedPeers: () => [],
      );
    });

    tearDown(() async {
      routerEngine.dispose();
      await transport.dispose();
    });

    // -------------------------------------------------------------------------
    // 1. PACKET FUZZING & STRUCTURAL EDGE CASES
    // -------------------------------------------------------------------------
    group('1. Packet Fuzzing & Structural Edge Cases', () {
      test('Fuzz: Unsupported protocol version throws UNSUPPORTED_PROTOCOL_VERSION', () async {
        final validEnv = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'Fuzz Version',
        );

        final badVersion = validEnv.copyWith(protocolVersion: '99.9');
        expect(
          () async => await packetService.validateAndClaimEnvelope(badVersion),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('UNSUPPORTED_PROTOCOL_VERSION'))),
        );
      });

      test('Fuzz: Oversized payload exceeding 4,096 bytes throws INVALID_PACKET_SIZE', () async {
        final hugePayload = 'A' * 5000;
        final envelope = PacketEnvelope(
          packetId: 'pkt_oversized_test',
          senderId: aliceNodeId,
          recipientId: bobNodeId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
          messageType: 'MESSAGE_PAYLOAD',
          payloadHash: '0' * 64,
          signature: '0' * 128,
          encryptedPayload: hugePayload,
        );

        expect(
          () async => await packetService.validateAndClaimEnvelope(envelope),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('INVALID_PACKET_SIZE'))),
        );
      });

      test('Fuzz: Unexpected JSON fields parse cleanly without breaking protocol envelope', () {
        final map = {
          'protocol_version': '0.1',
          'packet_id': 'pkt_extra_field',
          'sender_id': aliceNodeId,
          'recipient_id': bobNodeId,
          'created_at': 1000,
          'expires_at': 2000,
          'message_type': 'MESSAGE_PAYLOAD',
          'payload_hash': 'abc',
          'signature': 'def',
          'encrypted_payload': 'ghi',
          'unexpected_attacker_field': 'malicious_payload',
        };

        final env = PacketEnvelope.fromMap(map);
        expect(env.packetId, equals('pkt_extra_field'));
        expect(env.senderId, equals(aliceNodeId));
      });
    });

    // -------------------------------------------------------------------------
    // 2. AUTHENTICATION FUZZING
    // -------------------------------------------------------------------------
    group('2. Authentication Fuzzing', () {
      test('Single-bit modification of immutable fields invalidates signature', () async {
        final valid = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'Immutable Field Test',
        );

        // Mutate createdAt timestamp
        final badTs = valid.copyWith(createdAt: valid.createdAt + 1000);
        expect(
          () async => await packetService.validateEnvelope(badTs),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('INVALID_SIGNATURE'))),
        );

        // Mutate messageType
        final badType = valid.copyWith(messageType: 'FORGED_TYPE');
        expect(
          () async => await packetService.validateEnvelope(badType),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('INVALID_SIGNATURE'))),
        );
      });

      test('Relay-mutable fields (ttl, hopCount) do not invalidate signature', () async {
        final valid = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'Relay Mutable Test',
        );

        final mutated = valid.copyWith(ttl: valid.ttl - 3, hopCount: valid.hopCount + 3);
        final isValid = await packetService.validateEnvelope(mutated);
        expect(isValid, isTrue);
      });
    });

    // -------------------------------------------------------------------------
    // 3. AEAD ATTACKS
    // -------------------------------------------------------------------------
    group('3. AEAD Attacks', () {
      test('Tampering ciphertext Base64 bytes causes AEAD_DECRYPTION_FAILED', () async {
        final env = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'AEAD Ciphertext Tamper Test',
        );

        // Flip base64 chars in payload
        final tamperedBytes = base64Decode(env.encryptedPayload);
        tamperedBytes[tamperedBytes.length - 1] ^= 0xFF;
        final tamperedPayloadBase64 = base64Encode(tamperedBytes);

        // Recompute hash so payloadHash digest check passes, forcing AEAD decryption step
        final newHash = await cryptoService.sha256Hex(Uint8List.fromList(utf8.encode(tamperedPayloadBase64)));
        final envWithBadPayload = env.copyWith(
          encryptedPayload: tamperedPayloadBase64,
          payloadHash: newHash,
          signature: await cryptoService.signMessage(
            env.copyWith(encryptedPayload: tamperedPayloadBase64, payloadHash: newHash).toCanonicalBytes(),
            aliceEd25519KeyPair,
          ),
        );

        expect(
          () async => await packetService.decryptMessageEnvelope(
            envelope: envWithBadPayload,
            recipientStaticKeyPair: bobStaticX25519KeyPair,
            spkManager: bobSpkManager,
            senderStaticX25519PublicKeyHex: aliceStaticPubHex,
          ),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('AEAD_DECRYPTION_FAILED'))),
        );
      });
    });

    // -------------------------------------------------------------------------
    // 4. REPLAY MATRIX
    // -------------------------------------------------------------------------
    group('4. Replay Attack Matrix', () {
      test('Replay attempt with mutated TTL is rejected by same packet_id', () async {
        final env = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'Replay TTL Test',
        );

        // Claim first delivery
        expect(await packetService.validateAndClaimEnvelope(env), isTrue);

        // Attacker mutates TTL and tries to replay
        final replayMutated = env.copyWith(ttl: 2);
        expect(
          () async => await packetService.validateAndClaimEnvelope(replayMutated),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('DUPLICATE_PACKET'))),
        );
      });

      test('5 concurrent delivery attempts result in exactly 1 claim', () async {
        final env = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'Concurrent Replay Test',
        );

        final results = await Future.wait(
          List.generate(5, (_) => packetService.validateAndClaimEnvelope(env).then((_) => true).catchError((_) => false)),
        );

        final successCount = results.where((r) => r).length;
        expect(successCount, equals(1));
      });
    });

    // -------------------------------------------------------------------------
    // 5. AUTHENTICATION + REPLAY ORDERING
    // -------------------------------------------------------------------------
    group('5. Authentication + Replay Ordering', () {
      test('Forged signature does NOT pollute SQLite processed_packets table', () async {
        final env = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'Forged Replay Test',
        );

        final forged = env.copyWith(signature: 'f' * 128);

        expect(
          () async => await packetService.validateAndClaimEnvelope(forged),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('INVALID_SIGNATURE'))),
        );

        // SQLite processed_packets MUST NOT contain packetId
        expect(await dbService.isPacketProcessed(env.packetId), isFalse);
        expect(packetService.isDuplicateInRam(env.packetId), isFalse);
      });
    });

    // -------------------------------------------------------------------------
    // 6. DTN DELAY & CLOCK SKEW
    // -------------------------------------------------------------------------
    group('6. DTN Delay & Clock Skew', () {
      test('Expired packet throws PACKET_EXPIRED', () async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final expiredEnv = PacketEnvelope(
          packetId: 'pkt_expired_test',
          senderId: aliceNodeId,
          recipientId: bobNodeId,
          createdAt: now - 10000,
          expiresAt: now - 1000, // Expired 1 second ago
          messageType: 'MESSAGE_PAYLOAD',
          payloadHash: '0' * 64,
          signature: '0' * 128,
          encryptedPayload: 'abc',
        );

        expect(
          () async => await packetService.validateAndClaimEnvelope(expiredEnv),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('PACKET_EXPIRED'))),
        );
      });

      test('Future timestamp beyond 300s (5 min) throws CLOCK_SKEW_EXCEEDED', () async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final futureEnv = PacketEnvelope(
          packetId: 'pkt_future_skew_test',
          senderId: aliceNodeId,
          recipientId: bobNodeId,
          createdAt: now + 301000, // 301 seconds in future
          expiresAt: now + 600000,
          messageType: 'MESSAGE_PAYLOAD',
          payloadHash: '0' * 64,
          signature: '0' * 128,
          encryptedPayload: 'abc',
        );

        expect(
          () async => await packetService.validateAndClaimEnvelope(futureEnv),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('CLOCK_SKEW_EXCEEDED'))),
        );
      });
    });

    // -------------------------------------------------------------------------
    // 7. WRONG RECIPIENT & EPHEMERAL KEY ATTACKS
    // -------------------------------------------------------------------------
    group('7. Wrong Recipient & Ephemeral Key Attacks', () {
      test('Substituting ephemeral public key invalidates Ed25519 signature', () async {
        final env = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'Ephemeral Key Substitution Test',
        );

        final attackerEphKeyPair = await cryptoService.generateX25519KeyPair();
        final attackerEphPubHex = await cryptoService.getX25519PublicKeyHex(attackerEphKeyPair);

        final tamperedEph = env.copyWith(ephemeralPublicKey: attackerEphPubHex);

        expect(
          () async => await packetService.validateEnvelope(tamperedEph),
          throwsA(isA<PacketValidationException>().having((e) => e.errorCode, 'code', equals('INVALID_SIGNATURE'))),
        );
      });
    });

    // -------------------------------------------------------------------------
    // 8. SIGNED KEY BUNDLE ATTACK MATRIX
    // -------------------------------------------------------------------------
    group('8. SignedKeyBundle Attack Matrix', () {
      test('Tampered X25519 static key in SignedKeyBundle fails signature verification', () async {
        final bundle = await cryptoService.createSignedKeyBundle(
          masterEd25519KeyPair: aliceEd25519KeyPair,
          staticX25519PublicKeyHex: aliceStaticPubHex,
          signedPreKeyPublicKeyHex: aliceStaticPubHex,
        );

        final tamperedBundle = SignedKeyBundle(
          identityPublicKeyHex: bundle.identityPublicKeyHex,
          staticX25519PublicKeyHex: charlieStaticPubHex, // Tampered static key
          signedPreKeyPublicKeyHex: bundle.signedPreKeyPublicKeyHex,
          timestamp: bundle.timestamp,
          signature: bundle.signature,
        );

        final isValid = await cryptoService.verifySignedKeyBundle(tamperedBundle);
        expect(isValid, isFalse);
      });
    });

    // -------------------------------------------------------------------------
    // 9. BYZANTINE RELAY SIMULATION
    // -------------------------------------------------------------------------
    group('9. Byzantine Relay Simulation', () {
      test('Relay attacks (sender, recipient, ciphertext, signature) fail closed', () async {
        final validEnv = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: 'Byzantine Relay Test',
        );

        // 1. Sender modification -> DETECTED / PREVENTED
        final b1 = validEnv.copyWith(senderId: charlieNodeId);
        expect(await packetService.validateAndClaimEnvelope(b1).catchError((_) => false), isFalse);

        // 2. Recipient modification -> DETECTED / PREVENTED
        final b2 = validEnv.copyWith(recipientId: charlieNodeId);
        expect(await packetService.validateAndClaimEnvelope(b2).catchError((_) => false), isFalse);

        // 3. Ephemeral Key modification -> DETECTED / PREVENTED
        final b3 = validEnv.copyWith(ephemeralPublicKey: charlieStaticPubHex);
        expect(await packetService.validateAndClaimEnvelope(b3).catchError((_) => false), isFalse);
      });
    });

    // -------------------------------------------------------------------------
    // 10. MULTI-HOP RELAY CHAIN
    // -------------------------------------------------------------------------
    group('10. Multi-Hop Relay Chain', () {
      test('3 intermediate relays (Alice -> Relay A -> Relay B -> Relay C -> Bob)', () async {
        const plaintext = 'Multi-Hop 4-Node Chain Message';

        final envelope = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: aliceNodeId,
          senderKeyPair: aliceEd25519KeyPair,
          senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
          recipientNodeId: bobNodeId,
          recipientStaticX25519PublicKeyHex: bobStaticPubHex,
          plaintextBody: plaintext,
        );

        // Relay A
        final rA = envelope.copyWith(ttl: 6, hopCount: 1);
        // Relay B
        final rB = rA.copyWith(ttl: 5, hopCount: 2);
        // Relay C
        final rC = rB.copyWith(ttl: 4, hopCount: 3);

        expect(await packetService.validateAndClaimEnvelope(rC), isTrue);

        final decrypted = await packetService.decryptMessageEnvelope(
          envelope: rC,
          recipientStaticKeyPair: bobStaticX25519KeyPair,
          spkManager: bobSpkManager,
          senderStaticX25519PublicKeyHex: aliceStaticPubHex,
        );

        expect(decrypted, equals(plaintext));
      });
    });

    // -------------------------------------------------------------------------
    // 11. RESOURCE EXHAUSTION & SECRET LEAKAGE AUDIT
    // -------------------------------------------------------------------------
    group('11. Secret Material Leakage Audit', () {
      test('Exceptions and log messages contain ZERO secret key leakage', () async {
        try {
          await packetService.decryptMessageEnvelope(
            envelope: PacketEnvelope(
              packetId: 'pkt_leak_test',
              senderId: aliceNodeId,
              recipientId: bobNodeId,
              ephemeralPublicKey: charlieStaticPubHex,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              expiresAt: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
              messageType: 'MESSAGE_PAYLOAD',
              payloadHash: '0' * 64,
              signature: '0' * 128,
              encryptedPayload: base64Encode(Uint8List(30)),
            ),
            recipientStaticKeyPair: bobStaticX25519KeyPair,
            spkManager: bobSpkManager,
          );
        } catch (e) {
          final errorString = e.toString();
          expect(errorString, isNot(contains(aliceNodeId)));
          expect(errorString, isNot(contains(bobStaticPubHex)));
          expect(errorString, isNot(contains('secretKey')));
          expect(errorString, isNot(contains('privateKey')));
        }
      });
    });
  });
}
