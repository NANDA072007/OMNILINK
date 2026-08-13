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

  /// Retrieves a specific [PacketEnvelope] from the outbox queue by packetId.
  Future<PacketEnvelope?> getEnvelopeByPacketId(String packetId) async {
    final rows = await _dbService.query(
      'outbox_queue',
      where: 'packet_id = ?',
      whereArgs: [packetId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PacketEnvelope.fromJson(rows.first['envelope_json'] as String);
  }

  /// Retrieves all packet IDs currently stored in the outbox queue and messages table.
  Future<Set<String>> getAllKnownPacketIds() async {
    final outboxRows = await _dbService.query('outbox_queue');
    final messageRows = await _dbService.query('messages');

    final ids = <String>{};
    for (final row in outboxRows) {
      final id = row['packet_id'] as String?;
      if (id != null) ids.add(id);
    }
    for (final row in messageRows) {
      final id = row['message_id'] as String?;
      if (id != null) ids.add(id);
    }
    return ids;
  }
}
