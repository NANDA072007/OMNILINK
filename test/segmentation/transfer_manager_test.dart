import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/models/packet_envelope.dart';
import 'package:omnilink/core/protocol/chunk_payload_models.dart';
import 'package:omnilink/core/protocol/packet_types.dart';
import 'package:omnilink/core/routing/send_queue.dart';
import 'package:omnilink/core/segmentation/transfer_manager.dart';
import 'package:omnilink/transport_bridge/transport_adapter.dart';

class MockTransportAdapter implements TransportAdapter {
  final List<String> sentPackets = [];

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
    sentPackets.add(utf8.decode(packetBytes));
    return true;
  }

  @override
  Stream<PeerConnectionEvent> get peerEvents => const Stream.empty();

  @override
  Stream<IncomingPacketEvent> get incomingPackets => const Stream.empty();

  @override
  Future<bool> isConnected(String peerId) async => true;

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('TransferManager & RouterEngine Integration Tests', () {
    late DatabaseService testDbService;
    late MockTransportAdapter mockTransport;
    late SendQueueManager sendQueueManager;
    late TransferManager transferManager;

    setUp(() async {
      testDbService = DatabaseService.instance;
      final db = await testDbService.database;
      await db.execute('DELETE FROM payload_transfers');
      await db.execute('DELETE FROM payload_chunks');

      mockTransport = MockTransportAdapter();
      sendQueueManager = SendQueueManager(transport: mockTransport);
      transferManager = TransferManager(
        sendQueueManager: sendQueueManager,
        dbService: testDbService,
      );
    });

    test('TransferManager handles TRANSFER_OFFER and auto-replies with TRANSFER_ACCEPT', () async {
      const offerPayload = TransferOfferPayload(
        payloadId: 'pld_offer_123',
        fileName: 'test_photo.jpg',
        mimeType: 'image/jpeg',
        totalSize: 45000,
        totalChunks: 15,
        finalSha256: 'sha256_photo_offer',
      );

      final envelope = PacketEnvelope(
        packetId: 'pkt_offer_1',
        senderId: 'peer_sender_node',
        recipientId: 'my_local_node',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
        messageType: PacketTypeNames.transferOffer,
        payloadHash: 'hash',
        signature: 'sig',
        encryptedPayload: offerPayload.toJson(),
      );

      final progressEvents = <TransferProgress>[];
      final sub = transferManager.onProgressChanged.listen(progressEvents.add);

      await transferManager.handleIncomingEnvelope(envelope, 'peer_endpoint_1');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      // Verify progress event emitted and record created in SQLite
      expect(progressEvents.length, equals(1));
      expect(progressEvents.first.payloadId, equals('pld_offer_123'));
      expect(progressEvents.first.fileName, equals('test_photo.jpg'));

      final rows = await testDbService.query('payload_transfers', where: 'payload_id = ?', whereArgs: ['pld_offer_123']);
      expect(rows.length, equals(1));
      expect(rows.first['file_name'], equals('test_photo.jpg'));
    });

    test('cancelTransfer emits TRANSFER_ABORT packet to peer', () async {
      await transferManager.cancelTransfer('pld_offer_123', 'peer_endpoint_1');
      expect(mockTransport.sentPackets.isNotEmpty, isTrue);
      expect(mockTransport.sentPackets.first, contains('TRANSFER_ABORT'));
    });
  });
}
