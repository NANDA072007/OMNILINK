import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilink/core/protocol/chunk_payload_models.dart';
import 'package:omnilink/core/protocol/packet_types.dart';
import 'package:omnilink/core/segmentation/models/payload_chunk.dart';
import 'package:omnilink/core/segmentation/models/payload_transfer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Segmentation Payload Models Unit Tests', () {
    test('PayloadTransfer serializes and deserializes to map and JSON correctly', () {
      final now = DateTime.now();
      final transfer = PayloadTransfer(
        payloadId: 'pld_12345',
        direction: TransferDirection.outgoing,
        senderNodeId: 'node_a',
        recipientNodeId: 'node_b',
        fileName: 'sample_image.jpg',
        payloadType: 'image',
        mimeType: 'image/jpeg',
        totalSize: 102400,
        totalChunks: 35,
        receivedChunks: 10,
        finalSha256: 'abc123sha256',
        transferState: TransferState.sending,
        localFilePath: '/storage/sample_image.jpg',
        createdAt: now,
        updatedAt: now,
      );

      final map = transfer.toMap();
      final restored = PayloadTransfer.fromMap(map);

      expect(restored.payloadId, equals(transfer.payloadId));
      expect(restored.direction, equals(TransferDirection.outgoing));
      expect(restored.transferState, equals(TransferState.sending));
      expect(restored.totalSize, equals(102400));
      expect(restored.totalChunks, equals(35));
    });

    test('PayloadChunk handles binary data and map conversion', () {
      final now = DateTime.now();
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);

      final chunk = PayloadChunk(
        payloadId: 'pld_12345',
        chunkIndex: 3,
        chunkSha256: 'sha256_chunk_3',
        chunkData: bytes,
        receivedAt: now,
      );

      final map = chunk.toMap();
      final restored = PayloadChunk.fromMap(map);

      expect(restored.payloadId, equals(chunk.payloadId));
      expect(restored.chunkIndex, equals(3));
      expect(restored.chunkData, equals(bytes));
    });

    test('TransferOfferPayload JSON roundtrip', () {
      const offer = TransferOfferPayload(
        payloadId: 'pld_999',
        fileName: 'test.pdf',
        mimeType: 'application/pdf',
        totalSize: 50000,
        totalChunks: 17,
        finalSha256: 'sha256_final_999',
      );

      final jsonStr = offer.toJson();
      final restored = TransferOfferPayload.fromJson(jsonStr);

      expect(restored.payloadId, equals(offer.payloadId));
      expect(restored.fileName, equals('test.pdf'));
      expect(restored.totalChunks, equals(17));
    });

    test('ChunkPayload JSON roundtrip', () {
      const chunkPayload = ChunkPayload(
        payloadId: 'pld_999',
        chunkIndex: 0,
        chunkSha256: 'sha256_chk_0',
        chunkDataBase64: 'SGVsbG8gV29ybGQ=',
      );

      final jsonStr = chunkPayload.toJson();
      final restored = ChunkPayload.fromJson(jsonStr);

      expect(restored.payloadId, equals(chunkPayload.payloadId));
      expect(restored.chunkIndex, equals(0));
      expect(restored.chunkDataBase64, equals('SGVsbG8gV29ybGQ='));
    });

    test('ChunkAckPayload JSON roundtrip', () {
      const ack = ChunkAckPayload(
        payloadId: 'pld_999',
        windowStart: 0,
        receivedChunkIndices: [0, 1, 2, 4],
        missingChunkIndices: [3],
      );

      final jsonStr = ack.toJson();
      final restored = ChunkAckPayload.fromJson(jsonStr);

      expect(restored.payloadId, equals(ack.payloadId));
      expect(restored.receivedChunkIndices, equals([0, 1, 2, 4]));
      expect(restored.missingChunkIndices, equals([3]));
    });

    test('PacketType string conversion matches constants', () {
      expect(PacketType.transferOffer.toTypeString(), equals('TRANSFER_OFFER'));
      expect(PacketType.chunkPayload.toTypeString(), equals('CHUNK_PAYLOAD'));
      expect(PacketType.chunkAck.toTypeString(), equals('CHUNK_ACK'));
      expect(PacketType.fromTypeString('CHUNK_ACK'), equals(PacketType.chunkAck));
    });
  });
}
