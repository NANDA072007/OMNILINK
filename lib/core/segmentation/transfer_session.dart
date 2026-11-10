import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import '../database/database_service.dart';
import '../diagnostics/app_logger.dart';
import '../protocol/chunk_payload_models.dart';
import '../protocol/packet_types.dart';
import '../routing/send_queue.dart';
import 'models/payload_chunk.dart';
import 'models/payload_transfer.dart';
import 'payload_segmenter.dart';

/// Single outgoing transfer session managing sliding window ACK transmission.
class OutgoingTransferSession {
  final PayloadTransfer transfer;
  final String peerId;
  final SendQueueManager sendQueueManager;
  final DatabaseService dbService;
  final PayloadSegmenter segmenter;

  static const int maxWindowSize = 15;
  static const Duration ackTimeoutDuration = Duration(seconds: 10);

  int windowStart = 0;
  int windowEnd = 0;
  int nextChunkToSend = 0;
  Timer? ackTimeoutTimer;
  bool isCompleted = false;

  final Set<int> _ackedChunkIndices = {};
  final Map<int, ChunkData> _bufferedChunks = {};

  OutgoingTransferSession({
    required this.transfer,
    required this.peerId,
    required this.sendQueueManager,
    required this.dbService,
    PayloadSegmenter? segmenter,
  }) : segmenter = segmenter ?? PayloadSegmenter() {
    windowEnd = (transfer.totalChunks < maxWindowSize)
        ? transfer.totalChunks
        : maxWindowSize;
  }

  Future<void> start() async {
    AppLogger.info('Starting outgoing transfer session ${transfer.payloadId} to $peerId (totalChunks: ${transfer.totalChunks})', domain: LogDomain.crypto);
    await _loadAndSendWindow();
  }

  Future<void> _loadAndSendWindow() async {
    if (isCompleted) return;

    final filePath = transfer.localFilePath;
    if (filePath == null || !File(filePath).existsSync()) {
      await _markFailed('Local file path missing or file not found');
      return;
    }

    _bufferedChunks.clear();
    final windowSize = windowEnd - windowStart;
    if (windowSize <= 0) return;

    final windowChunks = await segmenter.readWindowChunks(filePath, windowStart, windowSize);

    for (final chunk in windowChunks) {
      _bufferedChunks[chunk.chunkIndex] = chunk;
    }

    await _dispatchWindowChunks();
    _resetAckTimeoutTimer();
  }

  Future<void> _dispatchWindowChunks() async {
    for (int i = windowStart; i < windowEnd; i++) {
      if (_ackedChunkIndices.contains(i)) continue;
      final chunkData = _bufferedChunks[i];
      if (chunkData == null) continue;

      final chunkPayload = ChunkPayload(
        payloadId: transfer.payloadId,
        chunkIndex: i,
        chunkSha256: chunkData.chunkSha256,
        chunkDataBase64: base64Encode(chunkData.byteData),
      );

      final envelopeJson = jsonEncode({
        'packet_id': 'chk_${transfer.payloadId}_$i',
        'sender_id': transfer.senderNodeId,
        'recipient_id': transfer.recipientNodeId,
        'message_type': PacketTypeNames.chunkPayload,
        'encrypted_payload': chunkPayload.toJson(),
      });

      await sendQueueManager.enqueueAndSend(
        packetId: 'chk_${transfer.payloadId}_$i',
        peerId: peerId,
        payloadBytes: Uint8List.fromList(utf8.encode(envelopeJson)),
      );
    }
  }

  Future<void> handleAck(ChunkAckPayload ack) async {
    if (isCompleted || ack.payloadId != transfer.payloadId) return;

    ackTimeoutTimer?.cancel();
    _ackedChunkIndices.addAll(ack.receivedChunkIndices);

    while (_ackedChunkIndices.contains(windowStart) && windowStart < transfer.totalChunks) {
      windowStart++;
    }

    windowEnd = (windowStart + maxWindowSize).clamp(0, transfer.totalChunks);

    if (ack.missingChunkIndices.isNotEmpty) {
      for (final missingIdx in ack.missingChunkIndices) {
        final chunkData = _bufferedChunks[missingIdx];
        if (chunkData != null) {
          final chunkPayload = ChunkPayload(
            payloadId: transfer.payloadId,
            chunkIndex: missingIdx,
            chunkSha256: chunkData.chunkSha256,
            chunkDataBase64: base64Encode(chunkData.byteData),
          );

          final envelopeJson = jsonEncode({
            'packet_id': 'chk_ret_${transfer.payloadId}_$missingIdx',
            'sender_id': transfer.senderNodeId,
            'recipient_id': transfer.recipientNodeId,
            'message_type': PacketTypeNames.chunkPayload,
            'encrypted_payload': chunkPayload.toJson(),
          });

          await sendQueueManager.enqueueAndSend(
            packetId: 'chk_ret_${transfer.payloadId}_$missingIdx',
            peerId: peerId,
            payloadBytes: Uint8List.fromList(utf8.encode(envelopeJson)),
          );
        }
      }
    }

    if (windowStart >= transfer.totalChunks) {
      isCompleted = true;
      ackTimeoutTimer?.cancel();
      await _updateTransferState(TransferState.completed);
      AppLogger.info('Outgoing transfer ${transfer.payloadId} COMPLETED successfully', domain: LogDomain.crypto);
    } else {
      await _loadAndSendWindow();
    }
  }

  void _resetAckTimeoutTimer() {
    ackTimeoutTimer?.cancel();
    ackTimeoutTimer = Timer(ackTimeoutDuration, () async {
      if (isCompleted) return;
      AppLogger.warn('ACK timeout for outgoing transfer ${transfer.payloadId} (windowStart: $windowStart). Retransmitting window.', domain: LogDomain.crypto);
      await _dispatchWindowChunks();
      _resetAckTimeoutTimer();
    });
  }

  Future<void> _updateTransferState(TransferState state) async {
    await dbService.update(
      'payload_transfers',
      {
        'transfer_state': state.toDbString(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'payload_id = ?',
      whereArgs: [transfer.payloadId],
    );
  }

  Future<void> _markFailed(String reason) async {
    isCompleted = true;
    ackTimeoutTimer?.cancel();
    await _updateTransferState(TransferState.failed);
    AppLogger.error('Outgoing transfer ${transfer.payloadId} FAILED: $reason', domain: LogDomain.crypto);
  }

  void cancel() {
    isCompleted = true;
    ackTimeoutTimer?.cancel();
  }
}

/// Single incoming transfer session managing chunk verification, SQLite persistence, and file reassembly.
class IncomingTransferSession {
  final PayloadTransfer transfer;
  final String peerId;
  final SendQueueManager sendQueueManager;
  final DatabaseService dbService;

  static const int maxWindowSize = 15;

  final Set<int> receivedChunkIndices = {};
  bool isCompleted = false;

  IncomingTransferSession({
    required this.transfer,
    required this.peerId,
    required this.sendQueueManager,
    required this.dbService,
  });

  Future<void> handleChunk(ChunkPayload chunk) async {
    if (isCompleted || chunk.payloadId != transfer.payloadId) return;

    final chunkBytes = base64Decode(chunk.chunkDataBase64);
    final computedSha256 = crypto.sha256.convert(chunkBytes).toString();

    if (computedSha256 != chunk.chunkSha256) {
      AppLogger.warn('Chunk ${chunk.chunkIndex} for ${transfer.payloadId} failed SHA-256 validation! Dropping.', domain: LogDomain.crypto);
      return;
    }

    final payloadChunk = PayloadChunk(
      payloadId: transfer.payloadId,
      chunkIndex: chunk.chunkIndex,
      chunkSha256: chunk.chunkSha256,
      chunkData: chunkBytes,
      receivedAt: DateTime.now(),
    );

    await dbService.insert('payload_chunks', payloadChunk.toMap());
    receivedChunkIndices.add(chunk.chunkIndex);

    await dbService.update(
      'payload_transfers',
      {
        'received_chunks': receivedChunkIndices.length,
        'transfer_state': TransferState.receiving.toDbString(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'payload_id = ?',
      whereArgs: [transfer.payloadId],
    );

    if (receivedChunkIndices.length % maxWindowSize == 0 || receivedChunkIndices.length == transfer.totalChunks) {
      await _sendAck();
    }

    if (receivedChunkIndices.length == transfer.totalChunks) {
      await reassembleFile();
    }
  }

  Future<void> _sendAck() async {
    final windowStart = receivedChunkIndices.isEmpty ? 0 : receivedChunkIndices.reduce((a, b) => a < b ? a : b);
    final missing = <int>[];

    for (int i = 0; i < transfer.totalChunks; i++) {
      if (!receivedChunkIndices.contains(i)) {
        missing.add(i);
      }
    }

    final ackPayload = ChunkAckPayload(
      payloadId: transfer.payloadId,
      windowStart: windowStart,
      receivedChunkIndices: receivedChunkIndices.toList()..sort(),
      missingChunkIndices: missing,
    );

    final envelopeJson = jsonEncode({
      'packet_id': 'ack_${transfer.payloadId}_${DateTime.now().millisecondsSinceEpoch}',
      'sender_id': transfer.recipientNodeId,
      'recipient_id': transfer.senderNodeId,
      'message_type': PacketTypeNames.chunkAck,
      'encrypted_payload': ackPayload.toJson(),
    });

    await sendQueueManager.enqueueAndSend(
      packetId: 'ack_${transfer.payloadId}',
      peerId: peerId,
      payloadBytes: Uint8List.fromList(utf8.encode(envelopeJson)),
    );
  }

  Future<void> reassembleFile() async {
    if (isCompleted) return;
    AppLogger.info('Reassembling incoming payload ${transfer.payloadId}...', domain: LogDomain.crypto);

    final targetPath = transfer.localFilePath;
    if (targetPath == null) {
      await _markFailed('Local target file path missing');
      return;
    }

    final file = File(targetPath);
    final sink = file.openWrite();

    try {
      final rows = await dbService.query(
        'payload_chunks',
        where: 'payload_id = ?',
        whereArgs: [transfer.payloadId],
        orderBy: 'chunk_index ASC',
      );

      for (final row in rows) {
        final chunk = PayloadChunk.fromMap(row);
        if (chunk.chunkData != null) {
          sink.add(chunk.chunkData!);
        }
      }
      await sink.flush();
      await sink.close();

      final segmenter = PayloadSegmenter();
      final finalHash = await segmenter.calculateFinalSha256(targetPath);

      if (finalHash != transfer.finalSha256) {
        await _markFailed('Final SHA-256 checksum mismatch (expected: ${transfer.finalSha256}, actual: $finalHash)');
        return;
      }

      await dbService.delete(
        'payload_chunks',
        where: 'payload_id = ?',
        whereArgs: [transfer.payloadId],
      );

      isCompleted = true;
      await dbService.update(
        'payload_transfers',
        {
          'transfer_state': TransferState.completed.toDbString(),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'payload_id = ?',
        whereArgs: [transfer.payloadId],
      );
      AppLogger.info('Incoming transfer ${transfer.payloadId} COMPLETED, verified & SQLite chunks purged successfully!', domain: LogDomain.crypto);
    } catch (e) {
      await sink.close();
      await _markFailed('Reassembly error: $e');
    }
  }

  Future<void> _markFailed(String reason) async {
    isCompleted = true;
    await dbService.update(
      'payload_transfers',
      {
        'transfer_state': TransferState.failed.toDbString(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'payload_id = ?',
      whereArgs: [transfer.payloadId],
    );
    AppLogger.error('Incoming transfer ${transfer.payloadId} FAILED: $reason', domain: LogDomain.crypto);
  }

  void cancel() {
    isCompleted = true;
  }
}

/// Central Transfer Session Manager coordinating ongoing incoming & outgoing file segmentation sessions.
class TransferSessionManager {
  final SendQueueManager sendQueueManager;
  final DatabaseService dbService;

  final Map<String, OutgoingTransferSession> _outgoingSessions = {};
  final Map<String, IncomingTransferSession> _incomingSessions = {};

  TransferSessionManager({
    required this.sendQueueManager,
    DatabaseService? dbService,
  }) : dbService = dbService ?? DatabaseService.instance;

  Future<void> startOutgoingSession(PayloadTransfer transfer, String peerId) async {
    final session = OutgoingTransferSession(
      transfer: transfer,
      peerId: peerId,
      sendQueueManager: sendQueueManager,
      dbService: dbService,
    );
    _outgoingSessions[transfer.payloadId] = session;
    await session.start();
  }

  Future<void> handleAck(ChunkAckPayload ack) async {
    final session = _outgoingSessions[ack.payloadId];
    if (session != null) {
      await session.handleAck(ack);
    }
  }

  Future<void> handleIncomingChunk(PayloadTransfer transfer, ChunkPayload chunk, String peerId) async {
    var session = _incomingSessions[transfer.payloadId];
    if (session == null) {
      session = IncomingTransferSession(
        transfer: transfer,
        peerId: peerId,
        sendQueueManager: sendQueueManager,
        dbService: dbService,
      );
      _incomingSessions[transfer.payloadId] = session;
    }
    await session.handleChunk(chunk);
  }

  void abortTransfer(String payloadId) {
    _outgoingSessions.remove(payloadId)?.cancel();
    _incomingSessions.remove(payloadId)?.cancel();
    AppLogger.warn('Aborted transfer session $payloadId', domain: LogDomain.crypto);
  }

  void dispose() {
    for (final session in _outgoingSessions.values) {
      session.cancel();
    }
    _outgoingSessions.clear();
    for (final session in _incomingSessions.values) {
      session.cancel();
    }
    _incomingSessions.clear();
  }
}
