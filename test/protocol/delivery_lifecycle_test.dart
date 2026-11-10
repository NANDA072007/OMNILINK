import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:omnilink/core/crypto/crypto_service.dart';
import 'package:omnilink/core/crypto/packet_service.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/models/message.dart';
import 'package:omnilink/core/models/peer_device.dart';
import 'package:omnilink/core/repositories/message_repository.dart';
import 'package:omnilink/core/routing/router_engine.dart';
import 'package:omnilink/core/routing/routing_database.dart';
import 'package:omnilink/transport_bridge/transport_adapter.dart';

import '../helpers/test_async_utils.dart';

class TestTransportAdapter implements TransportAdapter {
  final _incomingController = StreamController<IncomingPacketEvent>.broadcast();
  final _peerEventsController = StreamController<PeerConnectionEvent>.broadcast();
  final List<Map<String, dynamic>> sentPackets = [];

  void emitIncoming(String peerId, String jsonPayload) {
    _incomingController.add(
      IncomingPacketEvent(
        senderPeerId: peerId,
        payloadBytes: Uint8List.fromList(utf8.encode(jsonPayload)),
      ),
    );
  }

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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Phase 0 — Delivery lifecycle', () {
    late DatabaseService dbService;
    late RoutingDatabaseService routingDb;
    late MessageRepository messageRepo;
    late CryptoService cryptoService;
    late PacketService packetService;
    late TestTransportAdapter transport;
    late RouterEngine engine;
    late List<PeerDevice> connectedPeers;

    late SimpleKeyPair localEd25519;
    late SimpleKeyPair localStaticX25519;
    late String localNodeId;
    late String localStaticX25519Hex;

    late SimpleKeyPair remoteEd25519;
    late SimpleKeyPair remoteStaticX25519;
    late String remoteNodeId;
    late String remoteStaticX25519Hex;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      dbService = DatabaseService.instance;
      routingDb = RoutingDatabaseService.instance;
      await dbService.clearAllTablesForTesting();

      cryptoService = CryptoService();
      packetService = PacketService(
        cryptoService: cryptoService,
        dbService: dbService,
      );
      messageRepo = MessageRepository(dbService: dbService);
      transport = TestTransportAdapter();

      localEd25519 = await cryptoService.generateEd25519KeyPair();
      localStaticX25519 = await cryptoService.generateX25519KeyPair();
      localNodeId = await cryptoService.getEd25519PublicKeyHex(localEd25519);
      localStaticX25519Hex =
          await cryptoService.getX25519PublicKeyHex(localStaticX25519);

      remoteEd25519 = await cryptoService.generateEd25519KeyPair();
      remoteStaticX25519 = await cryptoService.generateX25519KeyPair();
      remoteNodeId = await cryptoService.getEd25519PublicKeyHex(remoteEd25519);
      remoteStaticX25519Hex =
          await cryptoService.getX25519PublicKeyHex(remoteStaticX25519);

      connectedPeers = [
        PeerDevice(
          peerId: 'EP_REMOTE',
          nodeId: remoteNodeId,
          friendlyName: 'Remote',
          staticX25519PublicKeyHex: remoteStaticX25519Hex,
          lastSeenAt: DateTime.now(),
          transportType: 'ANDROID_NEARBY',
          connectionStatus: PeerConnectionStatus.connected,
        ),
      ];

      engine = RouterEngine(
        transport: transport,
        packetService: packetService,
        cryptoService: cryptoService,
        db: routingDb,
        getMyNodeId: () => localNodeId,
        getMasterKeyPair: () => localEd25519,
        getStaticX25519KeyPair: () => localStaticX25519,
        getConnectedPeers: () => connectedPeers,
        messageRepo: messageRepo,
        receiptThrottle: Duration.zero,
      );
    });

    tearDown(() async {
      engine.dispose();
      await transport.dispose();
      cryptoService.dispose();
      await dbService.clearAllTablesForTesting();
    });

    test('control envelopes carry a real signature and survive relay mutation', () async {
      final envelope = await packetService.createSignedControlEnvelope(
        senderNodeId: localNodeId,
        senderKeyPair: localEd25519,
        recipientNodeId: remoteNodeId,
        messageType: 'ROUTE_REQUEST',
        payloadJson: jsonEncode({'targetNodeId': remoteNodeId}),
        packetId: 'ctrl_signed_1',
        ttl: 4,
        maxHops: 4,
        validity: const Duration(minutes: 5),
      );

      expect(envelope.signature, isNot('public_metadata'));
      expect(await packetService.validateEnvelope(envelope), isTrue);

      // Relays may decrement TTL/hop count without invalidating the signature.
      final relayed = envelope.copyWith(ttl: 3, hopCount: 1);
      expect(await packetService.validateEnvelope(relayed), isTrue);

      // Payload tampering is rejected by the payload hash.
      final tamperedPayload = envelope.copyWith(
        encryptedPayload: jsonEncode({'targetNodeId': 'attacker'}),
      );
      await expectLater(
        packetService.validateEnvelope(tamperedPayload),
        throwsA(
          isA<PacketValidationException>().having(
            (e) => e.errorCode,
            'errorCode',
            'PAYLOAD_HASH_MISMATCH',
          ),
        ),
      );

      // Signature tampering is rejected by Ed25519 verification.
      final tamperedSignature = envelope.copyWith(
        signature: List.filled(128, '0').join(),
      );
      await expectLater(
        packetService.validateEnvelope(tamperedSignature),
        throwsA(
          isA<PacketValidationException>().having(
            (e) => e.errorCode,
            'errorCode',
            'INVALID_SIGNATURE',
          ),
        ),
      );
    });

    test('link ACK retains the outbox row until a verified receipt arrives', () async {
      final now = DateTime.now();
      final message = Message(
        messageId: 'pkt_lifecycle_1',
        conversationId: remoteNodeId,
        senderNodeId: localNodeId,
        recipientNodeId: remoteNodeId,
        plaintextBody: 'durable hello',
        state: MessageState.sending,
        createdAt: now,
        updatedAt: now,
      );
      await messageRepo.saveMessage(message);

      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: localNodeId,
        senderKeyPair: localEd25519,
        senderStaticX25519KeyPair: localStaticX25519,
        recipientNodeId: remoteNodeId,
        recipientStaticX25519PublicKeyHex: remoteStaticX25519Hex,
        plaintextBody: 'durable hello',
        packetId: message.messageId,
      );

      await engine.sendMessage(envelope);

      final heldAfterLinkAck = await routingDb.getAllQueuedPackets();
      expect(
        heldAfterLinkAck.map((p) => p.packetId),
        contains(message.messageId),
        reason: 'A radio ACK must not remove the sender\'s only durable copy.',
      );

      final afterLinkAck = await messageRepo.getMessagesForConversation(remoteNodeId);
      expect(afterLinkAck.single.state, MessageState.delivered);

      final receipt = await packetService.createSignedControlEnvelope(
        senderNodeId: remoteNodeId,
        senderKeyPair: remoteEd25519,
        recipientNodeId: localNodeId,
        messageType: 'DELIVERY_RECEIPT',
        payloadJson: jsonEncode({
          'originalPacketId': message.messageId,
          'deliveredAt': DateTime.now().millisecondsSinceEpoch,
        }),
        packetId: 'receipt_${message.messageId}',
        ttl: 4,
        maxHops: 4,
        priority: 2,
      );

      transport.emitIncoming('EP_REMOTE', receipt.toJson());

      await pollUntil<bool>(
        condition: () async {
          final rows = await routingDb.getAllQueuedPackets();
          return rows.isEmpty ? true : null;
        },
        message: 'Outbox row was not removed after a verified receipt',
      );

      final afterReceipt = await messageRepo.getMessagesForConversation(remoteNodeId);
      expect(afterReceipt.single.state, MessageState.receiptReceived);

      final sentHistory = await routingDb.getSentPacketPayloadsByIds(
        [message.messageId],
      );
      expect(
        sentHistory,
        contains(message.messageId),
        reason: 'Delivered packets must remain resendable until expiry.',
      );

      // A replayed receipt must be harmless and keep the row deleted.
      transport.emitIncoming('EP_REMOTE', receipt.toJson());
      await Future.delayed(const Duration(milliseconds: 200));
      expect(await routingDb.getAllQueuedPackets(), isEmpty);
      final afterReplay = await messageRepo.getMessagesForConversation(remoteNodeId);
      expect(afterReplay.single.state, MessageState.receiptReceived);
      expect(
        (await routingDb.getSentPacketIds())
            .where((id) => id == message.messageId)
            .length,
        1,
      );
    });

    test('persistent processed IDs survive a new PacketService instance', () async {
      final envelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: localNodeId,
        senderKeyPair: localEd25519,
        senderStaticX25519KeyPair: localStaticX25519,
        recipientNodeId: remoteNodeId,
        recipientStaticX25519PublicKeyHex: remoteStaticX25519Hex,
        plaintextBody: 'persist me',
        packetId: 'pkt_persist_1',
      );

      await packetService.validateAndClaimEnvelope(envelope);

      // Simulate an app restart: a new PacketService has an empty RAM cache.
      final restartedService = PacketService(
        cryptoService: cryptoService,
        dbService: dbService,
      );
      final ids = await restartedService.getProcessedPacketIdsFromStore();
      expect(ids, contains('pkt_persist_1'));
    });

    test('a duplicate inbound message re-sends the delivery receipt', () async {
      final inboundEnvelope = await packetService.createEncryptedMessageEnvelope(
        senderNodeId: remoteNodeId,
        senderKeyPair: remoteEd25519,
        senderStaticX25519KeyPair: remoteStaticX25519,
        recipientNodeId: localNodeId,
        recipientStaticX25519PublicKeyHex: localStaticX25519Hex,
        plaintextBody: 'at least once',
        packetId: 'pkt_inbound_1',
      );

      int receiptCount() {
        var count = 0;
        for (final sent in transport.sentPackets) {
          try {
            final decoded = jsonDecode(
              utf8.decode(sent['bytes'] as Uint8List),
            ) as Map<String, dynamic>;
            if (decoded['message_type'] == 'DELIVERY_RECEIPT' &&
                decoded['recipient_id'] == remoteNodeId) {
              count++;
            }
          } catch (_) {}
        }
        return count;
      }

      transport.emitIncoming('EP_REMOTE', inboundEnvelope.toJson());

      await pollUntil<bool>(
        condition: () async {
          return await messageRepo.hasMessage('pkt_inbound_1') ? true : null;
        },
        message: 'Inbound message was not persisted',
      );

      await pollUntil<bool>(
        condition: () async => receiptCount() >= 1 ? true : null,
        message: 'First delivery receipt was not sent',
      );

      // Replaying the same packet must re-acknowledge it, not drop silently.
      transport.emitIncoming('EP_REMOTE', inboundEnvelope.toJson());

      await pollUntil<bool>(
        condition: () async => receiptCount() >= 2 ? true : null,
        message: 'Duplicate message did not trigger a second receipt',
      );

      expect(await messageRepo.hasMessage('pkt_inbound_1'), isTrue);
    });
  });
}
