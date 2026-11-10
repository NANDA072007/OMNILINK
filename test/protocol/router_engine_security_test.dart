import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/models/peer_device.dart';
import 'package:omnilink/core/routing/routing_database.dart';
import 'package:omnilink/core/routing/router_engine.dart';
import 'package:omnilink/transport_bridge/transport_adapter.dart';
import '../helpers/test_async_utils.dart';

class MockTransportAdapter implements TransportAdapter {
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
    sentPackets.add({
      'peerId': peerId,
      'bytes': packetBytes,
    });
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

  void emitPacketForTesting({required String senderPeerId, required Uint8List payloadBytes}) {
    _incomingController.add(IncomingPacketEvent(
      senderPeerId: senderPeerId,
      payloadBytes: payloadBytes,
    ));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Slice 1B.10B — RouterEngine Security Boundary Regression Tests', () {
    late CryptoService cryptoService;
    late DatabaseService dbService;
    late RoutingDatabaseService routingDb;
    late PacketService packetService;
    late MockTransportAdapter mockTransport;
    late RouterEngine routerEngine;

    // Alice (Sender)
    late SimpleKeyPair aliceEd25519KeyPair;
    late String aliceNodeId;
    late SimpleKeyPair aliceStaticX25519KeyPair;
    late String aliceStaticPubHex;

    // Bob (Local Device / Recipient)
    late SimpleKeyPair bobEd25519KeyPair;
    late String bobNodeId;
    late SimpleKeyPair bobStaticX25519KeyPair;
    late String bobStaticPubHex;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      databaseFactory = databaseFactoryFfi;
      dbService = DatabaseService.instance;
      routingDb = RoutingDatabaseService.instance;

      await dbService.clearAllTablesForTesting();

      cryptoService = CryptoService();
      packetService = PacketService(
        cryptoService: cryptoService,
        dbService: dbService,
      );

      mockTransport = MockTransportAdapter();

      aliceEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      aliceNodeId = await cryptoService.getEd25519PublicKeyHex(aliceEd25519KeyPair);
      aliceStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      aliceStaticPubHex =
          await cryptoService.getX25519PublicKeyHex(aliceStaticX25519KeyPair);

      bobEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      bobNodeId = await cryptoService.getEd25519PublicKeyHex(bobEd25519KeyPair);
      bobStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      bobStaticPubHex = await cryptoService.getX25519PublicKeyHex(bobStaticX25519KeyPair);

      const storage = FlutterSecureStorage();
      final bobStaticSeed = await bobStaticX25519KeyPair.extractPrivateKeyBytes();
      await storage.write(key: 'omnilink_static_x25519_seed', value: bobStaticSeed.join(','));

      // Production learns the sender's static X25519 key from the signed
      // ROUTE_ADVERTISEMENT before accepting messages. Mirror that here so the
      // Dual-ECDH decryption path has the key it needs.
      final alicePeer = PeerDevice(
        peerId: 'peer_alice',
        nodeId: aliceNodeId,
        friendlyName: 'Alice',
        staticX25519PublicKeyHex: aliceStaticPubHex,
        lastSeenAt: DateTime.now(),
        transportType: 'ANDROID_NEARBY',
        connectionStatus: PeerConnectionStatus.connected,
      );

      routerEngine = RouterEngine(
        transport: mockTransport,
        packetService: packetService,
        cryptoService: cryptoService,
        db: routingDb,
        getMyNodeId: () => bobNodeId,
        getMasterKeyPair: () => bobEd25519KeyPair,
        getStaticX25519KeyPair: () => bobStaticX25519KeyPair,
        getConnectedPeers: () => [alicePeer],
      );
    });

    tearDown(() async {
      routerEngine.dispose();
      await mockTransport.dispose();
      cryptoService.dispose();
    });

    test('Part F Test 1: Valid packet -> RouterEngine inbound -> validation succeeds', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Valid Inbound Message',
      );

      bool deliveredLocally = false;
      routerEngine.localInboundStream.listen((env) {
        if (env.packetId == envelope.packetId) deliveredLocally = true;
      });

      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(envelope.toJson())),
      );

      await pollUntil(
        condition: () async {
          final isProcessed = await dbService.isPacketProcessed(envelope.packetId);
          return (deliveredLocally && isProcessed) ? true : null;
        },
        message: 'Packet was not delivered locally and marked processed in DB',
      );
      expect(deliveredLocally, isTrue);
      expect(await dbService.isPacketProcessed(envelope.packetId), isTrue);
    });

    test('Part F Test 2: Tampered senderId -> INVALID_SIGNATURE -> NOT delivered/processed', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Tampered Sender Message',
      );

      final fakeKeyPair = await cryptoService.generateEd25519KeyPair();
      final fakeSenderId = await cryptoService.getEd25519PublicKeyHex(fakeKeyPair);
      final tampered = envelope.copyWith(senderId: fakeSenderId);

      bool deliveredLocally = false;
      routerEngine.localInboundStream.listen((env) {
        if (env.packetId == tampered.packetId) deliveredLocally = true;
      });

      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(tampered.toJson())),
      );

      await Future.delayed(const Duration(milliseconds: 300));
      expect(deliveredLocally, isFalse);
      expect(await dbService.isPacketProcessed(tampered.packetId), isFalse);
    });

    test('Part F Test 3: Tampered recipientId -> INVALID_SIGNATURE -> NOT processed', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Tampered Recipient Message',
      );

      final tampered = envelope.copyWith(recipientId: '0' * 64);

      bool deliveredLocally = false;
      routerEngine.localInboundStream.listen((env) {
        if (env.packetId == tampered.packetId) deliveredLocally = true;
      });

      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(tampered.toJson())),
      );

      await Future.delayed(const Duration(milliseconds: 300));
      expect(deliveredLocally, isFalse);
      expect(await dbService.isPacketProcessed(tampered.packetId), isFalse);
    });

    test('Part F Test 4: Tampered ephemeralPublicKey -> INVALID_SIGNATURE -> NOT processed', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Tampered Ephemeral Message',
      );

      final tampered = envelope.copyWith(ephemeralPublicKey: '1' * 64);

      bool deliveredLocally = false;
      routerEngine.localInboundStream.listen((env) {
        if (env.packetId == tampered.packetId) deliveredLocally = true;
      });

      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(tampered.toJson())),
      );

      await Future.delayed(const Duration(milliseconds: 300));
      expect(deliveredLocally, isFalse);
      expect(await dbService.isPacketProcessed(tampered.packetId), isFalse);
    });

    test('Part F Test 5: Tampered encryptedPayload -> PAYLOAD_HASH_MISMATCH -> NOT processed', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Tampered Ciphertext Message',
      );

      final tampered = envelope.copyWith(encryptedPayload: 'tamperedBase64Payload==');

      bool deliveredLocally = false;
      routerEngine.localInboundStream.listen((env) {
        if (env.packetId == tampered.packetId) deliveredLocally = true;
      });

      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(tampered.toJson())),
      );

      await Future.delayed(const Duration(milliseconds: 300));
      expect(deliveredLocally, isFalse);
      expect(await dbService.isPacketProcessed(tampered.packetId), isFalse);
    });

    test('Part F Test 6: Forged signature -> INVALID_SIGNATURE -> NOT processed', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Forged Signature Message',
      );

      final tampered = envelope.copyWith(signature: 'a' * 128);

      bool deliveredLocally = false;
      routerEngine.localInboundStream.listen((env) {
        if (env.packetId == tampered.packetId) deliveredLocally = true;
      });

      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(tampered.toJson())),
      );

      await Future.delayed(const Duration(milliseconds: 300));
      expect(deliveredLocally, isFalse);
      expect(await dbService.isPacketProcessed(tampered.packetId), isFalse);
    });

    test('Part F Test 8: Unauthenticated packet -> processed_packets MUST remain unchanged', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Unauthenticated Packet',
      );

      final badSig = envelope.copyWith(signature: '0' * 128);

      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(badSig.toJson())),
      );

      await Future.delayed(const Duration(milliseconds: 300));

      // SQLite processed_packets table MUST be 100% empty
      expect(await dbService.isPacketProcessed(envelope.packetId), isFalse);
      expect(packetService.isDuplicateInRam(envelope.packetId), isFalse);
    });

    test('Part F Test 9 & Part G: Legitimate Relay TTL/hopCount mutation succeeds', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Relay Mutated Message',
      );

      // Relay mutates TTL from 7 to 5 and hopCount from 0 to 2
      final relayed = envelope.copyWith(ttl: 5, hopCount: 2);

      bool deliveredLocally = false;
      routerEngine.localInboundStream.listen((env) {
        if (env.packetId == relayed.packetId) deliveredLocally = true;
      });

      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_relay',
        payloadBytes: Uint8List.fromList(utf8.encode(relayed.toJson())),
      );

      await Future.delayed(const Duration(milliseconds: 300));
      expect(deliveredLocally, isTrue);
      expect(await dbService.isPacketProcessed(relayed.packetId), isTrue);
    });

    test('Part F Test 10: Duplicate valid packet -> DUPLICATE_PACKET -> rejected', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Duplicate Delivery Message',
      );

      int localDeliveryCount = 0;
      routerEngine.localInboundStream.listen((env) {
        if (env.packetId == envelope.packetId) localDeliveryCount++;
      });

      // First delivery
      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(envelope.toJson())),
      );
      await Future.delayed(const Duration(milliseconds: 300));
      expect(localDeliveryCount, equals(1));

      // Replay attempt
      mockTransport.emitPacketForTesting(
        senderPeerId: 'peer_alice',
        payloadBytes: Uint8List.fromList(utf8.encode(envelope.toJson())),
      );
      await Future.delayed(const Duration(milliseconds: 300));
      expect(localDeliveryCount, equals(1), reason: 'Replayed packet MUST NOT be delivered again');
    });

    test('Part G: Malicious Relay Adversarial Simulation (Alice -> Malicious Relay -> Bob)', () async {
      final validEnvelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: aliceNodeId,
        senderKeyPair: aliceEd25519KeyPair,
        senderStaticX25519KeyPair: aliceStaticX25519KeyPair,
        recipientNodeId: bobNodeId,
        recipientStaticX25519PublicKeyHex: bobStaticPubHex,
        plaintextBody: 'Adversarial Relay Test Payload',
      );

      // Malicious Relay Attack 1: Change sender
      final attack1 = validEnvelope.copyWith(senderId: 'f' * 64);
      expect(await packetService.validateAndClaimEnvelope(attack1).catchError((_) => false), isFalse);

      // Malicious Relay Attack 2: Change recipient
      final attack2 = validEnvelope.copyWith(recipientId: 'e' * 64);
      expect(await packetService.validateAndClaimEnvelope(attack2).catchError((_) => false), isFalse);

      // Malicious Relay Attack 3: Replace ephemeral key
      final attack3 = validEnvelope.copyWith(ephemeralPublicKey: 'd' * 64);
      expect(await packetService.validateAndClaimEnvelope(attack3).catchError((_) => false), isFalse);

      // Malicious Relay Attack 4: Modify ciphertext
      final attack4 = validEnvelope.copyWith(encryptedPayload: 'modifiedPayloadBase64=');
      expect(await packetService.validateAndClaimEnvelope(attack4).catchError((_) => false), isFalse);

      // Malicious Relay Attack 5: Modify packet ID (invalidates signature since id is in canonical digest)
      final attack5 = validEnvelope.copyWith(packetId: 'pkt_adversarial_attack_id');
      expect(await packetService.validateAndClaimEnvelope(attack5).catchError((_) => false), isFalse);

      // Malicious Relay Attack 6: Forged signature
      final attack6 = validEnvelope.copyWith(signature: 'c' * 128);
      expect(await packetService.validateAndClaimEnvelope(attack6).catchError((_) => false), isFalse);
    });
  });
}
