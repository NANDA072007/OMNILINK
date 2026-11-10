import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/models/message.dart';
import 'package:omnilink/core/models/peer_device.dart';
import 'package:omnilink/core/repositories/message_repository.dart';
import 'package:omnilink/core/routing/router_engine.dart';
import 'package:omnilink/core/routing/routing_database.dart';
import 'dart:async';
import 'package:omnilink/transport_bridge/transport_adapter.dart';
import '../helpers/test_async_utils.dart';

class TestMockTransportAdapter implements TransportAdapter {
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

  group('Phase 1 — Plaintext Outbox Queueing & In-Memory Encryption Tests', () {
    late DatabaseService dbService;
    late RoutingDatabaseService routingDb;
    late MessageRepository messageRepo;
    late CryptoService cryptoService;
    late PacketService packetService;
    late TestMockTransportAdapter mockTransport;
    late RouterEngine routerEngine;

    // Sender (Local)
    late SimpleKeyPair localEd25519KeyPair;
    late String localNodeId;
    late SimpleKeyPair localStaticX25519KeyPair;

    // Recipient (Remote)
    late SimpleKeyPair remoteEd25519KeyPair;
    late String remoteNodeId;
    late SimpleKeyPair remoteStaticX25519KeyPair;
    late String remoteStaticX25519Hex;

    late List<PeerDevice> connectedPeers;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      databaseFactory = databaseFactoryFfi;
      dbService = DatabaseService.instance;
      routingDb = RoutingDatabaseService.instance;
      messageRepo = MessageRepository(dbService: dbService);

      await dbService.clearAllTablesForTesting();

      cryptoService = CryptoService();
      packetService = PacketService(
        cryptoService: cryptoService,
        dbService: dbService,
      );

      mockTransport = TestMockTransportAdapter();

      localEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      localNodeId = await cryptoService.getEd25519PublicKeyHex(localEd25519KeyPair);
      localStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();

      remoteEd25519KeyPair = await cryptoService.generateEd25519KeyPair();
      remoteNodeId = await cryptoService.getEd25519PublicKeyHex(remoteEd25519KeyPair);
      remoteStaticX25519KeyPair = await cryptoService.generateX25519KeyPair();
      remoteStaticX25519Hex = await cryptoService.getX25519PublicKeyHex(remoteStaticX25519KeyPair);

      connectedPeers = [
        PeerDevice(
          peerId: 'EP_REMOTE',
          nodeId: remoteNodeId,
          friendlyName: 'Remote Device',
          staticX25519PublicKeyHex: remoteStaticX25519Hex,
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
        getMyNodeId: () => localNodeId,
        getMasterKeyPair: () => localEd25519KeyPair,
        getStaticX25519KeyPair: () => localStaticX25519KeyPair,
        getConnectedPeers: () => connectedPeers,
        messageRepo: messageRepo,
      );
    });

    tearDown(() async {
      routerEngine.dispose();
      await mockTransport.dispose();
      cryptoService.dispose();
    });

    test('1. MessageRepository.migrateConversationId updates both conversation_id and recipient_node_id', () async {
      final now = DateTime.now();
      final draft = Message(
        messageId: 'msg_draft_101',
        conversationId: 'EP_TRANSIENT_9A',
        senderNodeId: localNodeId,
        recipientNodeId: 'EP_TRANSIENT_9A',
        plaintextBody: 'Hello before identity exchange',
        state: MessageState.queued,
        createdAt: now,
        updatedAt: now,
      );

      await messageRepo.saveMessage(draft);

      // Verify initial state
      final initial = await messageRepo.getMessagesForConversation('EP_TRANSIENT_9A');
      expect(initial.length, equals(1));
      expect(initial.first.recipientNodeId, equals('EP_TRANSIENT_9A'));

      // Migrate
      await messageRepo.migrateConversationId('EP_TRANSIENT_9A', remoteNodeId);

      // Verify migration
      final migrated = await messageRepo.getMessagesForConversation(remoteNodeId);
      expect(migrated.length, equals(1));
      expect(migrated.first.conversationId, equals(remoteNodeId));
      expect(migrated.first.recipientNodeId, equals(remoteNodeId));
    });

    test('2. onIdentityLearned drains queued plaintext message using in-memory static key', () async {
      final now = DateTime.now();
      // Insert a pending plaintext message saved under transient endpoint
      final draft = Message(
        messageId: 'msg_deferred_202',
        conversationId: 'EP_REMOTE',
        senderNodeId: localNodeId,
        recipientNodeId: 'EP_REMOTE',
        plaintextBody: 'Instant burst upon key exchange!',
        state: MessageState.queued,
        createdAt: now,
        updatedAt: now,
      );
      await messageRepo.saveMessage(draft);

      // Trigger identity learning
      await routerEngine.outboxDaemon.onIdentityLearned(remoteNodeId, 'EP_REMOTE');

      // Message in SQLite should now be updated to delivered
      final updatedMessages = await pollUntil(
        condition: () async {
          final msgs = await messageRepo.getMessagesForConversation(remoteNodeId);
          if (msgs.isNotEmpty && msgs.first.state == MessageState.delivered) {
            return msgs;
          }
          return null;
        },
        message: 'Queued message was not delivered after onIdentityLearned',
      );
      expect(updatedMessages.length, equals(1));
      expect(updatedMessages.first.state, equals(MessageState.delivered));

      // Packet should have been sent over transport
      expect(mockTransport.sentPackets.isNotEmpty, isTrue);
    });

    test('3. RouterEngine.registerPeerNodeId automatically triggers conversation migration', () async {
      final now = DateTime.now();
      final draft = Message(
        messageId: 'msg_auto_303',
        conversationId: 'EP_TEMP_44',
        senderNodeId: localNodeId,
        recipientNodeId: 'EP_TEMP_44',
        plaintextBody: 'Automatic registration test',
        state: MessageState.queued,
        createdAt: now,
        updatedAt: now,
      );
      await messageRepo.saveMessage(draft);

      // Register mapping
      routerEngine.registerPeerNodeId(
        'EP_TEMP_44',
        remoteNodeId,
        staticX25519PublicKeyHex: remoteStaticX25519Hex,
      );

      final rows = await pollUntil(
        condition: () async {
          final msgs = await messageRepo.getMessagesForConversation(remoteNodeId);
          return msgs.isNotEmpty ? msgs : null;
        },
        message: 'Conversation was not migrated to remoteNodeId',
      );
      expect(rows.length, equals(1));
      expect(rows.first.conversationId, equals(remoteNodeId));
    });
  });
}
