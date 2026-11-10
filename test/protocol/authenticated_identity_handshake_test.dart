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
import 'package:omnilink/core/routing/routing_database.dart';
import 'package:omnilink/core/routing/router_engine.dart';
import 'package:omnilink/core/models/packet_envelope.dart';
import 'package:omnilink/core/models/peer_device.dart';
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

  void emitPeerEventForTesting(PeerConnectionEvent event) {
    _peerEventsController.add(event);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('TASK-P0-01 Authenticated Identity Handshake & Direct Messaging Tests', () {
    late CryptoService cryptoService;
    late DatabaseService dbService;
    late RoutingDatabaseService routingDb;
    late PacketService packetService;
    late MockTransportAdapter mockTransport;
    late RouterEngine routerEngine;

    // Alice (Sender / Target Peer)
    late SimpleKeyPair aliceEd25519KeyPair;
    late String aliceNodeId;

    // Bob (Local Device)
    late SimpleKeyPair bobEd25519KeyPair;
    late String bobNodeId;

    late List<PeerDevice> connectedPeers;

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

      bobEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      bobNodeId = await cryptoService.getEd25519PublicKeyHex(bobEd25519KeyPair);

      connectedPeers = [
        PeerDevice(
          peerId: 'EP_ALICE',
          friendlyName: 'Alice Device',
          lastSeenAt: DateTime.now(),
          transportType: 'ANDROID_NEARBY',
          connectionStatus: PeerConnectionStatus.connected,
        ),
      ];

      routerEngine = RouterEngine(
        transport: mockTransport,
        packetService: packetService,
        cryptoService: cryptoService,
        db: routingDb,
        getMyNodeId: () => bobNodeId,
        getMasterKeyPair: () => bobEd25519KeyPair,
        getConnectedPeers: () => connectedPeers,
      );
    });

    tearDown(() async {
      routerEngine.dispose();
      await mockTransport.dispose();
      cryptoService.dispose();
    });

    test('TEST 1: sendRouteAdvertisement generates a valid Ed25519 signature', () async {
      await routerEngine.routeProtocol.sendRouteAdvertisement('EP_ALICE');

      expect(mockTransport.sentPackets.length, equals(1));
      final sentBytes = mockTransport.sentPackets.first['bytes'] as Uint8List;
      final jsonStr = utf8.decode(sentBytes);
      final envelope = PacketEnvelope.fromJson(jsonStr);

      expect(envelope.messageType, equals('ROUTE_ADVERTISEMENT'));
      expect(envelope.signature, isNot(equals('public_metadata')));
      expect(envelope.signature.length, equals(128)); // 64-byte Ed25519 sig in hex

      // Verification via PacketService MUST succeed
      final isValid = await packetService.validateEnvelope(envelope);
      expect(isValid, isTrue);
    });

    test('TEST 2: ROUTE_ADVERTISEMENT with dummy or invalid signature is rejected', () async {
      final payloadMap = {'nodeId': aliceNodeId, 'directNodes': []};
      final payloadJson = jsonEncode(payloadMap);
      final now = DateTime.now().millisecondsSinceEpoch;

      final dummyEnvelope = PacketEnvelope(
        protocolVersion: '0.1',
        packetId: 'adv_dummy_$now',
        senderId: aliceNodeId,
        recipientId: bobNodeId,
        createdAt: now,
        expiresAt: now + 3600000,
        ttl: 1,
        messageType: 'ROUTE_ADVERTISEMENT',
        payloadHash: await cryptoService.sha256Hex(Uint8List.fromList(utf8.encode(payloadJson))),
        signature: 'public_metadata',
        encryptedPayload: payloadJson,
      );

      // Must throw PacketValidationException('INVALID_SIGNATURE')
      expect(
        () => packetService.validateAndClaimEnvelope(dummyEnvelope),
        throwsA(isA<PacketValidationException>().having(
          (e) => e.errorCode,
          'errorCode',
          equals('INVALID_SIGNATURE'),
        )),
      );
    });

    test('TEST 3: Valid ROUTE_ADVERTISEMENT registers peerId <-> nodeId in RouterEngine', () async {
      final payloadMap = {'nodeId': aliceNodeId, 'directNodes': []};
      final payloadJson = jsonEncode(payloadMap);

      final validEnvelope = await packetService.createEnvelope(
        senderNodeId: aliceNodeId,
        recipientNodeId: bobNodeId,
        messageType: 'ROUTE_ADVERTISEMENT',
        encryptedPayloadBase64: payloadJson,
        senderKeyPair: aliceEd25519KeyPair,
        ttl: 1,
      );

      mockTransport.emitPacketForTesting(
        senderPeerId: 'EP_ALICE',
        payloadBytes: Uint8List.fromList(utf8.encode(validEnvelope.toJson())),
      );

      final routes = await pollUntil(
        condition: () async {
          final r = await routingDb.getRoutesForDestination(aliceNodeId);
          return r.isNotEmpty ? r : null;
        },
        message: 'Routes for Alice destination were not populated in routingDb',
      );

      expect(routes.first.nextHopPeerId, equals('EP_ALICE'));
    });

    test('TEST 4: Immediate direct routing selects RouteStrategy.direct on first attempt', () async {
      // 1. Establish identity registration by emitting valid signed ROUTE_ADVERTISEMENT from Alice
      final payloadMap = {'nodeId': aliceNodeId, 'directNodes': []};
      final payloadJson = jsonEncode(payloadMap);

      final validEnvelope = await packetService.createEnvelope(
        senderNodeId: aliceNodeId,
        recipientNodeId: bobNodeId,
        messageType: 'ROUTE_ADVERTISEMENT',
        encryptedPayloadBase64: payloadJson,
        senderKeyPair: aliceEd25519KeyPair,
        ttl: 1,
      );

      mockTransport.emitPacketForTesting(
        senderPeerId: 'EP_ALICE',
        payloadBytes: Uint8List.fromList(utf8.encode(validEnvelope.toJson())),
      );

      await pollUntil(
        condition: () async {
          final r = await routingDb.getRoutesForDestination(aliceNodeId);
          return r.isNotEmpty ? r : null;
        },
        message: 'Routes for Alice not established before sending user message',
      );
      mockTransport.sentPackets.clear();

      // 2. Immediately send user message to aliceNodeId
      final msgEnvelope = await packetService.createEnvelope(
        senderNodeId: bobNodeId,
        recipientNodeId: aliceNodeId,
        messageType: 'MESSAGE_PAYLOAD',
        encryptedPayloadBase64: 'TestDirectSendPayload==',
        senderKeyPair: bobEd25519KeyPair,
        ttl: 7,
      );

      RoutingEvent? capturedEvent;
      final eventSub = routerEngine.routingEvents.listen((event) {
        if (event.packetId == msgEnvelope.packetId) capturedEvent = event;
      });

      await routerEngine.sendMessage(msgEnvelope);

      await pollUntil(
        condition: () {
          final found = mockTransport.sentPackets.any((pkt) {
            final bytes = pkt['bytes'] as Uint8List;
            try {
              final env = PacketEnvelope.fromJson(utf8.decode(bytes));
              return env.packetId == msgEnvelope.packetId;
            } catch (_) {
              return false;
            }
          });
          return found ? true : null;
        },
        message: 'User message packet was not sent over mockTransport',
      );
      await eventSub.cancel();

      final sentUserPacket = mockTransport.sentPackets.firstWhere((pkt) {
        final bytes = pkt['bytes'] as Uint8List;
        try {
          final env = PacketEnvelope.fromJson(utf8.decode(bytes));
          return env.packetId == msgEnvelope.packetId;
        } catch (_) {
          return false;
        }
      });

      expect(sentUserPacket['peerId'], equals('EP_ALICE'));
      expect(capturedEvent?.strategy, equals('direct'));
    });

    test('TEST 5: Disconnect unregisters peerId <-> nodeId mapping', () async {
      routerEngine.registerPeerNodeId('EP_ALICE', aliceNodeId);
      expect(routerEngine.getNodeIdForEndpointId('EP_ALICE'), equals(aliceNodeId));

      // Trigger onDisconnected event
      mockTransport.emitPeerEventForTesting(
        const PeerConnectionEvent(
          eventType: PeerConnectionEventType.onDisconnected,
          peerId: 'EP_ALICE',
        ),
      );

      await pollUntil(
        condition: () => routerEngine.getNodeIdForEndpointId('EP_ALICE') == null ? true : null,
        message: 'Endpoint EP_ALICE was not unregistered on disconnect event',
      );

      expect(routerEngine.getNodeIdForEndpointId('EP_ALICE'), isNull);
      expect(routerEngine.getEndpointIdForNodeId(aliceNodeId), isNull);
    });

    test('TEST 6: Reconnect race preserves newer peerId mapping', () async {
      // Initial connection
      routerEngine.registerPeerNodeId('EP_123', aliceNodeId);

      // Reconnect with new peerId
      routerEngine.registerPeerNodeId('EP_456', aliceNodeId);

      // Late disconnect event for old EP_123 arrives
      routerEngine.unregisterPeerNodeId('EP_123');

      // The new EP_456 mapping MUST NOT be deleted
      final msgEnvelope = await packetService.createEnvelope(
        senderNodeId: bobNodeId,
        recipientNodeId: aliceNodeId,
        messageType: 'MESSAGE_PAYLOAD',
        encryptedPayloadBase64: 'TestPayload==',
        senderKeyPair: bobEd25519KeyPair,
        ttl: 7,
      );

      connectedPeers = [
        PeerDevice(
          peerId: 'EP_456',
          friendlyName: 'Alice Device Reconnected',
          lastSeenAt: DateTime.now(),
          transportType: 'ANDROID_NEARBY',
          connectionStatus: PeerConnectionStatus.connected,
        ),
      ];

      mockTransport.sentPackets.clear();
      await routerEngine.sendMessage(msgEnvelope);

      await pollUntil(
        condition: () {
          final found = mockTransport.sentPackets.any((pkt) {
            final bytes = pkt['bytes'] as Uint8List;
            try {
              final env = PacketEnvelope.fromJson(utf8.decode(bytes));
              return env.packetId == msgEnvelope.packetId;
            } catch (_) {
              return false;
            }
          });
          return found ? true : null;
        },
        message: 'Reconnected message was not transmitted via EP_456',
      );

      final sentUserPacket = mockTransport.sentPackets.firstWhere((pkt) {
        final bytes = pkt['bytes'] as Uint8List;
        try {
          final env = PacketEnvelope.fromJson(utf8.decode(bytes));
          return env.packetId == msgEnvelope.packetId;
        } catch (_) {
          return false;
        }
      });
      expect(sentUserPacket['peerId'], equals('EP_456'));
    });

    test('TEST 7: Duplicate handshake processing is idempotent', () async {
      final payloadMap = {'nodeId': aliceNodeId, 'directNodes': []};
      final payloadJson = jsonEncode(payloadMap);

      final validEnvelope1 = await packetService.createEnvelope(
        senderNodeId: aliceNodeId,
        recipientNodeId: bobNodeId,
        messageType: 'ROUTE_ADVERTISEMENT',
        encryptedPayloadBase64: payloadJson,
        senderKeyPair: aliceEd25519KeyPair,
        ttl: 1,
      );

      // First handshake
      mockTransport.emitPacketForTesting(
        senderPeerId: 'EP_ALICE',
        payloadBytes: Uint8List.fromList(utf8.encode(validEnvelope1.toJson())),
      );

      await pollUntil(
        condition: () async {
          final r = await routingDb.getRoutesForDestination(aliceNodeId);
          return r.isNotEmpty ? r : null;
        },
        message: 'First handshake routes were not populated',
      );

      // Duplicate handshake
      mockTransport.emitPacketForTesting(
        senderPeerId: 'EP_ALICE',
        payloadBytes: Uint8List.fromList(utf8.encode(validEnvelope1.toJson())),
      );

      // Wait until duplicate packet is confirmed processed in DB
      await pollUntil(
        condition: () async {
          final isClaimed = await packetService.isDuplicate(validEnvelope1.packetId);
          return isClaimed ? true : null;
        },
        message: 'Duplicate handshake was not recorded as processed',
      );

      // No crash or duplicate database routes
      final routes = await routingDb.getRoutesForDestination(aliceNodeId);
      expect(routes.length, equals(1));
    });
  });
}
