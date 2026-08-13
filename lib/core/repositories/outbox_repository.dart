import '../database/database_service.dart';
import '../models/packet_envelope.dart';

/// Repository managing the persistent Store-and-Forward outbox queue.
/// Holds encrypted packets when destination nodes are offline until radio links reconnect.
class OutboxRepository {
  final DatabaseService _dbService;

  OutboxRepository({DatabaseService? dbService})
      : _dbService = dbService ?? DatabaseService.instance;

  /// Saves a [PacketEnvelope] to the persistent outbox queue.
  Future<void> saveToOutbox(PacketEnvelope envelope) async {
    final data = {
      'packet_id': envelope.packetId,
      'recipient_node_id': envelope.recipientId,
      'envelope_json': envelope.toJson(),
      'created_at': envelope.createdAt,
      'attempts': 0,
    };

    await _dbService.insert('outbox_queue', data);
  }

  /// Retrieves pending packets awaiting delivery to a specific recipient node ID.
  Future<List<PacketEnvelope>> getPendingPacketsForRecipient(
    String recipientNodeId,
  ) async {
    final rows = await _dbService.query(
      'outbox_queue',
      where: 'recipient_node_id = ?',
      whereArgs: [recipientNodeId],
      orderBy: 'created_at ASC',
    );

    return rows
        .map((row) => PacketEnvelope.fromJson(row['envelope_json'] as String))
        .toList();
  }

  /// Retrieves all pending packets currently queued in the outbox.
  Future<List<PacketEnvelope>> getAllPendingPackets() async {
    final rows = await _dbService.query(
      'outbox_queue',
      orderBy: 'created_at ASC',
    );

    return rows
        .map((row) => PacketEnvelope.fromJson(row['envelope_json'] as String))
        .toList();
  }

  /// Removes a successfully delivered packet from the outbox queue.
  Future<void> removeFromOutbox(String packetId) async {
    await _dbService.delete(
      'outbox_queue',
      where: 'packet_id = ?',
      whereArgs: [packetId],
    );
  }

  /// Increments the delivery attempt counter for a packet in the outbox.
  Future<void> incrementAttemptCount(String packetId) async {
    final rows = await _dbService.query(
      'outbox_queue',
      where: 'packet_id = ?',
      whereArgs: [packetId],
      limit: 1,
    );

    if (rows.isNotEmpty) {
      final currentAttempts = (rows.first['attempts'] as int? ?? 0) + 1;
      await _dbService.update(
        'outbox_queue',
        {'attempts': currentAttempts},
        where: 'packet_id = ?',
        whereArgs: [packetId],
      );
    }
  }
}
