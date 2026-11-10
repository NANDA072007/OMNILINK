import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../database/database_service.dart';
import '../diagnostics/app_logger.dart';
import '../models/packet_envelope.dart';
import '../protocol/chunk_payload_models.dart';
import '../protocol/packet_types.dart';
import '../routing/send_queue.dart';
import 'models/payload_transfer.dart';
import 'transfer_session.dart';

class TransferProgress {
  final String payloadId;
  final String fileName;
  final String mimeType;
  final int receivedChunks;
  final int totalChunks;
  final int totalSize;
  final double speedKbps;
  final TransferState state;

  const TransferProgress({
    required this.payloadId,
    required this.fileName,
    required this.mimeType,
    required this.receivedChunks,
    required this.totalChunks,
    required this.totalSize,
    this.speedKbps = 0.0,
    required this.state,
  });

  double get percentComplete {
    if (totalChunks == 0) return 0.0;
    return (receivedChunks / totalChunks).clamp(0.0, 1.0);
  }
}

class TransferManager {
  final SendQueueManager sendQueueManager;
  final DatabaseService dbService;
  late final TransferSessionManager sessionManager;

  final _progressController = StreamController<TransferProgress>.broadcast();
  Stream<TransferProgress> get onProgressChanged => _progressController.stream;

  TransferManager({
    required this.sendQueueManager,
    DatabaseService? dbService,
  }) : dbService = dbService ?? DatabaseService.instance {
    sessionManager = TransferSessionManager(
      sendQueueManager: sendQueueManager,
      dbService: dbService,
    );
  }

  Future<void> handleIncomingEnvelope(PacketEnvelope envelope, String ingressPeerId) async {
    final type = PacketType.fromTypeString(envelope.messageType);
    AppLogger.info('TransferManager received packet type: ${envelope.messageType} from $ingressPeerId', domain: LogDomain.crypto);

    switch (type) {
      case PacketType.transferOffer:
        await _handleTransferOffer(envelope, ingressPeerId);
        break;
      case PacketType.transferAccept:
        await _handleTransferAccept(envelope, ingressPeerId);
        break;
      case PacketType.transferReject:
      case PacketType.transferAbort:
        _handleTransferAbort(envelope);
        break;
      case PacketType.chunkPayload:
        await _handleChunkPayload(envelope, ingressPeerId);
        break;
      case PacketType.chunkAck:
        await _handleChunkAck(envelope);
        break;
      default:
        break;
    }
  }

  Future<void> _handleTransferOffer(PacketEnvelope envelope, String ingressPeerId) async {
    final offer = TransferOfferPayload.fromJson(envelope.encryptedPayload);
    final now = DateTime.now();

    Directory targetDir;
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      targetDir = Directory('${docsDir.path}/Omnilink_Media');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
    } catch (_) {
      final tempDir = Directory.systemTemp;
      targetDir = Directory('${tempDir.path}/Omnilink_Media');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
    }

    String fileName = offer.fileName;
    File targetFile = File('${targetDir.path}/$fileName');

    if (await targetFile.exists()) {
      final extIdx = fileName.lastIndexOf('.');
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      if (extIdx != -1) {
        final name = fileName.substring(0, extIdx);
        final ext = fileName.substring(extIdx);
        fileName = '${name}_$timestamp$ext';
      } else {
        fileName = '${fileName}_$timestamp';
      }
      targetFile = File('${targetDir.path}/$fileName');
    }

    final transfer = PayloadTransfer(
      payloadId: offer.payloadId,
      direction: TransferDirection.incoming,
      senderNodeId: envelope.senderId,
      recipientNodeId: envelope.recipientId,
      fileName: fileName,
      payloadType: offer.mimeType.split('/').first,
      mimeType: offer.mimeType,
      totalSize: offer.totalSize,
      totalChunks: offer.totalChunks,
      receivedChunks: 0,
      finalSha256: offer.finalSha256,
      transferState: TransferState.accepted,
      localFilePath: targetFile.path,
      createdAt: now,
      updatedAt: now,
    );

    await dbService.insert('payload_transfers', transfer.toMap());

    final acceptEnvelopeJson = jsonEncode({
      'packet_id': 'acc_${offer.payloadId}',
      'sender_id': envelope.recipientId,
      'recipient_id': envelope.senderId,
      'message_type': PacketTypeNames.transferAccept,
      'encrypted_payload': jsonEncode({'payload_id': offer.payloadId}),
    });

    await sendQueueManager.enqueueAndSend(
      packetId: 'acc_${offer.payloadId}',
      peerId: ingressPeerId,
      payloadBytes: Uint8List.fromList(utf8.encode(acceptEnvelopeJson)),
    );

    _notifyProgress(transfer);
  }

  Future<void> _handleTransferAccept(PacketEnvelope envelope, String ingressPeerId) async {
    final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
    final payloadId = map['payload_id'] as String;

    final rows = await dbService.query('payload_transfers', where: 'payload_id = ?', whereArgs: [payloadId]);
    if (rows.isNotEmpty) {
      final transfer = PayloadTransfer.fromMap(rows.first);
      await sessionManager.startOutgoingSession(transfer, ingressPeerId);
      _notifyProgress(transfer.copyWith(transferState: TransferState.sending));
    }
  }

  void _handleTransferAbort(PacketEnvelope envelope) {
    try {
      final map = jsonDecode(envelope.encryptedPayload) as Map<String, dynamic>;
      final payloadId = map['payload_id'] as String;
      sessionManager.abortTransfer(payloadId);
    } catch (_) {}
  }

  Future<void> _handleChunkPayload(PacketEnvelope envelope, String ingressPeerId) async {
    final chunk = ChunkPayload.fromJson(envelope.encryptedPayload);
    final rows = await dbService.query('payload_transfers', where: 'payload_id = ?', whereArgs: [chunk.payloadId]);
    if (rows.isNotEmpty) {
      final transfer = PayloadTransfer.fromMap(rows.first);
      await sessionManager.handleIncomingChunk(transfer, chunk, ingressPeerId);
      _notifyProgress(transfer.copyWith(receivedChunks: chunk.chunkIndex + 1, transferState: TransferState.receiving));
    }
  }

  Future<void> _handleChunkAck(PacketEnvelope envelope) async {
    final ack = ChunkAckPayload.fromJson(envelope.encryptedPayload);
    await sessionManager.handleAck(ack);
  }

  Future<void> cancelTransfer(String payloadId, String peerId) async {
    sessionManager.abortTransfer(payloadId);
    final abortEnvelopeJson = jsonEncode({
      'packet_id': 'ab_${payloadId}_${DateTime.now().millisecondsSinceEpoch}',
      'sender_id': 'me',
      'recipient_id': peerId,
      'message_type': PacketTypeNames.transferAbort,
      'encrypted_payload': jsonEncode({'payload_id': payloadId}),
    });

    await sendQueueManager.enqueueAndSend(
      packetId: 'ab_$payloadId',
      peerId: peerId,
      payloadBytes: Uint8List.fromList(utf8.encode(abortEnvelopeJson)),
    );
  }

  void _notifyProgress(PayloadTransfer transfer) {
    _progressController.add(
      TransferProgress(
        payloadId: transfer.payloadId,
        fileName: transfer.fileName,
        mimeType: transfer.mimeType,
        receivedChunks: transfer.receivedChunks,
        totalChunks: transfer.totalChunks,
        totalSize: transfer.totalSize,
        state: transfer.transferState,
      ),
    );
  }

  void dispose() {
    sessionManager.dispose();
    if (!_progressController.isClosed) {
      _progressController.close();
    }
  }
}
