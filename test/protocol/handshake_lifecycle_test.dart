import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/models/packet_envelope.dart';
import 'package:omnilink/core/models/peer_device.dart';
import 'package:omnilink/core/models/signed_key_bundle.dart';
import 'package:omnilink/core/routing/router_engine.dart';
import 'package:omnilink/core/routing/routing_database.dart';
import 'package:omnilink/core/routing/send_queue.dart';
import 'package:omnilink/transport_bridge/transport_adapter.dart';

class TestLifecycleMockTransport implements TransportAdapter {
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Phase 2 — Handshake Lifecycle & Reconnection Guard Tests', () {
    late DatabaseService dbService;
    late RoutingDatabaseService routingDb;
    late CryptoService cryptoService;
    late PacketService packetService;
    late TestLifecycleMockTransport mockTransport;
    late RouterEngine routerEngine;

    late SimpleKeyPair localEd25519KeyPair;
    late String localNodeId;
    late SimpleKeyPair localStaticX25519KeyPair;
    late SignedKeyBundle localBundle;

    late List<PeerDevice> connectedPeers;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      databaseFactory = databaseFactoryFfi;
      dbService = DatabaseService.instance;
      routingDb = RoutingDatabaseService.instance;

      final db = await dbService.database;
      await db.delete('messages');
      await db.delete('peers');
      await db.delete('outbox_queue');
      await db.delete('processed_packets');
      await db.delete('routing_table');

      cryptoService = CryptoService();
      packetService = PacketService(
        cryptoService: cryptoService,
        dbService: dbService,
      );

      mockTransport = TestLifecycleMockTransport();

      localEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      localNodeId = await cryptoService.getEd25519PublicKeyHex(localEd25519KeyPair);
      localStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      final localStaticX25519Hex = await cryptoService.getX25519PublicKeyHex(localStaticX25519KeyPair);

      final dummySpkKeyPair = await cryptoService.generateX25519KeyPair();
      final dummySpkHex = await cryptoService.getX25519PublicKeyHex(dummySpkKeyPair);

      localBundle = await cryptoService.createSignedKeyBundle(
        masterEd25519KeyPair: localEd25519KeyPair,
        staticX25519PublicKeyHex: localStaticX25519Hex,
        signedPreKeyPublicKeyHex: dummySpkHex,
      );

      connectedPeers = [
        PeerDevice(
          peerId: 'EP_PEER_ALPHA',
          friendlyName: 'Alpha Device',
          lastSeenAt: DateTime.now(),
          transportType: 'ANDROID_NEARBY',
          connectionStatus: PeerConnectionStatus.connected,
        ),
      ];
    });

    tearDown(() async {
      routerEngine.dispose();
      await mockTransport.dispose();
    });

    test('1. Bounded retry waits for signedKeyBundle and transmits when ready', () async {
      SignedKeyBundle? delayedBundle;

      routerEngine = RouterEngine(
        transport: mockTransport,
        packetService: packetService,
        cryptoService: cryptoService,
        db: routingDb,
        getMyNodeId: () => localNodeId,
        getMasterKeyPair: () => localEd25519KeyPair,
        getStaticX25519KeyPair: () => localStaticX25519KeyPair,
        getSignedKeyBundle: () => delayedBundle,
        getConnectedPeers: () => connectedPeers,
      );

      // Trigger route advertisement when key bundle is still null
      await routerEngine.routeProtocol.sendRouteAdvertisement('EP_PEER_ALPHA');

      // Should NOT have transmitted yet because bundle is pending
      expect(mockTransport.sentPackets.isEmpty, isTrue);

      // Simulate bundle becoming available
      delayedBundle = localBundle;

      // Wait for the 300ms backoff timer to fire
      await Future.delayed(const Duration(milliseconds: 400));

      // Should now have successfully sent the route advertisement with key bundle attached
      expect(mockTransport.sentPackets.length, equals(1));
      final sentBytes = mockTransport.sentPackets.first['bytes'] as Uint8List;
      final envelope = PacketEnvelope.fromJson(utf8.decode(sentBytes));

      expect(envelope.messageType, equals('ROUTE_ADVERTISEMENT'));
      final payloadMap = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      expect(payloadMap.containsKey('signedKeyBundle'), isTrue);
      expect(payloadMap['nodeId'], equals(localNodeId));
    });

    test('2. Disconnection during handshake retry cancels pending timer immediately', () async {
      routerEngine = RouterEngine(
        transport: mockTransport,
        packetService: packetService,
        cryptoService: cryptoService,
        db: routingDb,
        getMyNodeId: () => localNodeId,
        getMasterKeyPair: () => null, // Never ready
        getStaticX25519KeyPair: () => localStaticX25519KeyPair,
        getSignedKeyBundle: () => localBundle,
        getConnectedPeers: () => connectedPeers,
      );

      // Trigger retry loop
      await routerEngine.routeProtocol.sendRouteAdvertisement('EP_PEER_ALPHA');
      expect(mockTransport.sentPackets.isEmpty, isTrue);

      // Simulate peer disconnection before retry fires
      connectedPeers.clear();
      routerEngine.routeProtocol.onPeerDisconnected('EP_PEER_ALPHA');

      // Wait beyond the retry window
      await Future.delayed(const Duration(milliseconds: 500));

      // Must remain 0 sent packets
      expect(mockTransport.sentPackets.isEmpty, isTrue);
    });

    test('3. Reciprocal Ping-Pong suppression prevents redundant route advertisements within 3s', () async {
      routerEngine = RouterEngine(
        transport: mockTransport,
        packetService: packetService,
        cryptoService: cryptoService,
        db: routingDb,
        getMyNodeId: () => localNodeId,
        getMasterKeyPair: () => localEd25519KeyPair,
        getStaticX25519KeyPair: () => localStaticX25519KeyPair,
        getSignedKeyBundle: () => localBundle,
        getConnectedPeers: () => connectedPeers,
      );

      // First send (initial advertisement)
      await routerEngine.routeProtocol.sendRouteAdvertisement('EP_PEER_ALPHA', isReply: false);
      expect(mockTransport.sentPackets.length, equals(1));

      // Immediate reciprocal send (isReply: true within 3s)
      await routerEngine.routeProtocol.sendRouteAdvertisement('EP_PEER_ALPHA', isReply: true);

      // Must be suppressed; packet count remains 1
      expect(mockTransport.sentPackets.length, equals(1));
    });

    test('4. SendQueueManager.clearQueue purges both endpointId and mapped nodeId', () async {
      final sendQueue = SendQueueManager(transport: mockTransport);
      sendQueue.endpointResolver = (id) => id == 'NODE_ID_XYZ' ? 'EP_TRANSIENT_99' : null;

      // Enqueue packet under nodeId
      final sendFuture = sendQueue.enqueueAndSend(
        packetId: 'pkt_double_key_test',
        peerId: 'NODE_ID_XYZ',
        payloadBytes: Uint8List.fromList([1, 2, 3]),
      );

      // Queue should have entry under normalized endpoint ID
      expect(sendQueue.queueDepth('EP_TRANSIENT_99'), equals(0)); // 0 in queue because 1 is in active transmitting
      expect(sendQueue.isTransmitting('EP_TRANSIENT_99'), isTrue);

      // Call clearQueue with the logical nodeId
      sendQueue.clearQueue('NODE_ID_XYZ');

      // In-flight transmission future must be completed with false
      final result = await sendFuture;
      expect(result, isFalse);
      expect(sendQueue.isTransmitting('EP_TRANSIENT_99'), isFalse);
    });
  });
}
