import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:omnilink/core/database/database_service.dart';
import 'package:omnilink/core/protocol/chunk_payload_models.dart';
import 'package:omnilink/core/routing/send_queue.dart';
import 'package:omnilink/core/segmentation/models/payload_transfer.dart';
import 'package:omnilink/core/segmentation/payload_segmenter.dart';
import 'package:omnilink/core/segmentation/transfer_session.dart';

import 'package:omnilink/transport_bridge/transport_adapter.dart';

class MockTransportAdapter implements TransportAdapter {
  final List<String> sentPacketIds = [];

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
    sentPacketIds.add(peerId);
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

  group('TransferSessionManager & Sliding Window Unit Tests', () {
    late DatabaseService testDbService;
    late SendQueueManager sendQueueManager;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('transfer_session_test_');
      testDbService = DatabaseService.instance;
      final db = await testDbService.database;
      await db.execute('DELETE FROM payload_transfers');
      await db.execute('DELETE FROM payload_chunks');

      sendQueueManager = SendQueueManager(transport: MockTransportAdapter() as dynamic);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('OutgoingTransferSession enforces max window size 15', () {
      final transfer = PayloadTransfer(
        payloadId: 'pld_window_test',
        direction: TransferDirection.outgoing,
        senderNodeId: 'node_a',
        recipientNodeId: 'node_b',
        fileName: 'test.bin',
        payloadType: 'file',
        mimeType: 'application/octet-stream',
        totalSize: 90000,
        totalChunks: 30,
        finalSha256: 'sha256_dummy',
        transferState: TransferState.pending,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final session = OutgoingTransferSession(
        transfer: transfer,
        peerId: 'peer_b',
        sendQueueManager: sendQueueManager,
        dbService: testDbService,
      );

      expect(session.windowStart, equals(0));
      expect(session.windowEnd, equals(15));
    });

    test('IncomingTransferSession reassembles file and verifies final SHA-256', () async {
      final targetFile = File('${tempDir.path}/reassembled_output.txt');
      const originalContent = 'OMNILINK End-to-End File Reassembly Content Test';
      final segmenter = PayloadSegmenter();

      final tempInputFile = File('${tempDir.path}/input.txt');
      await tempInputFile.writeAsString(originalContent);
      final finalSha256 = await segmenter.calculateFinalSha256(tempInputFile.path);

      final transfer = PayloadTransfer(
        payloadId: 'pld_session_inc_999',
        direction: TransferDirection.incoming,
        senderNodeId: 'node_sender',
        recipientNodeId: 'node_receiver',
        fileName: 'reassembled_output.txt',
        payloadType: 'text',
        mimeType: 'text/plain',
        totalSize: originalContent.length,
        totalChunks: 1,
        finalSha256: finalSha256,
        transferState: TransferState.pending,
        localFilePath: targetFile.path,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await testDbService.insert('payload_transfers', transfer.toMap());

      final session = IncomingTransferSession(
        transfer: transfer,
        peerId: 'peer_sender',
        sendQueueManager: sendQueueManager,
        dbService: testDbService,
      );

      final chunkData = await segmenter.streamFileChunks(tempInputFile.path, 'pld_session_inc_999').first;
      final chunkPayload = ChunkPayload(
        payloadId: 'pld_session_inc_999',
        chunkIndex: 0,
        chunkSha256: chunkData.chunkSha256,
        chunkDataBase64: base64Encode(chunkData.byteData),
      );

      // Handle incoming chunk which automatically triggers file reassembly
      await session.handleChunk(chunkPayload);

      expect(session.isCompleted, isTrue);
      expect(targetFile.existsSync(), isTrue);
      expect(await targetFile.readAsString(), equals(originalContent));
    });

    test('TransferSessionManager aborts session cleanly', () {
      final manager = TransferSessionManager(
        sendQueueManager: sendQueueManager,
        dbService: testDbService,
      );

      manager.abortTransfer('pld_abort_123');
    });
  });
}
